`timescale 1ns/1ps

module systolic_array #(
    parameter int ROWS       = 4,
    parameter int COLS       = 4,
    parameter int K          = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    localparam int TOTAL_CYCLES = K + ROWS + COLS - 2,
    localparam int COUNT_WIDTH  = $clog2(TOTAL_CYCLES + 1)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    input  logic signed [DATA_WIDTH-1:0] a_in [ROWS],
    input  logic signed [DATA_WIDTH-1:0] b_in [COLS],
    output logic signed [ACC_WIDTH-1:0]  c_out[ROWS][COLS],
    output logic                         busy,
    output logic                         done
);
    logic signed [DATA_WIDTH-1:0] a_bus[ROWS][COLS+1];
    logic signed [DATA_WIDTH-1:0] b_bus[ROWS+1][COLS];
    logic        [COUNT_WIDTH-1:0] cycle_count;

    for (genvar row = 0; row < ROWS; row++) begin : gen_a_inputs
        assign a_bus[row][0] = a_in[row];
    end

    for (genvar col = 0; col < COLS; col++) begin : gen_b_inputs
        assign b_bus[0][col] = b_in[col];
    end

    for (genvar row = 0; row < ROWS; row++) begin : gen_rows
        for (genvar col = 0; col < COLS; col++) begin : gen_cols
            logic signed [(2*DATA_WIDTH)-1:0] product;

            always_comb product = a_bus[row][col] * b_bus[row][col];

            always_ff @(posedge clk) begin
                if (!rst_n || start) begin
                    a_bus[row][col+1] <= '0;
                    b_bus[row+1][col] <= '0;
                    c_out[row][col]   <= '0;
                end else begin
                    a_bus[row][col+1] <= a_bus[row][col];
                    b_bus[row+1][col] <= b_bus[row][col];
                    c_out[row][col]   <= c_out[row][col] + ACC_WIDTH'(product);
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy        <= 1'b0;
            done        <= 1'b0;
            cycle_count <= '0;
        end else begin
            done <= 1'b0;
            if (start) begin
                busy        <= 1'b1;
                cycle_count <= '0;
            end else if (busy) begin
                if (cycle_count == COUNT_WIDTH'(TOTAL_CYCLES - 1)) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    cycle_count <= cycle_count + 1'b1;
                end
            end
        end
    end
endmodule
