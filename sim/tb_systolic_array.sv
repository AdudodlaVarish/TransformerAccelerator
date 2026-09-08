`timescale 1ns/1ps

module tb_systolic_array;
    localparam int ROWS = 4;
    localparam int COLS = 4;
    localparam int K    = 5;
    localparam int TOTAL_CYCLES = K + ROWS + COLS - 2;

    logic clk;
    logic rst_n;
    logic start;
    logic busy;
    logic done;
    logic signed [7:0]  a_in [ROWS];
    logic signed [7:0]  b_in [COLS];
    logic signed [31:0] c_out[ROWS][COLS];
    integer signed a_matrix[ROWS][K];
    integer signed b_matrix[K][COLS];
    integer signed expected[ROWS][COLS];

    always #5 clk <= ~clk;

    systolic_array #(
        .ROWS(ROWS),
        .COLS(COLS),
        .K(K)
    ) dut (.*);

    task automatic load_case(input int seed);
        for (int row = 0; row < ROWS; row++) begin
            for (int k = 0; k < K; k++)
                a_matrix[row][k] = ((row * 3 + k * 2 + seed) % 11) - 5;
        end
        for (int k = 0; k < K; k++) begin
            for (int col = 0; col < COLS; col++)
                b_matrix[k][col] = ((k * 4 - col * 3 + seed) % 13) - 6;
        end
        for (int row = 0; row < ROWS; row++) begin
            for (int col = 0; col < COLS; col++) begin
                expected[row][col] = 0;
                for (int k = 0; k < K; k++)
                    expected[row][col] += a_matrix[row][k] * b_matrix[k][col];
            end
        end
    endtask

    task automatic run_case(input int seed);
        load_case(seed);

        @(negedge clk);
        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;

        for (int cycle = 0; cycle < TOTAL_CYCLES; cycle++) begin
            @(negedge clk);
            for (int row = 0; row < ROWS; row++)
                a_in[row] = (cycle >= row && cycle < row + K)
                    ? 8'(a_matrix[row][cycle-row]) : 0;
            for (int col = 0; col < COLS; col++)
                b_in[col] = (cycle >= col && cycle < col + K)
                    ? 8'(b_matrix[cycle-col][col]) : 0;
            @(posedge clk);
            #1;
        end

        assert (done) else $fatal(1, "done did not assert on the expected cycle");
        assert (!busy) else $fatal(1, "busy remained asserted after completion");
        for (int row = 0; row < ROWS; row++) begin
            for (int col = 0; col < COLS; col++) begin
                assert ($signed(c_out[row][col]) == expected[row][col])
                    else $fatal(1, "C[%0d][%0d]: got %0d, expected %0d",
                                row, col, $signed(c_out[row][col]), expected[row][col]);
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        for (int row = 0; row < ROWS; row++) a_in[row] = '0;
        for (int col = 0; col < COLS; col++) b_in[col] = '0;

        repeat (2) @(posedge clk);
        rst_n = 1'b1;

        run_case(1);
        run_case(7);

        $display("PASS: two signed INT8 matrix products matched the expected");
        $finish;
    end
endmodule
