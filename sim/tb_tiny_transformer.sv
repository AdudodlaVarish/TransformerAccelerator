`timescale 1ns/1ps

module tb_tiny_transformer;
    localparam int SIZE = 4;
    localparam int GEMM_CYCLES = 10;

    logic clk;
    logic rst_n;

    logic gm_s_valid;
    logic gm_s_ready;
    logic [63:0] gm_s_data;
    logic gm_s_last;
    logic [1:0] gm_s_user;
    logic [15:0] gm_multiplier;
    logic [5:0] gm_shift;
    logic signed [7:0] gm_zero_point;
    logic gm_m_valid;
    logic gm_m_ready;
    logic signed [7:0] gm_m_data;
    logic gm_m_last;
    logic gm_counters_clear;
    logic gm_busy;
    logic gm_protocol_error;
    logic [63:0] gm_total_cycles;
    logic [63:0] gm_compute_cycles;
    logic [63:0] gm_input_stalls;
    logic [63:0] gm_output_stalls;
    logic [31:0] gm_tiles;
    logic [31:0] gm_results;

    logic score_s_valid;
    logic score_s_ready;
    logic signed [7:0] score_qdata;
    logic signed [7:0] score_kdata;
    logic score_vector_last;
    logic score_sequence_last;
    logic score_valid;
    logic score_ready;
    logic signed [15:0] score_data;
    logic score_last;
    logic score_busy;
    logic score_error;
    logic prob_valid;
    logic prob_ready;
    logic [6:0] prob_data;
    logic prob_last;
    logic prob_busy;
    logic prob_error;

    logic ln_s_valid;
    logic ln_s_ready;
    logic signed [7:0] ln_s_data;
    logic signed [15:0] ln_s_gamma;
    logic signed [7:0] ln_s_beta;
    logic ln_s_last;
    logic ln_m_valid;
    logic ln_m_ready;
    logic signed [7:0] ln_m_data;
    logic ln_m_last;
    logic ln_busy;
    logic ln_error;

    logic act_s_valid;
    logic act_s_ready;
    logic signed [7:0] act_s_data;
    logic act_s_last;
    logic [1:0] act_mode;
    logic act_m_valid;
    logic act_m_ready;
    logic signed [7:0] act_m_data;
    logic act_m_last;

    integer signed x[SIZE][SIZE];
    integer signed wq[SIZE][SIZE];
    integer signed wk[SIZE][SIZE];
    integer signed wv[SIZE][SIZE];
    integer signed wo[SIZE][SIZE];
    integer signed w1[SIZE][SIZE];
    integer signed w2[SIZE][SIZE];
    integer signed query[SIZE][SIZE];
    integer signed key[SIZE][SIZE];
    integer signed value[SIZE][SIZE];
    integer signed probabilities[SIZE][SIZE];
    integer signed attention_context[SIZE][SIZE];
    integer signed attention[SIZE][SIZE];
    integer signed residual[SIZE][SIZE];
    integer signed normalized[SIZE][SIZE];
    integer signed hidden_input[SIZE][SIZE];
    integer signed hidden[SIZE][SIZE];
    integer signed feed_forward[SIZE][SIZE];
    integer signed final_residual[SIZE][SIZE];
    integer signed output_matrix[SIZE][SIZE];
    integer signed expected_output[SIZE][SIZE];
    integer total_gemm_cycles;

    always #5 clk <= ~clk;

    transformer_gemm_accelerator #(
        .ROWS(SIZE), .COLS(SIZE), .K(SIZE)
    ) gemm (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(gm_s_valid), .s_axis_tready(gm_s_ready),
        .s_axis_tdata(gm_s_data), .s_axis_tlast(gm_s_last),
        .s_axis_tuser(gm_s_user),
        .requant_multiplier(gm_multiplier), .requant_shift(gm_shift),
        .requant_zero_point(gm_zero_point),
        .m_axis_tvalid(gm_m_valid), .m_axis_tready(gm_m_ready),
        .m_axis_tdata(gm_m_data), .m_axis_tlast(gm_m_last),
        .counters_clear(gm_counters_clear), .busy(gm_busy),
        .protocol_error(gm_protocol_error), .total_cycles(gm_total_cycles),
        .compute_cycles(gm_compute_cycles), .input_stall_cycles(gm_input_stalls),
        .output_stall_cycles(gm_output_stalls), .tiles_completed(gm_tiles),
        .results_transferred(gm_results)
    );

    attention_score #(
        .HEAD_DIM(SIZE)
    ) attention_dot (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(score_s_valid), .s_axis_tready(score_s_ready),
        .s_axis_qdata(score_qdata), .s_axis_kdata(score_kdata),
        .s_axis_vector_last(score_vector_last),
        .s_axis_sequence_last(score_sequence_last),
        .scale_multiplier(16'd1), .scale_shift(6'd4),
        .m_axis_tvalid(score_valid), .m_axis_tready(score_ready),
        .m_axis_tdata(score_data), .m_axis_tlast(score_last),
        .busy(score_busy), .protocol_error(score_error)
    );

    attention_softmax #(
        .LENGTH(SIZE), .PROB_WIDTH(7)
    ) softmax (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(score_valid), .s_axis_tready(score_ready),
        .s_axis_tdata(score_data), .s_axis_tlast(score_last),
        .m_axis_tvalid(prob_valid), .m_axis_tready(prob_ready),
        .m_axis_tdata(prob_data), .m_axis_tlast(prob_last),
        .busy(prob_busy), .protocol_error(prob_error)
    );

    layer_norm #(
        .LENGTH(SIZE)
    ) normalize (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(ln_s_valid), .s_axis_tready(ln_s_ready),
        .s_axis_tdata(ln_s_data), .s_axis_tgamma(ln_s_gamma),
        .s_axis_tbeta(ln_s_beta), .s_axis_tlast(ln_s_last),
        .m_axis_tvalid(ln_m_valid), .m_axis_tready(ln_m_ready),
        .m_axis_tdata(ln_m_data), .m_axis_tlast(ln_m_last),
        .busy(ln_busy), .protocol_error(ln_error)
    );

    transformer_activation activation (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(act_s_valid), .s_axis_tready(act_s_ready),
        .s_axis_tdata(act_s_data), .s_axis_tlast(act_s_last), .mode(act_mode),
        .m_axis_tvalid(act_m_valid), .m_axis_tready(act_m_ready),
        .m_axis_tdata(act_m_data), .m_axis_tlast(act_m_last)
    );

    function automatic integer signed clamp8(input integer signed value_in);
        if (value_in > 127)
            clamp8 = 127;
        else if (value_in < -128)
            clamp8 = -128;
        else
            clamp8 = value_in;
    endfunction

    task automatic build_weights(input int seed, output integer signed matrix[SIZE][SIZE]);
        for (int row = 0; row < SIZE; row++) begin
            for (int col = 0; col < SIZE; col++)
                matrix[row][col] = ((row * 3 + col * seed + seed) % 5) - 2;
        end
    endtask

    task automatic run_gemm(
        input integer signed left[SIZE][SIZE],
        input integer signed right[SIZE][SIZE],
        input logic [5:0] shift,
        output integer signed result[SIZE][SIZE]
    );
        @(negedge clk);
        gm_counters_clear = 1'b1;
        @(posedge clk);
        #1;
        gm_counters_clear = 1'b0;
        gm_multiplier = 16'd1;
        gm_shift = shift;
        gm_zero_point = '0;

        for (int k = 0; k < SIZE; k++) begin
            @(negedge clk);
            gm_s_valid = 1'b1;
            gm_s_last = k == SIZE - 1;
            gm_s_user = 2'b10;
            gm_s_data = '0;
            for (int row = 0; row < SIZE; row++)
                gm_s_data[row*8 +: 8] = 8'(left[row][k]);
            for (int col = 0; col < SIZE; col++)
                gm_s_data[(SIZE+col)*8 +: 8] = 8'(right[k][col]);
            #1;
            assert (gm_s_ready) else $fatal(1, "tiny-model GEMM input blocked");
            @(posedge clk);
            #1;
        end
        gm_s_valid = 1'b0;
        gm_s_last = 1'b0;

        gm_m_ready = 1'b1;
        while (!gm_m_valid) begin
            @(posedge clk);
            #1;
        end
        for (int index = 0; index < SIZE*SIZE; index++) begin
            @(negedge clk);
            #1;
            assert (gm_m_valid && gm_m_last == (index == SIZE*SIZE-1))
                else $fatal(1, "tiny-model GEMM output framing failed");
            result[index/SIZE][index%SIZE] = int'($signed(gm_m_data));
            @(posedge clk);
            #1;
        end
        gm_m_ready = 1'b0;
        assert (gm_compute_cycles == 64'(GEMM_CYCLES)
                && gm_tiles == 1 && gm_results == 1)
            else $fatal(1, "tiny-model GEMM counters failed");
        total_gemm_cycles += int'(gm_compute_cycles);
    endtask

    task automatic run_attention;
        for (int query_index = 0; query_index < SIZE; query_index++) begin
            for (int key_index = 0; key_index < SIZE; key_index++) begin
                for (int dim = 0; dim < SIZE; dim++) begin
                    @(negedge clk);
                    score_s_valid = 1'b1;
                    score_qdata = 8'(query[query_index][dim]);
                    score_kdata = 8'(key[key_index][dim]);
                    score_vector_last = dim == SIZE - 1;
                    score_sequence_last = key_index == SIZE - 1;
                    #1;
                    while (!score_s_ready) begin
                        @(posedge clk);
                        @(negedge clk);
                        #1;
                    end
                    @(posedge clk);
                    #1;
                end
            end
            score_s_valid = 1'b0;
            score_vector_last = 1'b0;
            score_sequence_last = 1'b0;

            prob_ready = 1'b1;
            while (!prob_valid) begin
                @(posedge clk);
                #1;
            end
            for (int col = 0; col < SIZE; col++) begin
                @(negedge clk);
                #1;
                assert (prob_valid && prob_last == (col == SIZE-1))
                    else $fatal(1, "tiny-model softmax framing failed");
                probabilities[query_index][col] = int'($unsigned(prob_data));
                @(posedge clk);
                #1;
            end
            prob_ready = 1'b0;
        end
    endtask

    task automatic run_layer_norm(
        input integer signed input_matrix[SIZE][SIZE],
        output integer signed result[SIZE][SIZE]
    );
        for (int row = 0; row < SIZE; row++) begin
            for (int col = 0; col < SIZE; col++) begin
                @(negedge clk);
                ln_s_valid = 1'b1;
                ln_s_data = 8'(input_matrix[row][col]);
                ln_s_gamma = 16'sd256;
                ln_s_beta = '0;
                ln_s_last = col == SIZE - 1;
                #1;
                assert (ln_s_ready) else $fatal(1, "tiny-model layer norm blocked");
                @(posedge clk);
                #1;
            end
            ln_s_valid = 1'b0;
            ln_s_last = 1'b0;

            ln_m_ready = 1'b1;
            while (!ln_m_valid) begin
                @(posedge clk);
                #1;
            end
            for (int col = 0; col < SIZE; col++) begin
                @(negedge clk);
                #1;
                assert (ln_m_valid && ln_m_last == (col == SIZE-1))
                    else $fatal(1, "tiny-model layer norm framing failed");
                result[row][col] = int'($signed(ln_m_data));
                @(posedge clk);
                #1;
            end
            ln_m_ready = 1'b0;
        end
    endtask

    task automatic run_gelu(
        input integer signed input_matrix[SIZE][SIZE],
        output integer signed result[SIZE][SIZE]
    );
        act_mode = 2'b10;
        act_m_ready = 1'b1;
        for (int index = 0; index < SIZE*SIZE; index++) begin
            @(negedge clk);
            act_s_valid = 1'b1;
            act_s_data = 8'(input_matrix[index/SIZE][index%SIZE]);
            act_s_last = index == SIZE*SIZE - 1;
            #1;
            assert (act_s_ready) else $fatal(1, "tiny-model GELU input blocked");
            @(posedge clk);
            #1;
            act_s_valid = 1'b0;
            assert (act_m_valid && act_m_last == (index == SIZE*SIZE-1))
                else $fatal(1, "tiny-model GELU output framing failed");
            result[index/SIZE][index%SIZE] = int'($signed(act_m_data));
            @(posedge clk);
            #1;
        end
        act_m_ready = 1'b0;
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        gm_s_valid = 1'b0;
        gm_s_data = '0;
        gm_s_last = 1'b0;
        gm_s_user = '0;
        gm_multiplier = 16'd1;
        gm_shift = '0;
        gm_zero_point = '0;
        gm_m_ready = 1'b0;
        gm_counters_clear = 1'b0;
        score_s_valid = 1'b0;
        score_qdata = '0;
        score_kdata = '0;
        score_vector_last = 1'b0;
        score_sequence_last = 1'b0;
        prob_ready = 1'b0;
        ln_s_valid = 1'b0;
        ln_s_data = '0;
        ln_s_gamma = '0;
        ln_s_beta = '0;
        ln_s_last = 1'b0;
        ln_m_ready = 1'b0;
        act_s_valid = 1'b0;
        act_s_data = '0;
        act_s_last = 1'b0;
        act_mode = '0;
        act_m_ready = 1'b0;
        total_gemm_cycles = 0;

        x = '{'{3, -2, 1, 0}, '{-1, 2, 0, 3},
              '{2, 1, -3, 1}, '{0, -1, 2, -2}};
        build_weights(1, wq);
        build_weights(2, wk);
        build_weights(3, wv);
        build_weights(4, wo);
        build_weights(5, w1);
        build_weights(6, w2);
        expected_output = '{'{17, 0, 34, -51}, '{-52, 29, 21, 1},
                            '{2, 51, -26, -26}, '{-13, 18, 39, -44}};

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        run_gemm(x, wq, 2, query);
        run_gemm(x, wk, 2, key);
        run_gemm(x, wv, 1, value);
        run_attention();
        run_gemm(probabilities, value, 7, attention_context);
        run_gemm(attention_context, wo, 1, attention);
        for (int row = 0; row < SIZE; row++) begin
            for (int col = 0; col < SIZE; col++)
                residual[row][col] = clamp8(x[row][col] + attention[row][col]);
        end
        run_layer_norm(residual, normalized);
        run_gemm(normalized, w1, 2, hidden_input);
        run_gelu(hidden_input, hidden);
        run_gemm(hidden, w2, 2, feed_forward);
        for (int row = 0; row < SIZE; row++) begin
            for (int col = 0; col < SIZE; col++)
                final_residual[row][col] =
                    clamp8(normalized[row][col] + feed_forward[row][col]);
        end
        run_layer_norm(final_residual, output_matrix);

        assert (!gm_protocol_error && !score_error && !prob_error && !ln_error)
            else $fatal(1, "tiny transformer reported a protocol error");
        assert (!gm_busy && !score_busy && !prob_busy && !ln_busy
                && gm_total_cycles >= gm_compute_cycles
                && gm_input_stalls == 0 && gm_output_stalls == 0)
            else $fatal(1, "tiny transformer did not finish cleanly");
        assert (total_gemm_cycles == 7*GEMM_CYCLES)
            else $fatal(1, "tiny transformer GEMM cycle total failed");
        for (int row = 0; row < SIZE; row++) begin
            for (int col = 0; col < SIZE; col++) begin
                assert (output_matrix[row][col] == expected_output[row][col])
                    else $fatal(1, "tiny output [%0d][%0d]: got %0d expected %0d",
                                row, col, output_matrix[row][col],
                                expected_output[row][col]);
            end
            $display("TINY_OUTPUT %0d %0d %0d %0d", output_matrix[row][0],
                     output_matrix[row][1], output_matrix[row][2],
                     output_matrix[row][3]);
        end

        $display("PASS: cycle-accurate tiny transformer used all RTL kernels");
        $finish;
    end
endmodule
