`timescale 1ns/1ps

module tb_attention_softmax;
    localparam int LENGTH = 8;
    localparam int IN_WIDTH = 16;
    localparam int IN_FRAC_BITS = 4;

    logic clk;
    logic rst_n;
    logic s_axis_tvalid;
    logic s_axis_tready;
    logic signed [IN_WIDTH-1:0] s_axis_tdata;
    logic s_axis_tlast;
    logic m_axis_tvalid;
    logic m_axis_tready;
    logic [7:0] m_axis_tdata;
    logic m_axis_tlast;
    logic busy;
    logic protocol_error;
    integer signed vectors[4][LENGTH];

    always #5 clk <= ~clk;

    attention_softmax #(
        .LENGTH(LENGTH),
        .IN_WIDTH(IN_WIDTH),
        .IN_FRAC_BITS(IN_FRAC_BITS)
    ) dut (.*);

    task automatic send_vector(input logic [1:0] vector_index);
        for (int index = 0; index < LENGTH; index++) begin
            @(negedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tdata  = IN_WIDTH'(vectors[vector_index][index]);
            s_axis_tlast  = index == LENGTH - 1;
            #1;
            assert (s_axis_tready) else $fatal(1, "softmax input was not ready");
            @(posedge clk);
            #1;
        end
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
    endtask

    task automatic receive_and_check(input logic [1:0] vector_index);
        integer signed maximum;
        integer probability_sum;
        logic [7:0] held_data;
        logic held_last;
        real denominator;
        real expected_probability;
        real actual_probability;
        real error;

        maximum = vectors[vector_index][0];
        for (int index = 1; index < LENGTH; index++) begin
            if (vectors[vector_index][index] > maximum)
                maximum = vectors[vector_index][index];
        end
        denominator = 0.0;
        for (int index = 0; index < LENGTH; index++)
            denominator += $exp($itor(vectors[vector_index][index] - maximum)
                                / (1 << IN_FRAC_BITS));

        while (!m_axis_tvalid) begin
            @(posedge clk);
            #1;
        end
        held_data = m_axis_tdata;
        held_last = m_axis_tlast;
        repeat (2) begin
            @(posedge clk);
            #1;
            assert (m_axis_tvalid && m_axis_tdata == held_data
                    && m_axis_tlast == held_last)
                else $fatal(1, "softmax output changed while backpressured");
        end

        probability_sum = 0;
        m_axis_tready = 1'b1;
        for (int index = 0; index < LENGTH; index++) begin
            @(negedge clk);
            #1;
            assert (m_axis_tvalid) else $fatal(1, "softmax output ended early");
            expected_probability = $exp($itor(vectors[vector_index][index] - maximum)
                                        / (1 << IN_FRAC_BITS)) / denominator;
            actual_probability = $itor(m_axis_tdata) / 255.0;
            error = actual_probability - expected_probability;
            if (error < 0.0)
                error = -error;
            assert (error < 0.01)
                else $fatal(1, "vector %0d output %0d error %f", vector_index,
                            index, error);
            assert (m_axis_tlast == (index == LENGTH - 1))
                else $fatal(1, "incorrect softmax tlast at index %0d", index);
            probability_sum += int'($unsigned(m_axis_tdata));
            @(posedge clk);
            #1;
        end
        m_axis_tready = 1'b0;
        assert (probability_sum >= 252 && probability_sum <= 258)
            else $fatal(1, "softmax probabilities sum to %0d", probability_sum);
        assert (!m_axis_tvalid && !busy)
            else $fatal(1, "softmax did not return idle");
    endtask

    task automatic send_bad_tlast;
        @(negedge clk);
        s_axis_tvalid = 1'b1;
        s_axis_tdata  = '0;
        s_axis_tlast  = 1'b1;
        @(posedge clk);
        #1;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        assert (protocol_error) else $fatal(1, "bad softmax tlast was not detected");
    endtask

    initial begin
        clk           = 1'b0;
        rst_n         = 1'b0;
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = '0;
        s_axis_tlast  = 1'b0;
        m_axis_tready = 1'b0;

        for (int index = 0; index < LENGTH; index++)
            vectors[0][index] = 0;
        vectors[1] = '{32, 24, 16, 8, 0, -16, -48, -96};
        vectors[2] = '{160, 152, 144, 136, 128, 112, 80, 32};
        vectors[3] = '{31, 22, 14, 7, -3, -15, -40, -91};

        repeat (2) @(posedge clk);
        rst_n = 1'b1;

        for (int vector_index = 0; vector_index < 4; vector_index++) begin
            send_vector(2'(vector_index));
            receive_and_check(2'(vector_index));
        end
        send_bad_tlast();

        $display("PASS: fixed-point attention softmax stayed within 1%% of float");
        $finish;
    end
endmodule
