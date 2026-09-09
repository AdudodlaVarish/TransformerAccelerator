`timescale 1ns/1ps

module transformer_activation #(
    parameter int DATA_WIDTH = 8,
    parameter int FRAC_BITS = 4
) (
    input  logic clk,
    input  logic rst_n,
    input  logic                         s_axis_tvalid,
    output logic                         s_axis_tready,
    input  logic signed [DATA_WIDTH-1:0] s_axis_tdata,
    input  logic                         s_axis_tlast,
    input  logic [1:0]                   mode,
    output logic                         m_axis_tvalid,
    input  logic                         m_axis_tready,
    output logic signed [DATA_WIDTH-1:0] m_axis_tdata,
    output logic                         m_axis_tlast
);
    localparam logic signed [DATA_WIDTH-1:0] MAX_VALUE =
        {1'b0, {(DATA_WIDTH-1){1'b1}}};
    localparam int PRODUCT_WIDTH = DATA_WIDTH + 9;

    logic out_valid;
    logic signed [DATA_WIDTH-1:0] out_data;
    logic out_last;
    logic signed [PRODUCT_WIDTH-1:0] gelu_product;
    logic signed [PRODUCT_WIDTH-1:0] gelu_rounded;
    logic [7:0] gelu_gate;
    logic signed [DATA_WIDTH+3:0] gate_unclamped;
    logic signed [DATA_WIDTH-1:0] activated;

    initial begin
        if (DATA_WIDTH != 8 || FRAC_BITS != 4)
            $error("transformer_activation currently uses signed INT8 Q4.4");
    end

    always_comb begin
        // A linear sigmoid approximation: clamp(0.5 + 0.4375*x, 0, 1).
        gate_unclamped = (DATA_WIDTH+4)'(128)
                       + ((DATA_WIDTH+4)'($signed(s_axis_tdata)) <<< 3)
                       - (DATA_WIDTH+4)'($signed(s_axis_tdata));
        if (gate_unclamped < 0)
            gelu_gate = 8'd0;
        else if (gate_unclamped > 255)
            gelu_gate = 8'd255;
        else
            gelu_gate = 8'(gate_unclamped);

        gelu_product = PRODUCT_WIDTH'($signed(s_axis_tdata))
                     * PRODUCT_WIDTH'($signed({1'b0, gelu_gate}));
        if (gelu_product < 0)
            gelu_rounded = -((-gelu_product + PRODUCT_WIDTH'(128)) >>> 8);
        else
            gelu_rounded = (gelu_product + PRODUCT_WIDTH'(128)) >>> 8;

        case (mode)
            2'b00: activated = s_axis_tdata;
            2'b01: activated = s_axis_tdata < 0 ? '0 : s_axis_tdata;
            default: begin
                if (gelu_rounded > PRODUCT_WIDTH'($signed(MAX_VALUE)))
                    activated = MAX_VALUE;
                else if (gelu_rounded < 0
                         && -gelu_rounded > PRODUCT_WIDTH'(1 << (DATA_WIDTH-1)))
                    activated = {1'b1, {(DATA_WIDTH-1){1'b0}}};
                else
                    activated = DATA_WIDTH'(gelu_rounded);
            end
        endcase

        s_axis_tready = rst_n && (!out_valid || m_axis_tready);
        m_axis_tvalid = out_valid;
        m_axis_tdata = out_data;
        m_axis_tlast = out_last;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_data  <= '0;
            out_last  <= 1'b0;
        end else if (s_axis_tvalid && s_axis_tready) begin
            out_valid <= 1'b1;
            out_data  <= activated;
            out_last  <= s_axis_tlast;
        end else if (m_axis_tvalid && m_axis_tready) begin
            out_valid <= 1'b0;
        end
    end
endmodule
