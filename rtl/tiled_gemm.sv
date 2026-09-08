`timescale 1ns/1ps

module tiled_gemm #(
    parameter int ROWS       = 4,
    parameter int COLS       = 4,
    parameter int K          = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    localparam int K_ADDR_WIDTH = (K <= 1) ? 1 : $clog2(K),
    localparam int TOTAL_CYCLES = K + ROWS + COLS - 2,
    localparam int FEED_WIDTH   = $clog2(TOTAL_CYCLES + 1)
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
    output logic                         busy,
    output logic                         done,
    output logic                         result_bank,
    output logic signed [ACC_WIDTH-1:0]  c_out[ROWS][COLS]
);
    logic signed [DATA_WIDTH-1:0] a_buffer[2][ROWS][K];
    logic signed [DATA_WIDTH-1:0] b_buffer[2][COLS][K];
    logic signed [DATA_WIDTH-1:0] a_stream[ROWS];
    logic signed [DATA_WIDTH-1:0] b_stream[COLS];
    logic        [FEED_WIDTH-1:0] feed_cycle;
    logic                         feeding;
    logic                         array_start;
    logic                         bank_conflict;

    always_comb begin
        array_start  = start && !busy;
        bank_conflict = (busy && load_bank == result_bank)
                      || (array_start && load_bank == start_bank);
        load_ready = !bank_conflict && int'($unsigned(load_k)) < K;
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
        .c_out(c_out),
        .busy (busy),
        .done (done)
    );
endmodule
