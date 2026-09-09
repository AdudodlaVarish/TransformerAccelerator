`timescale 1ns/1ps

module attention_score #(
    parameter int HEAD_DIM = 8,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH = 32,
    parameter int SCORE_WIDTH = 16,
    parameter int MULT_WIDTH = 16,
    localparam int INDEX_WIDTH = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM),
    localparam int SHIFT_WIDTH = $clog2(ACC_WIDTH + MULT_WIDTH + 2)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic                          s_axis_tvalid,
    output logic                          s_axis_tready,
    input  logic signed [DATA_WIDTH-1:0]  s_axis_qdata,
    input  logic signed [DATA_WIDTH-1:0]  s_axis_kdata,
    input  logic                          s_axis_vector_last,
    input  logic                          s_axis_sequence_last,
    input  logic [MULT_WIDTH-1:0]         scale_multiplier,
    input  logic [SHIFT_WIDTH-1:0]        scale_shift,
    output logic                          m_axis_tvalid,
    input  logic                          m_axis_tready,
    output logic signed [SCORE_WIDTH-1:0] m_axis_tdata,
    output logic                          m_axis_tlast,
    output logic                          busy,
    output logic                          protocol_error
);
    logic [INDEX_WIDTH-1:0] vector_index;
    logic signed [ACC_WIDTH-1:0] accumulator;
    logic signed [2*DATA_WIDTH-1:0] product;
    logic signed [ACC_WIDTH-1:0] dot_with_current;
    logic signed [SCORE_WIDTH-1:0] scaled_score;
    logic incoming_sequence_last;
    logic out_valid;
    logic signed [SCORE_WIDTH-1:0] out_data;
    logic out_last;
    logic input_accept;
    logic expected_vector_last;

    assign product = s_axis_qdata * s_axis_kdata;
    assign dot_with_current = accumulator + ACC_WIDTH'($signed(product));

    assign s_axis_tready = rst_n && (!out_valid || m_axis_tready);
    assign input_accept = s_axis_tvalid && s_axis_tready;
    assign expected_vector_last = vector_index == INDEX_WIDTH'(HEAD_DIM - 1);
    assign m_axis_tvalid = out_valid;
    assign m_axis_tdata = out_data;
    assign m_axis_tlast = out_last;
    assign busy = vector_index != 0 || out_valid;

    requantize #(
        .IN_WIDTH(ACC_WIDTH),
        .OUT_WIDTH(SCORE_WIDTH),
        .MULT_WIDTH(MULT_WIDTH)
    ) scale_result (
        .value     (dot_with_current),
        .multiplier(scale_multiplier),
        .shift     (scale_shift),
        .zero_point('0),
        .result    (scaled_score)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            vector_index          <= '0;
            accumulator           <= '0;
            incoming_sequence_last <= 1'b0;
            out_valid             <= 1'b0;
            out_data              <= '0;
            out_last              <= 1'b0;
            protocol_error        <= 1'b0;
        end else begin
            if (m_axis_tvalid && m_axis_tready)
                out_valid <= 1'b0;

            if (input_accept) begin
                if (vector_index == 0)
                    incoming_sequence_last <= s_axis_sequence_last;
                else if (s_axis_sequence_last != incoming_sequence_last)
                    protocol_error <= 1'b1;
                if (s_axis_vector_last != expected_vector_last)
                    protocol_error <= 1'b1;

                if (expected_vector_last) begin
                    vector_index <= '0;
                    accumulator <= '0;
                    out_valid <= 1'b1;
                    out_data <= scaled_score;
                    out_last <= vector_index == 0
                              ? s_axis_sequence_last
                              : incoming_sequence_last;
                end else begin
                    vector_index <= vector_index + 1'b1;
                    accumulator <= dot_with_current;
                end
            end
        end
    end
endmodule
