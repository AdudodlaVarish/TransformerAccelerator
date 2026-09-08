`timescale 1ns/1ps

module tb_transformer_gemm_accelerator;
    localparam int ROWS = 4;
    localparam int COLS = 4;
    localparam int K = 5;
    localparam int K_TILES = 2;
    localparam int DATA_WIDTH = 8;
    localparam int S_AXIS_DATA_WIDTH = (ROWS + COLS) * DATA_WIDTH;
    localparam int COMPUTE_CYCLES_PER_TILE = K + ROWS + COLS - 2;

    logic clk;
    logic rst_n;
    logic s_axis_tvalid;
    logic s_axis_tready;
    logic [S_AXIS_DATA_WIDTH-1:0] s_axis_tdata;
    logic s_axis_tlast;
    logic [1:0] s_axis_tuser;
    logic [15:0] requant_multiplier;
    logic [5:0] requant_shift;
    logic signed [7:0] requant_zero_point;
    logic m_axis_tvalid;
    logic m_axis_tready;
    logic signed [7:0] m_axis_tdata;
    logic m_axis_tlast;
    logic counters_clear;
    logic busy;
    logic protocol_error;
    logic [63:0] total_cycles;
    logic [63:0] compute_cycles;
    logic [63:0] input_stall_cycles;
    logic [63:0] output_stall_cycles;
    logic [31:0] tiles_completed;
    logic [31:0] results_transferred;
    integer signed a_matrix[ROWS][K*K_TILES];
    integer signed b_matrix[K*K_TILES][COLS];
    integer signed expected[ROWS][COLS];

    always #5 clk = ~clk;

    transformer_gemm_accelerator #(
        .ROWS(ROWS),
        .COLS(COLS),
        .K(K)
    ) dut (.*);

    task automatic build_case;
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
                assert (expected[row][col] >= -128 && expected[row][col] <= 127)
                    else $fatal(1, "test result exceeds identity INT8 range");
            end
        end
    endtask

    task automatic send_k_tile(
        input int tile,
        input logic accumulate,
        input logic emit,
        input logic must_overlap
    );
        for (int k = 0; k < K; k++) begin
            @(negedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tlast  = k == K - 1;
            s_axis_tuser  = {emit, accumulate};
            s_axis_tdata  = '0;
            for (int row = 0; row < ROWS; row++)
                s_axis_tdata[row*DATA_WIDTH +: DATA_WIDTH] =
                    DATA_WIDTH'(a_matrix[row][tile*K+k]);
            for (int col = 0; col < COLS; col++)
                s_axis_tdata[(ROWS+col)*DATA_WIDTH +: DATA_WIDTH] =
                    DATA_WIDTH'(b_matrix[tile*K+k][col]);
            #1;
            while (!s_axis_tready) begin
                @(posedge clk);
                @(negedge clk);
                #1;
            end
            @(posedge clk);
            #1;
            if (must_overlap)
                assert (busy) else $fatal(1, "second tile load did not overlap compute");
        end
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
    endtask

    task automatic receive_result;
        logic signed [7:0] held_data;
        logic held_last;

        while (!m_axis_tvalid) begin
            @(posedge clk);
            #1;
        end
        held_data = m_axis_tdata;
        held_last = m_axis_tlast;

        repeat (3) begin
            @(posedge clk);
            #1;
            assert (m_axis_tvalid && m_axis_tdata == held_data
                    && m_axis_tlast == held_last)
                else $fatal(1, "output changed while backpressured");
        end

        m_axis_tready = 1'b1;
        for (int index = 0; index < ROWS*COLS; index++) begin
            @(negedge clk);
            #1;
            assert (m_axis_tvalid) else $fatal(1, "output stream ended early");
            assert (int'($signed(m_axis_tdata))
                    == expected[index/COLS][index%COLS])
                else $fatal(1, "output %0d: got %0d, expected %0d", index,
                            $signed(m_axis_tdata), expected[index/COLS][index%COLS]);
            assert (m_axis_tlast == (index == ROWS*COLS-1))
                else $fatal(1, "incorrect output tlast at index %0d", index);
            @(posedge clk);
            #1;
        end
        m_axis_tready = 1'b0;
        assert (!m_axis_tvalid) else $fatal(1, "output valid remained high");
    endtask

    task automatic send_bad_tlast;
        @(negedge clk);
        s_axis_tvalid = 1'b1;
        s_axis_tlast  = 1'b1;
        s_axis_tuser  = '0;
        s_axis_tdata  = '0;
        #1;
        assert (s_axis_tready) else $fatal(1, "input was unexpectedly blocked");
        @(posedge clk);
        #1;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        assert (protocol_error) else $fatal(1, "bad tlast was not detected");
    endtask

    task automatic send_bad_tuser;
        for (int beat = 0; beat < 2; beat++) begin
            @(negedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tlast  = 1'b0;
            s_axis_tuser  = beat == 0 ? 2'b00 : 2'b01;
            s_axis_tdata  = '0;
            #1;
            assert (s_axis_tready) else $fatal(1, "input was unexpectedly blocked");
            @(posedge clk);
            #1;
        end
        s_axis_tvalid = 1'b0;
        assert (protocol_error) else $fatal(1, "changing tuser was not detected");
    endtask

    initial begin
        clk                  = 1'b0;
        rst_n                = 1'b0;
        s_axis_tvalid        = 1'b0;
        s_axis_tdata         = '0;
        s_axis_tlast         = 1'b0;
        s_axis_tuser         = '0;
        requant_multiplier   = 16'd1;
        requant_shift        = '0;
        requant_zero_point   = '0;
        m_axis_tready        = 1'b0;
        counters_clear       = 1'b0;
        build_case();

        repeat (2) @(posedge clk);
        rst_n = 1'b1;

        @(negedge clk);
        counters_clear = 1'b1;
        @(posedge clk);
        #1;
        counters_clear = 1'b0;
        assert (total_cycles == 0 && compute_cycles == 0
                && input_stall_cycles == 0 && output_stall_cycles == 0
                && tiles_completed == 0 && results_transferred == 0)
            else $fatal(1, "counter clear failed");

        send_k_tile(0, 1'b0, 1'b0, 1'b0);
        send_k_tile(1, 1'b1, 1'b1, 1'b1);
        receive_result();

        assert (compute_cycles == 2*COMPUTE_CYCLES_PER_TILE)
            else $fatal(1, "compute counter: got %0d, expected %0d",
                        compute_cycles, 2*COMPUTE_CYCLES_PER_TILE);
        assert (tiles_completed == 2) else $fatal(1, "tile counter mismatch");
        assert (results_transferred == 1) else $fatal(1, "result counter mismatch");
        assert (input_stall_cycles == 0) else $fatal(1, "unexpected input stalls");
        assert (output_stall_cycles == 3) else $fatal(1, "output stall counter mismatch");
        assert (total_cycles > compute_cycles) else $fatal(1, "total cycle counter mismatch");

        send_bad_tlast();

        @(negedge clk);
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        assert (!protocol_error) else $fatal(1, "reset did not clear protocol error");
        rst_n = 1'b1;
        send_bad_tuser();

        $display("PASS: streamed 4x10x4 GEMM with K-tile accumulation and counters");
        $finish;
    end
endmodule
