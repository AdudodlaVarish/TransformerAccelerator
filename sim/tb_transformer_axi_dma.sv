`timescale 1ns/1ps

module tb_transformer_axi_dma #(
    parameter int ROWS = 4,
    parameter int COLS = 4,
    parameter int K = 5,
    parameter int DATA_WIDTH = 8,
    parameter int K_TILES = 2
);
    localparam int AXI_ADDR_WIDTH = 32;
    localparam int AXI_DATA_WIDTH = (ROWS + COLS) * DATA_WIDTH;
    localparam int AXI_BYTES = AXI_DATA_WIDTH / 8;
    localparam int SOURCE_ADDRESS = 32'h0000_0fe0;
    localparam int DESTINATION_ADDRESS = 32'h0000_2000;
    localparam int SOURCE_WORD = SOURCE_ADDRESS / AXI_BYTES;
    localparam int DESTINATION_WORD = DESTINATION_ADDRESS / AXI_BYTES;
    localparam int COMPUTE_CYCLES_PER_TILE = K + ROWS + COLS - 2;
    localparam int OUTPUT_WORDS =
        (ROWS*COLS*DATA_WIDTH + AXI_DATA_WIDTH - 1) / AXI_DATA_WIDTH;

    logic clk;
    logic rst_n;
    logic start;
    logic [AXI_ADDR_WIDTH-1:0] source_address;
    logic [AXI_ADDR_WIDTH-1:0] destination_address;
    logic [15:0] k_tiles;
    logic [15:0] requant_multiplier;
    logic [$clog2(32+16+2)-1:0] requant_shift;
    logic signed [DATA_WIDTH-1:0] requant_zero_point;
    logic busy;
    logic done;
    logic error;

    logic m_axi_arvalid;
    logic m_axi_arready;
    logic [AXI_ADDR_WIDTH-1:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_rvalid;
    logic m_axi_rready;
    logic [AXI_DATA_WIDTH-1:0] m_axi_rdata;
    logic m_axi_rlast;
    logic [1:0] m_axi_rresp;

    logic m_axi_awvalid;
    logic m_axi_awready;
    logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_wvalid;
    logic m_axi_wready;
    logic [AXI_DATA_WIDTH-1:0] m_axi_wdata;
    logic [AXI_BYTES-1:0] m_axi_wstrb;
    logic m_axi_wlast;
    logic m_axi_bvalid;
    logic m_axi_bready;
    logic [1:0] m_axi_bresp;

    logic [63:0] memory_read_beats;
    logic [63:0] memory_write_beats;
    logic [63:0] total_cycles;
    logic [63:0] compute_cycles;
    logic [63:0] input_stall_cycles;
    logic [63:0] output_stall_cycles;
    logic [31:0] tiles_completed;
    logic [31:0] results_transferred;

    logic [AXI_DATA_WIDTH-1:0] memory[0:4095];
    integer signed a_matrix[ROWS][K*K_TILES];
    integer signed b_matrix[K*K_TILES][COLS];
    integer signed expected[ROWS][COLS];

    logic read_active;
    integer read_word;
    integer read_left;
    integer read_burst_count;
    integer read_burst_lengths[0:255];

    logic write_active;
    integer write_word;
    integer write_left;
    integer write_burst_count;
    integer write_burst_length;
    logic [1:0] write_stall_count;
    integer timeout;

    always #5 clk <= ~clk;

    assign m_axi_arready = !read_active;
    assign m_axi_rvalid  = read_active;
    assign m_axi_rdata   = memory[read_word];
    assign m_axi_rlast   = read_active && read_left == 1;
    assign m_axi_rresp   = 2'b00;

    assign m_axi_awready = !write_active && !m_axi_bvalid;
    assign m_axi_wready  = write_active && write_stall_count == 2;
    assign m_axi_bresp   = 2'b00;

    transformer_axi_dma #(
        .ROWS(ROWS),
        .COLS(COLS),
        .K(K),
        .DATA_WIDTH(DATA_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .MAX_READ_BURST(4)
    ) dut (.*);

    task automatic build_case;
        for (int word = 0; word < 4096; word++)
            memory[word] = '0;

        for (int row = 0; row < ROWS; row++) begin
            for (int k = 0; k < K*K_TILES; k++)
                a_matrix[row][k] = ((row * 2 + k * 3 + 1) % 5) - 2;
        end
        for (int k = 0; k < K*K_TILES; k++) begin
            for (int col = 0; col < COLS; col++)
                b_matrix[k][col] = ((k * 2 - col + 3) % 5) - 2;
        end
        for (int row = 0; row < ROWS; row++) begin
            for (int col = 0; col < COLS; col++) begin
                expected[row][col] = 0;
                for (int k = 0; k < K*K_TILES; k++)
                    expected[row][col] += a_matrix[row][k] * b_matrix[k][col];
                if (expected[row][col] < 0)
                    expected[row][col] = -((-expected[row][col] + 2) >>> 2);
                else
                    expected[row][col] = (expected[row][col] + 2) >>> 2;
                assert (expected[row][col] >= -(1 << (DATA_WIDTH-1))
                        && expected[row][col] < (1 << (DATA_WIDTH-1)))
                    else $fatal(1, "test result exceeds signed output range");
            end
        end

        for (int tile = 0; tile < K_TILES; tile++) begin
            for (int k = 0; k < K; k++) begin
                for (int row = 0; row < ROWS; row++)
                    memory[SOURCE_WORD+tile*K+k][row*DATA_WIDTH +: DATA_WIDTH] =
                        DATA_WIDTH'(a_matrix[row][tile*K+k]);
                for (int col = 0; col < COLS; col++)
                    memory[SOURCE_WORD+tile*K+k][(ROWS+col)*DATA_WIDTH +: DATA_WIDTH] =
                        DATA_WIDTH'(b_matrix[tile*K+k][col]);
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            read_active      <= 1'b0;
            read_word        <= 0;
            read_left        <= 0;
            read_burst_count <= 0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) begin
                assert (m_axi_arsize == 3'($clog2(AXI_BYTES))
                        && m_axi_arburst == 2'b01)
                    else $fatal(1, "bad AXI read attributes");
                assert (int'(m_axi_arlen) + 1 <= 4
                        && int'($unsigned(m_axi_araddr[11:0]))
                           + (int'(m_axi_arlen) + 1) * AXI_BYTES <= 4096)
                    else $fatal(1, "AXI read burst exceeds limit: addr=%h len=%0d bytes=%0d",
                                m_axi_araddr, int'(m_axi_arlen) + 1, AXI_BYTES);
                read_active <= 1'b1;
                read_word   <= m_axi_araddr / AXI_BYTES;
                read_left   <= int'(m_axi_arlen) + 1;
                read_burst_lengths[read_burst_count] <= int'(m_axi_arlen) + 1;
                read_burst_count <= read_burst_count + 1;
            end
            if (m_axi_rvalid && m_axi_rready) begin
                if (read_left == 1) begin
                    read_active <= 1'b0;
                    read_left   <= 0;
                end else begin
                    read_word <= read_word + 1;
                    read_left <= read_left - 1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            write_active      <= 1'b0;
            write_word        <= 0;
            write_left        <= 0;
            write_burst_count <= 0;
            write_burst_length <= 0;
            m_axi_bvalid      <= 1'b0;
            write_stall_count <= '0;
        end else begin
            if (m_axi_wvalid && !m_axi_wready)
                write_stall_count <= write_stall_count + 1'b1;
            else if (m_axi_wvalid && m_axi_wready)
                write_stall_count <= '0;
            if (m_axi_awvalid && m_axi_awready) begin
                assert (m_axi_awaddr == DESTINATION_ADDRESS
                        && m_axi_awsize == 3'($clog2(AXI_BYTES))
                        && m_axi_awburst == 2'b01)
                    else $fatal(1, "bad AXI write address or attributes");
                write_active       <= 1'b1;
                write_word         <= m_axi_awaddr / AXI_BYTES;
                write_left         <= int'(m_axi_awlen) + 1;
                write_burst_length <= int'(m_axi_awlen) + 1;
                write_burst_count  <= write_burst_count + 1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                assert (m_axi_wlast == (write_left == 1))
                    else $fatal(1, "bad AXI wlast");
                for (int byte_index = 0; byte_index < AXI_BYTES; byte_index++) begin
                    if (m_axi_wstrb[byte_index])
                        memory[write_word][byte_index*8 +: 8]
                            <= m_axi_wdata[byte_index*8 +: 8];
                end
                if (write_left == 1) begin
                    write_active <= 1'b0;
                    write_left   <= 0;
                    m_axi_bvalid <= 1'b1;
                end else begin
                    write_word <= write_word + 1;
                    write_left <= write_left - 1;
                end
            end
            if (m_axi_bvalid && m_axi_bready)
                m_axi_bvalid <= 1'b0;
        end
    end

    initial begin
        clk                  = 1'b0;
        rst_n                = 1'b0;
        start                = 1'b0;
        source_address       = SOURCE_ADDRESS;
        destination_address  = DESTINATION_ADDRESS;
        k_tiles              = 16'(K_TILES);
        requant_multiplier   = 16'd1;
        requant_shift        = 6'd2;
        requant_zero_point   = '0;
        build_case();

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;
        assert (!busy && !done && !error && !m_axi_arvalid && !m_axi_awvalid)
            else $fatal(1, "DMA did not reset idle");

        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        assert (busy) else $fatal(1, "DMA did not accept command");

        // Descriptor settings must remain stable even if software changes the ports.
        requant_multiplier = 16'd2;
        requant_shift = '0;
        requant_zero_point = DATA_WIDTH'(-1);

        timeout = 0;
        while (!done && timeout < 1000) begin
            @(posedge clk);
            #1;
            timeout++;
        end
        assert (done && !busy && !error) else $fatal(1, "DMA timed out or failed");

        for (int index = 0; index < ROWS*COLS; index++) begin
            assert (int'($signed(memory[DESTINATION_WORD
                                        + (index*DATA_WIDTH)/AXI_DATA_WIDTH]
                                      [(index*DATA_WIDTH)%AXI_DATA_WIDTH
                                       +: DATA_WIDTH]))
                    == expected[index/COLS][index%COLS])
                else $fatal(1, "output %0d: got %0d, expected %0d", index,
                            $signed(memory[DESTINATION_WORD
                                           + (index*DATA_WIDTH)/AXI_DATA_WIDTH]
                                          [(index*DATA_WIDTH)%AXI_DATA_WIDTH
                                           +: DATA_WIDTH]),
                            expected[index/COLS][index%COLS]);
        end

        assert (read_burst_count > 0
                && read_burst_lengths[0]
                   == ((4096 - (SOURCE_ADDRESS & 4095)) / AXI_BYTES < 4
                       ? (4096 - (SOURCE_ADDRESS & 4095)) / AXI_BYTES : 4))
            else $fatal(1, "first read burst was not boundary limited");
        assert (write_burst_count == 1 && write_burst_length == OUTPUT_WORDS)
            else $fatal(1, "unexpected write burst");
        assert (memory_read_beats == K*K_TILES
                && memory_write_beats == 64'(OUTPUT_WORDS))
            else $fatal(1, "memory beat counter mismatch");
        assert (compute_cycles == K_TILES*COMPUTE_CYCLES_PER_TILE)
            else $fatal(1, "compute cycle counter mismatch");
        assert (tiles_completed == K_TILES && results_transferred == 1)
            else $fatal(1, "tile/result counter mismatch");
        assert (output_stall_cycles
                == 64'(3) * (64'(OUTPUT_WORDS) - 64'(1)))
            else $fatal(1, "output stall counter mismatch");
        assert (total_cycles > compute_cycles)
            else $fatal(1, "total cycle counter mismatch");
        if (ROWS == 16 && COLS == 16 && K == 16 && K_TILES == 1) begin
            assert (total_cycles * 10 < ROWS*COLS*K*K_TILES)
                else $fatal(1, "16x16 benchmark fell below 10x speedup");
        end

        $display("PASS: INT%0d %0dx%0dx%0d DMA GEMM used %0d cycles vs %0d scalar MAC cycles (%f x, input stalls=%0d)",
                 DATA_WIDTH, ROWS, K*K_TILES, COLS, total_cycles,
                 ROWS*COLS*K*K_TILES,
                 $itor(ROWS*COLS*K*K_TILES) / $itor(total_cycles),
                 input_stall_cycles);

        @(negedge clk);
        source_address = SOURCE_ADDRESS + 1;
        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        assert (done && error && !busy)
            else $fatal(1, "misaligned command was not rejected");

        $finish;
    end
endmodule
