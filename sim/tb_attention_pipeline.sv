`timescale 1ns/1ps

module tb_attention_pipeline;
    localparam int HEAD_DIM = 4;
    localparam int LENGTH = 8;
    localparam int IN_FRAC_BITS = 4;

    logic clk;
    logic rst_n;
    logic s_axis_tvalid;
    logic s_axis_tready;
    logic signed [7:0] s_axis_qdata;
    logic signed [7:0] s_axis_kdata;
    logic s_axis_vector_last;
    logic s_axis_sequence_last;
    logic [15:0] scale_multiplier;
    logic [5:0] scale_shift;
    logic score_valid;
    logic score_ready;
    logic signed [15:0] score_data;
    logic score_last;
    logic score_busy;
    logic score_protocol_error;
    logic m_axis_tvalid;
    logic m_axis_tready;
    logic [7:0] m_axis_tdata;
    logic m_axis_tlast;
    logic softmax_busy;
    logic softmax_protocol_error;

    integer signed query[HEAD_DIM];
    integer signed keys[LENGTH][HEAD_DIM];
    integer signed dots[LENGTH];

    always #5 clk <= ~clk;

    attention_score #(
        .HEAD_DIM(HEAD_DIM)
    ) score (
        .clk                  (clk),
        .rst_n                (rst_n),
        .s_axis_tvalid        (s_axis_tvalid),
        .s_axis_tready        (s_axis_tready),
        .s_axis_qdata         (s_axis_qdata),
        .s_axis_kdata         (s_axis_kdata),
        .s_axis_vector_last   (s_axis_vector_last),
        .s_axis_sequence_last (s_axis_sequence_last),
        .scale_multiplier     (scale_multiplier),
        .scale_shift          (scale_shift),
        .m_axis_tvalid        (score_valid),
        .m_axis_tready        (score_ready),
        .m_axis_tdata         (score_data),
        .m_axis_tlast         (score_last),
        .busy                 (score_busy),
        .protocol_error       (score_protocol_error)
    );

    attention_softmax #(
        .LENGTH(LENGTH),
        .IN_FRAC_BITS(IN_FRAC_BITS)
    ) softmax (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tvalid  (score_valid),
        .s_axis_tready  (score_ready),
        .s_axis_tdata   (score_data),
        .s_axis_tlast   (score_last),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tlast   (m_axis_tlast),
        .busy           (softmax_busy),
        .protocol_error (softmax_protocol_error)
    );

    task automatic send_attention_inputs;
        for (int key_index = 0; key_index < LENGTH; key_index++) begin
            for (int dim = 0; dim < HEAD_DIM; dim++) begin
                @(negedge clk);
                s_axis_tvalid = 1'b1;
                s_axis_qdata = 8'(query[dim]);
                s_axis_kdata = 8'(keys[key_index][dim]);
                s_axis_vector_last = dim == HEAD_DIM - 1;
                s_axis_sequence_last = key_index == LENGTH - 1;
                #1;
                while (!s_axis_tready) begin
                    @(posedge clk);
                    @(negedge clk);
                    #1;
                end
                @(posedge clk);
                #1;
            end
        end
        s_axis_tvalid = 1'b0;
        s_axis_vector_last = 1'b0;
        s_axis_sequence_last = 1'b0;
    endtask

    task automatic receive_probabilities;
        integer signed maximum;
        integer probability_sum;
        real denominator;
        real expected_probability;
        real actual_probability;
        real difference;
        logic [7:0] held_data;

        maximum = dots[0];
        for (int index = 1; index < LENGTH; index++) begin
            if (dots[index] > maximum)
                maximum = dots[index];
        end
        denominator = 0.0;
        for (int index = 0; index < LENGTH; index++)
            denominator += $exp($itor(dots[index] - maximum) / 2.0);

        while (!m_axis_tvalid) begin
            @(posedge clk);
            #1;
        end
        held_data = m_axis_tdata;
        repeat (2) begin
            @(posedge clk);
            #1;
            assert (m_axis_tvalid && m_axis_tdata == held_data)
                else $fatal(1, "attention output changed under backpressure");
        end

        probability_sum = 0;
        m_axis_tready = 1'b1;
        for (int index = 0; index < LENGTH; index++) begin
            @(negedge clk);
            #1;
            assert (m_axis_tvalid) else $fatal(1, "attention output ended early");
            expected_probability = $exp($itor(dots[index] - maximum) / 2.0)
                                 / denominator;
            actual_probability = $itor(m_axis_tdata) / 255.0;
            difference = actual_probability - expected_probability;
            if (difference < 0.0)
                difference = -difference;
            assert (difference < 0.012)
                else $fatal(1, "attention probability %0d error %f", index,
                            difference);
            assert (m_axis_tlast == (index == LENGTH - 1))
                else $fatal(1, "attention output tlast mismatch");
            probability_sum += int'(m_axis_tdata);
            @(posedge clk);
            #1;
        end
        m_axis_tready = 1'b0;
        assert (probability_sum >= 252 && probability_sum <= 258)
            else $fatal(1, "attention probabilities sum to %0d", probability_sum);
    endtask

    initial begin
        clk                  = 1'b0;
        rst_n                = 1'b0;
        s_axis_tvalid        = 1'b0;
        s_axis_qdata         = '0;
        s_axis_kdata         = '0;
        s_axis_vector_last   = 1'b0;
        s_axis_sequence_last = 1'b0;
        scale_multiplier     = 16'd8;
        scale_shift          = '0;
        m_axis_tready        = 1'b0;

        query = '{2, -1, 3, 1};
        keys[0] = '{1, 0, 1, 0};
        keys[1] = '{0, 1, 1, 1};
        keys[2] = '{1, -1, 0, 2};
        keys[3] = '{-1, 2, 1, 0};
        keys[4] = '{2, 0, -1, 1};
        keys[5] = '{0, -2, 2, 1};
        keys[6] = '{1, 1, 1, -1};
        keys[7] = '{-2, 0, 1, 2};
        for (int key_index = 0; key_index < LENGTH; key_index++) begin
            dots[key_index] = 0;
            for (int dim = 0; dim < HEAD_DIM; dim++)
                dots[key_index] += query[dim] * keys[key_index][dim];
        end

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        fork
            send_attention_inputs();
            receive_probabilities();
        join

        assert (!score_protocol_error && !softmax_protocol_error)
            else $fatal(1, "attention pipeline reported a framing error");
        assert (!score_busy && !softmax_busy)
            else $fatal(1, "attention pipeline did not return idle");

        $display("PASS: scaled dot-product attention stayed within 1.2%% of float");
        $finish;
    end
endmodule
