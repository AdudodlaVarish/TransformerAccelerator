`timescale 1ns/1ps

module transformer_gemm_accelerator #(
    parameter int ROWS       = 4,
    parameter int COLS       = 4,
    parameter int K          = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int REQUANT_MULT_WIDTH = 16,
    parameter string BUFFER_RAM_STYLE = "block",
    localparam int K_ADDR_WIDTH = (K <= 1) ? 1 : $clog2(K),
    localparam int REQUANT_SHIFT_WIDTH =
        $clog2(ACC_WIDTH + REQUANT_MULT_WIDTH + 2),
    localparam int S_AXIS_DATA_WIDTH = (ROWS + COLS) * DATA_WIDTH,
    localparam int OUTPUTS = ROWS * COLS,
    localparam int OUTPUT_INDEX_WIDTH = (OUTPUTS <= 1) ? 1 : $clog2(OUTPUTS)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic                         s_axis_tvalid,
    output logic                         s_axis_tready,
    input  logic [S_AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    input  logic                         s_axis_tlast,
    input  logic [1:0]                   s_axis_tuser,
    input  logic [REQUANT_MULT_WIDTH-1:0] requant_multiplier,
    input  logic [REQUANT_SHIFT_WIDTH-1:0] requant_shift,
    input  logic signed [DATA_WIDTH-1:0] requant_zero_point,

    output logic                         m_axis_tvalid,
    input  logic                         m_axis_tready,
    output logic signed [DATA_WIDTH-1:0] m_axis_tdata,
    output logic                         m_axis_tlast,

    input  logic        counters_clear,
    output logic        busy,
    output logic        protocol_error,
    output logic [63:0] total_cycles,
    output logic [63:0] compute_cycles,
    output logic [63:0] input_stall_cycles,
    output logic [63:0] output_stall_cycles,
    output logic [31:0] tiles_completed,
    output logic [31:0] results_transferred
);
    // s_axis_tuser[0] accumulate this K tile onto the previous partial sum.
    // s_axis_tuser[1] stream the result after this K tile completes.
    logic [1:0] bank_full;
    logic [1:0] bank_accumulate;
    logic [1:0] bank_emit;
    logic [REQUANT_MULT_WIDTH-1:0] bank_multiplier[2];
    logic [REQUANT_SHIFT_WIDTH-1:0] bank_shift[2];
    logic signed [DATA_WIDTH-1:0] bank_zero_point[2];
    logic write_bank;
    logic next_compute_bank;
    logic incoming_accumulate;
    logic incoming_emit;
    logic [K_ADDR_WIDTH-1:0] beat_count;

    logic engine_load_ready;
    logic engine_start;
    logic engine_busy;
    logic engine_done;
    logic active_emit;
    logic [REQUANT_MULT_WIDTH-1:0] active_multiplier;
    logic [REQUANT_SHIFT_WIDTH-1:0] active_shift;
    logic signed [DATA_WIDTH-1:0] active_zero_point;
    logic signed [DATA_WIDTH-1:0] a_load[ROWS];
    logic signed [DATA_WIDTH-1:0] b_load[COLS];
    logic signed [DATA_WIDTH-1:0] engine_q[ROWS][COLS];
    logic                         unused_result_bank;
    logic signed [ACC_WIDTH-1:0]  unused_c_out[ROWS][COLS];

    logic signed [DATA_WIDTH-1:0] output_buffer[OUTPUTS];
    logic [OUTPUT_INDEX_WIDTH-1:0] output_index;
    logic output_pending;
    logic input_accept;
    logic expected_last;
    logic active_cycle;

    always_comb begin
        for (int row = 0; row < ROWS; row++)
            a_load[row] = s_axis_tdata[row*DATA_WIDTH +: DATA_WIDTH];
        for (int col = 0; col < COLS; col++)
            b_load[col] = s_axis_tdata[(ROWS+col)*DATA_WIDTH +: DATA_WIDTH];
    end

    assign s_axis_tready = rst_n && !bank_full[write_bank] && engine_load_ready;
    assign input_accept  = s_axis_tvalid && s_axis_tready;
    assign expected_last = beat_count == K_ADDR_WIDTH'(K - 1);
    // ponytail: one result buffer; add a second if output stalls limit throughput.
    assign engine_start  = rst_n && !engine_busy && bank_full[next_compute_bank]
                         && !output_pending && !(engine_done && active_emit);

    assign m_axis_tvalid = output_pending;
    assign m_axis_tdata  = output_buffer[output_index];
    assign m_axis_tlast  = output_pending
                         && output_index == OUTPUT_INDEX_WIDTH'(OUTPUTS - 1);
    assign busy = bank_full != 0 || beat_count != 0 || engine_busy || output_pending;
    assign active_cycle = s_axis_tvalid || bank_full != 0 || beat_count != 0
                        || engine_busy || output_pending;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bank_full          <= '0;
            bank_accumulate    <= '0;
            bank_emit          <= '0;
            write_bank         <= 1'b0;
            next_compute_bank  <= 1'b0;
            incoming_accumulate <= 1'b0;
            incoming_emit      <= 1'b0;
            beat_count         <= '0;
            active_emit        <= 1'b0;
            active_multiplier  <= '0;
            active_shift       <= '0;
            active_zero_point  <= '0;
            output_index       <= '0;
            output_pending     <= 1'b0;
            protocol_error     <= 1'b0;
        end else begin
            if (counters_clear)
                protocol_error <= 1'b0;
            if (input_accept) begin
                if (beat_count == 0) begin
                    incoming_accumulate <= s_axis_tuser[0];
                    incoming_emit       <= s_axis_tuser[1];
                end else if (s_axis_tuser != {incoming_emit, incoming_accumulate}) begin
                    protocol_error <= 1'b1;
                end

                if (s_axis_tlast != expected_last)
                    protocol_error <= 1'b1;

                if (expected_last) begin
                    bank_full[write_bank]       <= 1'b1;
                    bank_accumulate[write_bank] <= (beat_count == 0)
                                                 ? s_axis_tuser[0]
                                                 : incoming_accumulate;
                    bank_emit[write_bank]       <= (beat_count == 0)
                                                 ? s_axis_tuser[1]
                                                 : incoming_emit;
                    bank_multiplier[write_bank] <= requant_multiplier;
                    bank_shift[write_bank]      <= requant_shift;
                    bank_zero_point[write_bank] <= requant_zero_point;
                    write_bank <= ~write_bank;
                    beat_count <= '0;
                end else begin
                    beat_count <= beat_count + 1'b1;
                end
            end

            if (engine_start) begin
                bank_full[next_compute_bank] <= 1'b0;
                active_emit       <= bank_emit[next_compute_bank];
                active_multiplier <= bank_multiplier[next_compute_bank];
                active_shift      <= bank_shift[next_compute_bank];
                active_zero_point <= bank_zero_point[next_compute_bank];
                next_compute_bank <= ~next_compute_bank;
            end

            if (engine_done && active_emit) begin
                for (int row = 0; row < ROWS; row++) begin
                    for (int col = 0; col < COLS; col++)
                        output_buffer[row*COLS+col] <= engine_q[row][col];
                end
                output_index   <= '0;
                output_pending <= 1'b1;
            end else if (m_axis_tvalid && m_axis_tready) begin
                if (m_axis_tlast) begin
                    output_index   <= '0;
                    output_pending <= 1'b0;
                end else begin
                    output_index <= output_index + 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || counters_clear) begin
            total_cycles        <= '0;
            compute_cycles      <= '0;
            input_stall_cycles  <= '0;
            output_stall_cycles <= '0;
            tiles_completed     <= '0;
            results_transferred <= '0;
        end else begin
            if (active_cycle)
                total_cycles <= total_cycles + 1'b1;
            if (engine_busy)
                compute_cycles <= compute_cycles + 1'b1;
            if (s_axis_tvalid && !s_axis_tready)
                input_stall_cycles <= input_stall_cycles + 1'b1;
            if (m_axis_tvalid && !m_axis_tready)
                output_stall_cycles <= output_stall_cycles + 1'b1;
            if (engine_done)
                tiles_completed <= tiles_completed + 1'b1;
            if (m_axis_tvalid && m_axis_tready && m_axis_tlast)
                results_transferred <= results_transferred + 1'b1;
        end
    end

    tiled_gemm #(
        .ROWS              (ROWS),
        .COLS              (COLS),
        .K                 (K),
        .DATA_WIDTH        (DATA_WIDTH),
        .ACC_WIDTH         (ACC_WIDTH),
        .REQUANT_MULT_WIDTH(REQUANT_MULT_WIDTH),
        .BUFFER_RAM_STYLE  (BUFFER_RAM_STYLE)
    ) engine (
        .clk                (clk),
        .rst_n              (rst_n),
        .load_valid         (input_accept),
        .load_ready         (engine_load_ready),
        .load_bank          (write_bank),
        .load_k             (beat_count),
        .a_load             (a_load),
        .b_load             (b_load),
        .start              (engine_start),
        .start_bank         (next_compute_bank),
        .accumulate         (bank_accumulate[next_compute_bank]),
        .requant_multiplier (active_multiplier),
        .requant_shift      (active_shift),
        .requant_zero_point (active_zero_point),
        .busy               (engine_busy),
        .done               (engine_done),
        .result_bank        (unused_result_bank),
        .c_out              (unused_c_out),
        .q_out              (engine_q)
    );
endmodule
