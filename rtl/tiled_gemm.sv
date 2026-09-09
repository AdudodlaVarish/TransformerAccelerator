`timescale 1ns/1ps

module tiled_gemm #(
    parameter int ROWS       = 4,
    parameter int COLS       = 4,
    parameter int K          = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int REQUANT_MULT_WIDTH = 16,
    parameter string BUFFER_RAM_STYLE = "block",
    localparam int K_ADDR_WIDTH = (K <= 1) ? 1 : $clog2(K),
    localparam int TOTAL_CYCLES = K + ROWS + COLS - 2,
    localparam int FEED_WIDTH   = $clog2(TOTAL_CYCLES + 1),
    localparam int REQUANT_SHIFT_WIDTH =
        $clog2(ACC_WIDTH + REQUANT_MULT_WIDTH + 2)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         load_valid,
    output logic                         load_ready,
    input  logic                         load_bank,
    input  logic        [K_ADDR_WIDTH-1:0] load_k,
    input  logic signed [DATA_WIDTH-1:0] a_load[ROWS],
    input  logic signed [DATA_WIDTH-1:0] b_load[COLS],

    input  logic                         start,
    input  logic                         start_bank,
    input  logic                         accumulate,
    input  logic        [REQUANT_MULT_WIDTH-1:0] requant_multiplier,
    input  logic        [REQUANT_SHIFT_WIDTH-1:0] requant_shift,
    input  logic signed [DATA_WIDTH-1:0] requant_zero_point,
    output logic                         busy,
    output logic                         done,
    output logic                         result_bank,
    output logic signed [ACC_WIDTH-1:0]  c_out[ROWS][COLS],
    output logic signed [DATA_WIDTH-1:0] q_out[ROWS][COLS]
);
    (* ram_style = BUFFER_RAM_STYLE *)
    logic signed [DATA_WIDTH-1:0] a_buffer[2][ROWS][K];
    (* ram_style = BUFFER_RAM_STYLE *)
    logic signed [DATA_WIDTH-1:0] b_buffer[2][COLS][K];
    logic signed [DATA_WIDTH-1:0] a_stream[ROWS];
    logic signed [DATA_WIDTH-1:0] b_stream[COLS];
    logic        [FEED_WIDTH-1:0] feed_cycle;
    logic                         feeding;
    logic                         array_start;
    logic                         bank_conflict;
    logic                         active_accumulate;
    logic signed [ACC_WIDTH-1:0]  previous_sum[ROWS][COLS];
    logic signed [ACC_WIDTH-1:0]  array_c_out[ROWS][COLS];

    initial begin
        if (BUFFER_RAM_STYLE != "block" && BUFFER_RAM_STYLE != "ultra")
            $error("BUFFER_RAM_STYLE must be block or ultra");
    end

    always_comb begin
        array_start  = rst_n && start && !busy;
        bank_conflict = (busy && load_bank == result_bank)
                      || (array_start && load_bank == start_bank);
        load_ready = rst_n && !bank_conflict
                   && int'($unsigned(load_k)) < K;
    end

    always_ff @(posedge clk) begin
        if (load_valid && load_ready) begin
            for (int row = 0; row < ROWS; row++)
                a_buffer[load_bank][row][load_k] <= a_load[row];
            for (int col = 0; col < COLS; col++)
                b_buffer[load_bank][col][load_k] <= b_load[col];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            result_bank <= 1'b0;
            feed_cycle  <= '0;
            feeding     <= 1'b0;
            for (int row = 0; row < ROWS; row++) a_stream[row] <= '0;
            for (int col = 0; col < COLS; col++) b_stream[col] <= '0;
        end else if (array_start) begin
            result_bank <= start_bank;
            feed_cycle  <= FEED_WIDTH'(1);
            feeding     <= TOTAL_CYCLES > 1;
            for (int row = 0; row < ROWS; row++)
                a_stream[row] <= (row == 0) ? a_buffer[start_bank][row][0] : '0;
            for (int col = 0; col < COLS; col++)
                b_stream[col] <= (col == 0) ? b_buffer[start_bank][col][0] : '0;
        end else if (feeding) begin
            for (int row = 0; row < ROWS; row++) begin
                if (int'($unsigned(feed_cycle)) >= row
                        && int'($unsigned(feed_cycle)) < row + K)
                    a_stream[row] <= a_buffer[result_bank][row]
                        [int'($unsigned(feed_cycle)) - row];
                else
                    a_stream[row] <= '0;
            end
            for (int col = 0; col < COLS; col++) begin
                if (int'($unsigned(feed_cycle)) >= col
                        && int'($unsigned(feed_cycle)) < col + K)
                    b_stream[col] <= b_buffer[result_bank][col]
                        [int'($unsigned(feed_cycle)) - col];
                else
                    b_stream[col] <= '0;
            end
            if (feed_cycle == FEED_WIDTH'(TOTAL_CYCLES - 1))
                feeding <= 1'b0;
            else
                feed_cycle <= feed_cycle + 1'b1;
        end else begin
            for (int row = 0; row < ROWS; row++) a_stream[row] <= '0;
            for (int col = 0; col < COLS; col++) b_stream[col] <= '0;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active_accumulate <= 1'b0;
            for (int row = 0; row < ROWS; row++)
                for (int col = 0; col < COLS; col++)
                    previous_sum[row][col] <= '0;
        end else begin
            if (done) begin
                for (int row = 0; row < ROWS; row++)
                    for (int col = 0; col < COLS; col++)
                        previous_sum[row][col] <= c_out[row][col];
            end
            if (array_start)
                active_accumulate <= accumulate;
        end
    end

    systolic_array #(
        .ROWS      (ROWS),
        .COLS      (COLS),
        .K         (K),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) array (
        .clk  (clk),
        .rst_n(rst_n),
        .start(array_start),
        .a_in (a_stream),
        .b_in (b_stream),
        .c_out(array_c_out),
        .busy (busy),
        .done (done)
    );

    for (genvar row = 0; row < ROWS; row++) begin : gen_output_rows
        for (genvar col = 0; col < COLS; col++) begin : gen_output_cols
            always_comb begin
                c_out[row][col] = active_accumulate
                                ? previous_sum[row][col] + array_c_out[row][col]
                                : array_c_out[row][col];
            end

            requantize #(
                .IN_WIDTH  (ACC_WIDTH),
                .OUT_WIDTH (DATA_WIDTH),
                .MULT_WIDTH(REQUANT_MULT_WIDTH)
            ) output_quantizer (
                .value     (c_out[row][col]),
                .multiplier(requant_multiplier),
                .shift     (requant_shift),
                .zero_point(requant_zero_point),
                .result    (q_out[row][col])
            );
        end
    end
endmodule
