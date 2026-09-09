`timescale 1ns/1ps

module layer_norm #(
    parameter int LENGTH = 8,
    parameter int IN_WIDTH = 8,
    parameter int OUT_WIDTH = 8,
    parameter int STAT_FRAC_BITS = 8,
    parameter int GAMMA_WIDTH = 16,
    parameter int GAMMA_FRAC_BITS = 8,
    parameter int NORM_SCALE = 32,
    parameter int EPSILON_Q = 1,
    localparam int INDEX_WIDTH = (LENGTH <= 1) ? 1 : $clog2(LENGTH),
    localparam int SUM_WIDTH = IN_WIDTH + $clog2(LENGTH + 1) + 1,
    localparam int DIFF_WIDTH = IN_WIDTH + STAT_FRAC_BITS + 2,
    localparam int SQUARE_WIDTH = 2 * DIFF_WIDTH,
    localparam int VAR_WIDTH = SQUARE_WIDTH + $clog2(LENGTH + 1),
    localparam int SQRT_INDEX_WIDTH = (DIFF_WIDTH <= 1) ? 1 : $clog2(DIFF_WIDTH),
    localparam int MEAN_NUM_WIDTH = SUM_WIDTH + STAT_FRAC_BITS,
    localparam int NORM_WIDTH = DIFF_WIDTH + $clog2(NORM_SCALE + 1),
    localparam int AFFINE_WIDTH = NORM_WIDTH + GAMMA_WIDTH + 1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic                         s_axis_tvalid,
    output logic                         s_axis_tready,
    input  logic signed [IN_WIDTH-1:0]   s_axis_tdata,
    input  logic signed [GAMMA_WIDTH-1:0] s_axis_tgamma,
    input  logic signed [OUT_WIDTH-1:0]  s_axis_tbeta,
    input  logic                         s_axis_tlast,
    output logic                         m_axis_tvalid,
    input  logic                         m_axis_tready,
    output logic signed [OUT_WIDTH-1:0]  m_axis_tdata,
    output logic                         m_axis_tlast,
    output logic                         busy,
    output logic                         protocol_error
);
    typedef enum logic [1:0] {LOAD, VARIANCE, SQRT, OUTPUT} state_t;

    localparam logic signed [OUT_WIDTH-1:0] MAX_VALUE =
        {1'b0, {(OUT_WIDTH-1){1'b1}}};
    localparam logic signed [OUT_WIDTH-1:0] MIN_VALUE =
        {1'b1, {(OUT_WIDTH-1){1'b0}}};
    localparam logic signed [MEAN_NUM_WIDTH-1:0] LENGTH_SIGNED =
        MEAN_NUM_WIDTH'(LENGTH);
    localparam logic signed [NORM_WIDTH-1:0] NORM_SCALE_SIGNED =
        NORM_WIDTH'(NORM_SCALE);

    state_t state;
    logic signed [IN_WIDTH-1:0] samples[LENGTH];
    logic signed [GAMMA_WIDTH-1:0] gammas[LENGTH];
    logic signed [OUT_WIDTH-1:0] betas[LENGTH];
    logic [INDEX_WIDTH-1:0] input_index;
    logic [INDEX_WIDTH-1:0] variance_index;
    logic [INDEX_WIDTH-1:0] output_index;
    logic signed [SUM_WIDTH-1:0] sum;
    logic signed [SUM_WIDTH:0] sum_with_input;
    logic signed [MEAN_NUM_WIDTH-1:0] mean_numerator;
    logic signed [DIFF_WIDTH-1:0] mean_q;
    logic signed [DIFF_WIDTH-1:0] difference_q;
    logic signed [DIFF_WIDTH-1:0] output_difference_q;
    logic [SQUARE_WIDTH-1:0] difference_square;
    logic [VAR_WIDTH-1:0] variance_sum;
    logic [VAR_WIDTH-1:0] variance_q;

    logic [DIFF_WIDTH-1:0] sqrt_root;
    logic [SQRT_INDEX_WIDTH-1:0] sqrt_bit;
    logic [DIFF_WIDTH-1:0] sqrt_candidate;
    logic [SQUARE_WIDTH-1:0] sqrt_candidate_square;
    logic [DIFF_WIDTH-1:0] stddev_q;

    logic signed [NORM_WIDTH-1:0] normalized_numerator;
    logic signed [NORM_WIDTH-1:0] stddev_extended;
    logic signed [NORM_WIDTH-1:0] normalized;
    logic signed [AFFINE_WIDTH-1:0] affine_product;
    logic signed [AFFINE_WIDTH-1:0] adjusted;
    logic input_accept;
    logic output_accept;

    always_comb begin
        s_axis_tready = rst_n && state == LOAD;
        input_accept = s_axis_tvalid && s_axis_tready;
        m_axis_tvalid = state == OUTPUT;
        output_accept = m_axis_tvalid && m_axis_tready;
        m_axis_tlast = m_axis_tvalid
                     && output_index == INDEX_WIDTH'(LENGTH - 1);
        busy = state != LOAD || input_index != 0;

        difference_q = (DIFF_WIDTH'($signed(samples[variance_index]))
                        <<< STAT_FRAC_BITS) - mean_q;
        difference_square = SQUARE_WIDTH'($signed(difference_q))
                          * SQUARE_WIDTH'($signed(difference_q));

        sum_with_input = (SUM_WIDTH+1)'($signed(sum))
                       + (SUM_WIDTH+1)'($signed(s_axis_tdata));
        mean_numerator = MEAN_NUM_WIDTH'(sum_with_input) <<< STAT_FRAC_BITS;

        sqrt_candidate = sqrt_root
                       | (DIFF_WIDTH'(1) << sqrt_bit);
        sqrt_candidate_square = SQUARE_WIDTH'(sqrt_candidate)
                              * SQUARE_WIDTH'(sqrt_candidate);

        output_difference_q =
            (DIFF_WIDTH'($signed(samples[output_index])) <<< STAT_FRAC_BITS)
            - mean_q;
        normalized_numerator = NORM_WIDTH'($signed(output_difference_q))
                             * NORM_SCALE_SIGNED;
        stddev_extended = NORM_WIDTH'($signed({1'b0, stddev_q}));
        if (stddev_q != 0)
            normalized = normalized_numerator / stddev_extended;
        else
            normalized = '0;
        affine_product = AFFINE_WIDTH'($signed(normalized))
                       * AFFINE_WIDTH'($signed(gammas[output_index]));
        adjusted = (affine_product >>> GAMMA_FRAC_BITS)
                 + AFFINE_WIDTH'($signed(betas[output_index]));

        if (adjusted > AFFINE_WIDTH'($signed(MAX_VALUE)))
            m_axis_tdata = MAX_VALUE;
        else if (adjusted < AFFINE_WIDTH'($signed(MIN_VALUE)))
            m_axis_tdata = MIN_VALUE;
        else
            m_axis_tdata = OUT_WIDTH'(adjusted);
    end

    // ponytail: one vector buffer and shared math; duplicate only if measured throughput needs it.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= LOAD;
            input_index    <= '0;
            variance_index <= '0;
            output_index   <= '0;
            sum            <= '0;
            mean_q         <= '0;
            variance_sum   <= '0;
            variance_q     <= '0;
            sqrt_root      <= '0;
            sqrt_bit       <= '0;
            stddev_q       <= '0;
            protocol_error <= 1'b0;
        end else begin
            case (state)
                LOAD: begin
                    if (input_accept) begin
                        samples[input_index] <= s_axis_tdata;
                        gammas[input_index]  <= s_axis_tgamma;
                        betas[input_index]   <= s_axis_tbeta;
                        if (s_axis_tlast
                                != (input_index == INDEX_WIDTH'(LENGTH - 1)))
                            protocol_error <= 1'b1;

                        if (input_index == INDEX_WIDTH'(LENGTH - 1)) begin
                            mean_q <= DIFF_WIDTH'(
                                mean_numerator / LENGTH_SIGNED);
                            input_index    <= '0;
                            variance_index <= '0;
                            variance_sum   <= '0;
                            sum            <= '0;
                            state          <= VARIANCE;
                        end else begin
                            sum <= sum + SUM_WIDTH'(s_axis_tdata);
                            input_index <= input_index + 1'b1;
                        end
                    end
                end

                VARIANCE: begin
                    if (variance_index == INDEX_WIDTH'(LENGTH - 1)) begin
                        variance_q <= (variance_sum + VAR_WIDTH'(difference_square))
                                    / VAR_WIDTH'(LENGTH);
                        variance_index <= '0;
                        sqrt_root <= '0;
                        sqrt_bit <= SQRT_INDEX_WIDTH'(DIFF_WIDTH - 1);
                        state <= SQRT;
                    end else begin
                        variance_sum <= variance_sum + VAR_WIDTH'(difference_square);
                        variance_index <= variance_index + 1'b1;
                    end
                end

                SQRT: begin
                    if (VAR_WIDTH'(sqrt_candidate_square)
                            <= variance_q + VAR_WIDTH'(EPSILON_Q))
                        sqrt_root <= sqrt_candidate;
                    if (sqrt_bit == 0) begin
                        stddev_q <= (VAR_WIDTH'(sqrt_candidate_square)
                                     <= variance_q + VAR_WIDTH'(EPSILON_Q))
                                  ? sqrt_candidate : sqrt_root;
                        output_index <= '0;
                        state <= OUTPUT;
                    end else begin
                        sqrt_bit <= sqrt_bit - 1'b1;
                    end
                end

                OUTPUT: begin
                    if (output_accept) begin
                        if (output_index == INDEX_WIDTH'(LENGTH - 1)) begin
                            output_index <= '0;
                            state <= LOAD;
                        end else begin
                            output_index <= output_index + 1'b1;
                        end
                    end
                end

                default: state <= LOAD;
            endcase
        end
    end
endmodule
