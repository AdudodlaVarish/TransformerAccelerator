`timescale 1ns/1ps

module attention_softmax #(
    parameter int LENGTH       = 8,
    parameter int IN_WIDTH     = 16,
    parameter int IN_FRAC_BITS = 4,
    parameter int PROB_WIDTH   = 8,
    localparam int INDEX_WIDTH = (LENGTH <= 1) ? 1 : $clog2(LENGTH),
    localparam int EXP_WIDTH   = 13,
    localparam int SUM_WIDTH   = EXP_WIDTH + $clog2(LENGTH + 1),
    localparam int NUMERATOR_WIDTH = EXP_WIDTH + PROB_WIDTH + 1
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       s_axis_tvalid,
    output logic                       s_axis_tready,
    input  logic signed [IN_WIDTH-1:0] s_axis_tdata,
    input  logic                       s_axis_tlast,
    output logic                       m_axis_tvalid,
    input  logic                       m_axis_tready,
    output logic        [PROB_WIDTH-1:0] m_axis_tdata,
    output logic                       m_axis_tlast,
    output logic                       busy,
    output logic                       protocol_error
);
    typedef enum logic [1:0] {LOAD, EXPONENTIATE, OUTPUT} state_t;

    state_t state;
    logic signed [IN_WIDTH-1:0] scores[LENGTH];
    logic        [EXP_WIDTH-1:0] exponentials[LENGTH];
    logic signed [IN_WIDTH-1:0] maximum;
    logic        [SUM_WIDTH-1:0] exponential_sum;
    logic        [INDEX_WIDTH-1:0] input_index;
    logic        [INDEX_WIDTH-1:0] exp_index;
    logic        [INDEX_WIDTH-1:0] output_index;
    logic signed [IN_WIDTH:0] difference;
    logic        [EXP_WIDTH-1:0] current_exponential;
    logic        [NUMERATOR_WIDTH-1:0] probability_numerator;
    logic input_accept;
    logic output_accept;

    function automatic logic [EXP_WIDTH-1:0] exp_lut_entry(
        input logic [4:0] index
    );
        begin
            case (index)
                0:  exp_lut_entry = 13'd4096;
                1:  exp_lut_entry = 13'd2484;
                2:  exp_lut_entry = 13'd1507;
                3:  exp_lut_entry = 13'd914;
                4:  exp_lut_entry = 13'd554;
                5:  exp_lut_entry = 13'd336;
                6:  exp_lut_entry = 13'd204;
                7:  exp_lut_entry = 13'd124;
                8:  exp_lut_entry = 13'd75;
                9:  exp_lut_entry = 13'd46;
                10: exp_lut_entry = 13'd28;
                11: exp_lut_entry = 13'd17;
                12: exp_lut_entry = 13'd10;
                13: exp_lut_entry = 13'd6;
                14: exp_lut_entry = 13'd4;
                15: exp_lut_entry = 13'd2;
                16: exp_lut_entry = 13'd1;
                default: exp_lut_entry = '0;
            endcase
        end
    endfunction

    function automatic logic [EXP_WIDTH-1:0] exp_lut(
        input logic signed [IN_WIDTH:0] delta
    );
        logic [IN_WIDTH:0] interval;
        logic [IN_FRAC_BITS-2:0] fraction;
        logic [EXP_WIDTH-1:0] upper;
        logic [EXP_WIDTH-1:0] lower;
        logic [EXP_WIDTH-1:0] step;
        logic [EXP_WIDTH+IN_FRAC_BITS-2:0] correction;
        begin
            interval = $unsigned(delta) >> (IN_FRAC_BITS - 1);
            fraction = $unsigned(delta[IN_FRAC_BITS-2:0]);
            upper = exp_lut_entry(5'(interval));
            lower = exp_lut_entry(5'(interval + 1'b1));
            step = upper - lower;
            correction = step * fraction;
            if (interval > (IN_WIDTH+1)'(16))
                exp_lut = '0;
            else
                exp_lut = upper
                        - EXP_WIDTH'(correction >> (IN_FRAC_BITS - 1));
        end
    endfunction

    always_comb begin
        s_axis_tready = state == LOAD;
        input_accept  = s_axis_tvalid && s_axis_tready;
        m_axis_tvalid = state == OUTPUT;
        output_accept = m_axis_tvalid && m_axis_tready;
        m_axis_tlast  = m_axis_tvalid
                      && output_index == INDEX_WIDTH'(LENGTH - 1);
        busy = state != LOAD || input_index != 0;

        difference = $signed({maximum[IN_WIDTH-1], maximum})
                   - $signed({scores[exp_index][IN_WIDTH-1], scores[exp_index]});
        current_exponential = exp_lut(difference);
        probability_numerator =
            NUMERATOR_WIDTH'(exponentials[output_index] * ((1 << PROB_WIDTH) - 1))
          + NUMERATOR_WIDTH'(exponential_sum >> 1);
        // ponytail: one shared divider; pipeline it only if timing reports demand it.
        m_axis_tdata = (state == OUTPUT && exponential_sum != 0)
                     ? PROB_WIDTH'(probability_numerator / exponential_sum)
                     : '0;
    end

    // ponytail: one vector buffer; ping-pong it if softmax throughput becomes limiting.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state            <= LOAD;
            maximum          <= '0;
            exponential_sum  <= '0;
            input_index      <= '0;
            exp_index        <= '0;
            output_index     <= '0;
            protocol_error   <= 1'b0;
        end else begin
            case (state)
                LOAD: begin
                    if (input_accept) begin
                        scores[input_index] <= s_axis_tdata;
                        if (input_index == 0 || s_axis_tdata > maximum)
                            maximum <= s_axis_tdata;
                        if (s_axis_tlast != (input_index == INDEX_WIDTH'(LENGTH - 1)))
                            protocol_error <= 1'b1;

                        if (input_index == INDEX_WIDTH'(LENGTH - 1)) begin
                            input_index     <= '0;
                            exp_index       <= '0;
                            exponential_sum <= '0;
                            state           <= EXPONENTIATE;
                        end else begin
                            input_index <= input_index + 1'b1;
                        end
                    end
                end

                EXPONENTIATE: begin
                    exponentials[exp_index] <= current_exponential;
                    exponential_sum <= exponential_sum + SUM_WIDTH'(current_exponential);
                    if (exp_index == INDEX_WIDTH'(LENGTH - 1)) begin
                        exp_index    <= '0;
                        output_index <= '0;
                        state        <= OUTPUT;
                    end else begin
                        exp_index <= exp_index + 1'b1;
                    end
                end

                OUTPUT: begin
                    if (output_accept) begin
                        if (output_index == INDEX_WIDTH'(LENGTH - 1)) begin
                            output_index <= '0;
                            maximum      <= '0;
                            state        <= LOAD;
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
