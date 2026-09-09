`timescale 1ns/1ps

module transformer_axi_dma #(
    parameter int ROWS       = 4,
    parameter int COLS       = 4,
    parameter int K          = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int REQUANT_MULT_WIDTH = 16,
    parameter string BUFFER_RAM_STYLE = "block",
    parameter int AXI_ADDR_WIDTH = 32,
    parameter int AXI_DATA_WIDTH = (ROWS + COLS) * DATA_WIDTH,
    parameter int MAX_READ_BURST = 16,
    localparam int AXI_BYTES = AXI_DATA_WIDTH / 8,
    localparam int AXI_SIZE = $clog2(AXI_BYTES),
    localparam int OUTPUTS = ROWS * COLS,
    localparam int PACK_FACTOR = AXI_DATA_WIDTH / DATA_WIDTH,
    localparam int OUTPUT_WORDS = (OUTPUTS + PACK_FACTOR - 1) / PACK_FACTOR,
    localparam int PACK_INDEX_WIDTH = (PACK_FACTOR <= 1) ? 1 : $clog2(PACK_FACTOR),
    localparam int WRITE_INDEX_WIDTH = (OUTPUT_WORDS <= 1) ? 1 : $clog2(OUTPUT_WORDS + 1),
    localparam int K_ADDR_WIDTH = (K <= 1) ? 1 : $clog2(K),
    localparam int REQUANT_SHIFT_WIDTH =
        $clog2(ACC_WIDTH + REQUANT_MULT_WIDTH + 2)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic                          start,
    input  logic [AXI_ADDR_WIDTH-1:0]     source_address,
    input  logic [AXI_ADDR_WIDTH-1:0]     destination_address,
    input  logic [15:0]                   k_tiles,
    input  logic [REQUANT_MULT_WIDTH-1:0] requant_multiplier,
    input  logic [REQUANT_SHIFT_WIDTH-1:0] requant_shift,
    input  logic signed [DATA_WIDTH-1:0]  requant_zero_point,
    output logic                          busy,
    output logic                          done,
    output logic                          error,

    output logic                          m_axi_arvalid,
    input  logic                          m_axi_arready,
    output logic [AXI_ADDR_WIDTH-1:0]     m_axi_araddr,
    output logic [7:0]                    m_axi_arlen,
    output logic [2:0]                    m_axi_arsize,
    output logic [1:0]                    m_axi_arburst,
    input  logic                          m_axi_rvalid,
    output logic                          m_axi_rready,
    input  logic [AXI_DATA_WIDTH-1:0]     m_axi_rdata,
    input  logic                          m_axi_rlast,
    input  logic [1:0]                    m_axi_rresp,

    output logic                          m_axi_awvalid,
    input  logic                          m_axi_awready,
    output logic [AXI_ADDR_WIDTH-1:0]     m_axi_awaddr,
    output logic [7:0]                    m_axi_awlen,
    output logic [2:0]                    m_axi_awsize,
    output logic [1:0]                    m_axi_awburst,
    output logic                          m_axi_wvalid,
    input  logic                          m_axi_wready,
    output logic [AXI_DATA_WIDTH-1:0]     m_axi_wdata,
    output logic [AXI_BYTES-1:0]          m_axi_wstrb,
    output logic                          m_axi_wlast,
    input  logic                          m_axi_bvalid,
    output logic                          m_axi_bready,
    input  logic [1:0]                    m_axi_bresp,

    output logic [63:0]                   memory_read_beats,
    output logic [63:0]                   memory_write_beats,
    output logic [63:0]                   total_cycles,
    output logic [63:0]                   compute_cycles,
    output logic [63:0]                   input_stall_cycles,
    output logic [63:0]                   output_stall_cycles,
    output logic [31:0]                   tiles_completed,
    output logic [31:0]                   results_transferred
);
    logic [AXI_ADDR_WIDTH-1:0] read_address;
    logic [AXI_ADDR_WIDTH-1:0] destination_address_reg;
    logic [31:0] read_beats_remaining;
    logic [8:0] read_burst_beats;
    logic [8:0] read_burst_left;
    logic read_burst_active;
    logic running;
    logic aw_sent;
    logic [15:0] k_tiles_reg;
    logic [REQUANT_MULT_WIDTH-1:0] requant_multiplier_reg;
    logic [REQUANT_SHIFT_WIDTH-1:0] requant_shift_reg;
    logic signed [DATA_WIDTH-1:0] requant_zero_point_reg;
    logic [15:0] input_tile;
    logic [K_ADDR_WIDTH-1:0] input_k;
    logic [12:0] boundary_beats;
    logic [12:0] bytes_to_4k;
    logic [31:0] burst_limit;

    logic [AXI_DATA_WIDTH-1:0] pack_data;
    logic [AXI_BYTES-1:0] pack_strb;
    logic [PACK_INDEX_WIDTH-1:0] pack_index;
    logic pack_valid;
    logic [WRITE_INDEX_WIDTH-1:0] write_word_index;

    logic core_s_valid;
    logic core_s_ready;
    logic core_s_last;
    logic [1:0] core_s_user;
    logic core_m_valid;
    logic core_m_ready;
    logic signed [DATA_WIDTH-1:0] core_m_data;
    logic core_m_last;
    logic core_protocol_error;
    logic unused_core_busy;
    logic [63:0] unused_core_total_cycles;
    logic core_input_accept;
    logic core_output_accept;

    initial begin
        if (DATA_WIDTH != 4 && DATA_WIDTH != 8)
            $error("transformer_axi_dma supports INT4 or INT8 data");
        if (AXI_DATA_WIDTH != (ROWS + COLS) * DATA_WIDTH)
            $error("AXI_DATA_WIDTH must equal one packed GEMM input beat");
        if (AXI_BYTES <= 0 || (AXI_BYTES & (AXI_BYTES - 1)) != 0)
            $error("AXI data width must contain a power-of-two number of bytes");
        if (AXI_BYTES > 128)
            $error("AXI beat size must fit the 3-bit AxSIZE field");
        if (MAX_READ_BURST < 1 || MAX_READ_BURST > 256)
            $error("MAX_READ_BURST must be between 1 and 256");
        if (OUTPUT_WORDS > 256)
            $error("one output tile must fit in one AXI burst");
        if (AXI_ADDR_WIDTH < 12)
            $error("AXI_ADDR_WIDTH must be at least 12 for 4 KiB burst checks");
    end

    always_comb begin
        bytes_to_4k = 13'd4096 - {1'b0, read_address[11:0]};
        boundary_beats = bytes_to_4k >> AXI_SIZE;
        burst_limit = read_beats_remaining;
        if (burst_limit > MAX_READ_BURST)
            burst_limit = MAX_READ_BURST;
        if (burst_limit > boundary_beats)
            burst_limit = 32'(boundary_beats);
        read_burst_beats = 9'(burst_limit);

        m_axi_arvalid = running && !read_burst_active
                      && read_beats_remaining != 0;
        m_axi_araddr  = read_address;
        m_axi_arlen   = 8'(read_burst_beats - 1'b1);
        m_axi_arsize  = 3'(AXI_SIZE);
        m_axi_arburst = 2'b01;

        core_s_valid = m_axi_rvalid && read_burst_active;
        core_s_last  = input_k == K_ADDR_WIDTH'(K - 1);
        core_s_user  = {input_tile == k_tiles_reg - 1'b1, input_tile != 0};
        m_axi_rready = core_s_ready && read_burst_active;
        core_input_accept = core_s_valid && core_s_ready;

        m_axi_awvalid = running && !aw_sent;
        m_axi_awaddr  = destination_address_reg;
        m_axi_awlen   = 8'(OUTPUT_WORDS - 1);
        m_axi_awsize  = 3'(AXI_SIZE);
        m_axi_awburst = 2'b01;

        core_m_ready = running && !pack_valid;
        core_output_accept = core_m_valid && core_m_ready;
        m_axi_wvalid = pack_valid && aw_sent;
        m_axi_wdata  = pack_data;
        m_axi_wstrb  = pack_strb;
        m_axi_wlast  = write_word_index == WRITE_INDEX_WIDTH'(OUTPUT_WORDS - 1);
        m_axi_bready = running;
    end

    assign busy = running;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            done                    <= 1'b0;
            error                   <= 1'b0;
            read_address            <= '0;
            destination_address_reg <= '0;
            read_beats_remaining    <= '0;
            read_burst_left         <= '0;
            read_burst_active       <= 1'b0;
            running                 <= 1'b0;
            aw_sent                 <= 1'b0;
            k_tiles_reg             <= '0;
            requant_multiplier_reg  <= '0;
            requant_shift_reg       <= '0;
            requant_zero_point_reg  <= '0;
            input_tile              <= '0;
            input_k                 <= '0;
            pack_data               <= '0;
            pack_strb               <= '0;
            pack_index              <= '0;
            pack_valid              <= 1'b0;
            write_word_index        <= '0;
            memory_read_beats       <= '0;
            memory_write_beats      <= '0;
            total_cycles            <= '0;
        end else begin
            done <= 1'b0;

            if (start && !running) begin
                error              <= 1'b0;
                running            <= 1'b1;
                read_address       <= source_address;
                destination_address_reg <= destination_address;
                read_burst_left    <= '0;
                read_burst_active  <= 1'b0;
                aw_sent            <= 1'b0;
                k_tiles_reg        <= k_tiles;
                requant_multiplier_reg <= requant_multiplier;
                requant_shift_reg      <= requant_shift;
                requant_zero_point_reg <= requant_zero_point;
                input_tile         <= '0;
                input_k            <= '0;
                pack_data          <= '0;
                pack_strb          <= '0;
                pack_index         <= '0;
                pack_valid         <= 1'b0;
                write_word_index   <= '0;
                memory_read_beats  <= '0;
                memory_write_beats <= '0;
                total_cycles       <= '0;

                if (k_tiles == 0
                        || (source_address
                            & AXI_ADDR_WIDTH'(AXI_BYTES - 1)) != 0
                        || (destination_address
                            & AXI_ADDR_WIDTH'(AXI_BYTES - 1)) != 0
                        // ponytail: one output burst; split it if tiles exceed 256 beats.
                        || int'($unsigned(destination_address[11:0]))
                           + OUTPUT_WORDS * AXI_BYTES > 4096) begin
                    read_beats_remaining <= '0;
                    k_tiles_reg          <= '0;
                    write_word_index     <= WRITE_INDEX_WIDTH'(OUTPUT_WORDS);
                    running              <= 1'b0;
                    error                <= 1'b1;
                    done                 <= 1'b1;
                end else begin
                    read_beats_remaining <= 32'(k_tiles) * 32'(K);
                end
            end else if (running) begin
                total_cycles <= total_cycles + 1'b1;
                if (core_protocol_error)
                    error <= 1'b1;

                if (m_axi_arvalid && m_axi_arready) begin
                    read_address <= read_address
                                  + AXI_ADDR_WIDTH'(read_burst_beats * AXI_BYTES);
                    read_beats_remaining <= read_beats_remaining
                                          - 32'(read_burst_beats);
                    read_burst_left   <= read_burst_beats;
                    read_burst_active <= 1'b1;
                end

                if (core_input_accept) begin
                    memory_read_beats <= memory_read_beats + 1'b1;
                    if (m_axi_rresp != 2'b00
                            || m_axi_rlast != (read_burst_left == 1))
                        error <= 1'b1;

                    if (read_burst_left == 1) begin
                        read_burst_left   <= '0;
                        read_burst_active <= 1'b0;
                    end else begin
                        read_burst_left <= read_burst_left - 1'b1;
                    end

                    if (core_s_last) begin
                        input_k    <= '0;
                        input_tile <= input_tile + 1'b1;
                    end else begin
                        input_k <= input_k + 1'b1;
                    end
                end

                if (m_axi_awvalid && m_axi_awready)
                    aw_sent <= 1'b1;

                if (core_output_accept) begin
                    pack_data[pack_index*DATA_WIDTH +: DATA_WIDTH] <= core_m_data;
                    pack_strb[(pack_index*DATA_WIDTH)/8] <= 1'b1;
                    if (pack_index == PACK_INDEX_WIDTH'(PACK_FACTOR - 1)
                            || core_m_last) begin
                        pack_index <= '0;
                        pack_valid <= 1'b1;
                    end else begin
                        pack_index <= pack_index + 1'b1;
                    end
                end

                if (m_axi_wvalid && m_axi_wready) begin
                    pack_data          <= '0;
                    pack_strb          <= '0;
                    pack_valid         <= 1'b0;
                    write_word_index   <= write_word_index + 1'b1;
                    memory_write_beats <= memory_write_beats + 1'b1;
                end

                if (m_axi_bvalid && m_axi_bready) begin
                    if (m_axi_bresp != 2'b00)
                        error <= 1'b1;
                    running <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

    transformer_gemm_accelerator #(
        .ROWS              (ROWS),
        .COLS              (COLS),
        .K                 (K),
        .DATA_WIDTH        (DATA_WIDTH),
        .ACC_WIDTH         (ACC_WIDTH),
        .REQUANT_MULT_WIDTH(REQUANT_MULT_WIDTH),
        .BUFFER_RAM_STYLE  (BUFFER_RAM_STYLE)
    ) core (
        .clk                (clk),
        .rst_n              (rst_n),
        .s_axis_tvalid      (core_s_valid),
        .s_axis_tready      (core_s_ready),
        .s_axis_tdata       (m_axi_rdata),
        .s_axis_tlast       (core_s_last),
        .s_axis_tuser       (core_s_user),
        .requant_multiplier (requant_multiplier_reg),
        .requant_shift      (requant_shift_reg),
        .requant_zero_point (requant_zero_point_reg),
        .m_axis_tvalid      (core_m_valid),
        .m_axis_tready      (core_m_ready),
        .m_axis_tdata       (core_m_data),
        .m_axis_tlast       (core_m_last),
        .counters_clear     (start && !running),
        .busy               (unused_core_busy),
        .protocol_error     (core_protocol_error),
        .total_cycles       (unused_core_total_cycles),
        .compute_cycles     (compute_cycles),
        .input_stall_cycles (input_stall_cycles),
        .output_stall_cycles(output_stall_cycles),
        .tiles_completed    (tiles_completed),
        .results_transferred(results_transferred)
    );
endmodule
