`timescale 1ns/1ps

module requantize #(
    parameter int IN_WIDTH   = 32,
    parameter int OUT_WIDTH  = 8,
    parameter int MULT_WIDTH = 16,
    localparam int PRODUCT_WIDTH = IN_WIDTH + MULT_WIDTH + 1,
    localparam int SHIFT_WIDTH   = $clog2(PRODUCT_WIDTH + 1)
) (
    input  logic signed [IN_WIDTH-1:0]    value,
    input  logic        [MULT_WIDTH-1:0]  multiplier,
    input  logic        [SHIFT_WIDTH-1:0] shift,
    input  logic signed [OUT_WIDTH-1:0]   zero_point,
    output logic signed [OUT_WIDTH-1:0]   result
);
    localparam logic signed [OUT_WIDTH-1:0] MAX_VALUE =
        {1'b0, {(OUT_WIDTH-1){1'b1}}};
    localparam logic signed [OUT_WIDTH-1:0] MIN_VALUE =
        {1'b1, {(OUT_WIDTH-1){1'b0}}};

    logic signed [PRODUCT_WIDTH-1:0] product;
    logic signed [PRODUCT_WIDTH-1:0] magnitude;
    logic signed [PRODUCT_WIDTH-1:0] bias;
    logic signed [PRODUCT_WIDTH-1:0] scaled;
    logic signed [PRODUCT_WIDTH-1:0] adjusted;

    always_comb begin
        product   = PRODUCT_WIDTH'(value)
                  * PRODUCT_WIDTH'($signed({1'b0, multiplier}));
        magnitude = (product < 0) ? -product : product;
        bias      = '0;
        scaled    = '0;

        if (shift == 0) begin
            scaled = product;
        end else if (int'($unsigned(shift)) < PRODUCT_WIDTH) begin
            bias   = PRODUCT_WIDTH'(1) <<< (shift - 1'b1);
            scaled = (magnitude + bias) >>> shift;
            if (product < 0)
                scaled = -scaled;
        end

        adjusted = scaled + PRODUCT_WIDTH'(zero_point);
        if (adjusted > PRODUCT_WIDTH'(MAX_VALUE))
            result = MAX_VALUE;
        else if (adjusted < PRODUCT_WIDTH'(MIN_VALUE))
            result = MIN_VALUE;
        else
            result = adjusted[OUT_WIDTH-1:0];
    end
endmodule
