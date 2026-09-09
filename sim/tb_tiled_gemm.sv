`timescale 1ns/1ps

module tb_tiled_gemm;
    localparam int ROWS = 4;
    localparam int COLS = 4;
    localparam int K    = 5;
    localparam int K_ADDR_WIDTH = $clog2(K);

    logic clk;
    logic rst_n;
    logic load_valid;
    logic load_ready;
    logic load_bank;
    logic [K_ADDR_WIDTH-1:0] load_k;
    logic signed [7:0] a_load[ROWS];
    logic signed [7:0] b_load[COLS];
    logic start;
    logic start_bank;
    logic accumulate;
    logic [15:0] requant_multiplier;
    logic [5:0] requant_shift;
    logic signed [7:0] requant_zero_point;
    logic busy;
    logic done;
    logic result_bank;
    logic signed [31:0] c_out[ROWS][COLS];
    logic signed [7:0] q_out[ROWS][COLS];
    integer signed a_matrix[2][ROWS][K];
    integer signed b_matrix[2][K][COLS];
    integer signed expected[2][ROWS][COLS];

    always #5 clk <= ~clk;

    tiled_gemm #(
        .ROWS(ROWS),
        .COLS(COLS),
        .K(K)
    ) dut (.*);

    function automatic integer signed clamp_int8(input integer signed value);
        if (value > 127)
            clamp_int8 = 127;
        else if (value < -128)
            clamp_int8 = -128;
        else
            clamp_int8 = value;
    endfunction

    task automatic build_case(input logic bank, input int seed);
        for (int row = 0; row < ROWS; row++) begin
            for (int k = 0; k < K; k++)
                a_matrix[bank][row][k] = ((row * 3 + k * 2 + seed) % 11) - 5;
        end
        for (int k = 0; k < K; k++) begin
            for (int col = 0; col < COLS; col++)
                b_matrix[bank][k][col] = ((k * 4 - col * 3 + seed) % 13) - 6;
        end
        for (int row = 0; row < ROWS; row++) begin
            for (int col = 0; col < COLS; col++) begin
                expected[bank][row][col] = 0;
                for (int k = 0; k < K; k++)
                    expected[bank][row][col] +=
                        a_matrix[bank][row][k] * b_matrix[bank][k][col];
            end
        end
    endtask

    task automatic load_tile(input logic bank, input logic must_overlap);
        for (int k = 0; k < K; k++) begin
            @(negedge clk);
            load_bank  = bank;
            load_k     = K_ADDR_WIDTH'(k);
            load_valid = 1'b1;
            for (int row = 0; row < ROWS; row++)
                a_load[row] = 8'(a_matrix[bank][row][k]);
            for (int col = 0; col < COLS; col++)
                b_load[col] = 8'(b_matrix[bank][k][col]);
            #1;
            assert (load_ready) else $fatal(1, "bank %0d was not writable", bank);
            if (must_overlap)
                assert (busy) else $fatal(1, "load did not overlap computation");
            @(posedge clk);
            #1;
        end
        load_valid = 1'b0;
    endtask

    task automatic start_tile(input logic bank, input logic add_previous);
        @(negedge clk);
        start_bank = bank;
        accumulate = add_previous;
        start      = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        assert (busy) else $fatal(1, "tile did not start");
    endtask

    task automatic check_tile(input logic bank, input logic add_previous);
        integer signed target;
        while (!done) begin
            @(posedge clk);
            #1;
        end
        assert (!busy) else $fatal(1, "busy remained high after done");
        assert (result_bank == bank) else $fatal(1, "wrong result bank tag");
        for (int row = 0; row < ROWS; row++) begin
            for (int col = 0; col < COLS; col++) begin
                target = expected[bank][row][col]
                       + (add_previous ? expected[0][row][col] : 0);
                assert ($signed(c_out[row][col]) == target)
                    else $fatal(1, "bank %0d C[%0d][%0d]: got %0d, expected %0d",
                                bank, row, col, $signed(c_out[row][col]), target);
                assert (int'($signed(q_out[row][col])) == clamp_int8(target))
                    else $fatal(1, "bank %0d Q[%0d][%0d]: got %0d, expected %0d",
                                bank, row, col, $signed(q_out[row][col]),
                                clamp_int8(target));
            end
        end
    endtask

    task automatic try_active_bank_write;
        @(negedge clk);
        load_bank  = 1'b0;
        load_k     = '0;
        load_valid = 1'b1;
        for (int row = 0; row < ROWS; row++) a_load[row] = 8'sd99;
        for (int col = 0; col < COLS; col++) b_load[col] = 8'sd99;
        #1;
        assert (!load_ready) else $fatal(1, "active-bank write was not blocked");
        @(posedge clk);
        #1;
        load_valid = 1'b0;
    endtask

    initial begin
        clk                 = 1'b0;
        rst_n               = 1'b0;
        load_valid          = 1'b0;
        load_bank           = 1'b0;
        load_k              = '0;
        start               = 1'b0;
        start_bank          = 1'b0;
        accumulate          = 1'b0;
        requant_multiplier  = 16'd1;
        requant_shift       = '0;
        requant_zero_point  = '0;
        for (int row = 0; row < ROWS; row++) a_load[row] = '0;
        for (int col = 0; col < COLS; col++) b_load[col] = '0;

        build_case(1'b0, 1);
        build_case(1'b1, 7);

        repeat (2) @(posedge clk);
        #1;
        assert (!load_ready) else $fatal(1, "load_ready asserted during reset");
        rst_n = 1'b1;

        load_tile(1'b0, 1'b0);
        start_tile(1'b0, 1'b0);
        try_active_bank_write();
        load_tile(1'b1, 1'b1);
        check_tile(1'b0, 1'b0);

        start_tile(1'b1, 1'b1);
        check_tile(1'b1, 1'b1);

        requant_multiplier = 16'd4;
        #1;
        for (int row = 0; row < ROWS; row++) begin
            for (int col = 0; col < COLS; col++) begin
                assert (int'($signed(q_out[row][col])) ==
                        clamp_int8(4 * (expected[0][row][col]
                                      + expected[1][row][col])))
                    else $fatal(1, "requant saturation failed at [%0d][%0d]", row, col);
            end
        end

        $display("PASS: tiled GEMM overlapped banks, accumulated tiles, and requantized");
        $finish;
    end
endmodule
