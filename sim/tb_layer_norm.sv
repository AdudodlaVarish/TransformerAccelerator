`timescale 1ns/1ps

module tb_layer_norm;
    localparam int LENGTH = 8;
    localparam int STAT_FRAC_BITS = 8;
    localparam int NORM_SCALE = 32;

    logic clk;
    logic rst_n;
    logic s_axis_tvalid;
    logic s_axis_tready;
    logic signed [7:0] s_axis_tdata;
    logic signed [15:0] s_axis_tgamma;
    logic signed [7:0] s_axis_tbeta;
    logic s_axis_tlast;
    logic m_axis_tvalid;
    logic m_axis_tready;
    logic signed [7:0] m_axis_tdata;
    logic m_axis_tlast;
    logic busy;
    logic protocol_error;

    integer signed vectors[4][LENGTH];
    integer signed gamma_codes[LENGTH];
    integer signed beta_codes[LENGTH];
    integer signed expected_codes[4][LENGTH];

    always #5 clk <= ~clk;

    layer_norm #(
        .LENGTH(LENGTH),
        .NORM_SCALE(NORM_SCALE)
    ) dut (.*);

    function automatic integer integer_sqrt(input longint unsigned value);
        longint unsigned root;
        longint unsigned candidate;
        begin
            root = 0;
            for (int bit_index = 31; bit_index >= 0; bit_index--) begin
                candidate = root | (64'(1) << bit_index);
                if (candidate * candidate <= value)
                    root = candidate;
            end
            integer_sqrt = int'(root);
        end
    endfunction

    task automatic build_expected(input logic [1:0] vector_index);
        integer signed sum;
        integer signed mean_q;
        integer signed difference_q;
        integer signed stddev_q;
        integer signed normalized;
        integer signed affine;
        longint signed wide_difference;
        longint unsigned variance_sum;

        sum = 0;
        for (int index = 0; index < LENGTH; index++)
            sum += vectors[vector_index][index];
        mean_q = (sum <<< STAT_FRAC_BITS) / LENGTH;

        variance_sum = 0;
        for (int index = 0; index < LENGTH; index++) begin
            difference_q = (vectors[vector_index][index] <<< STAT_FRAC_BITS)
                         - mean_q;
            wide_difference = 64'($signed(difference_q));
            variance_sum += wide_difference * wide_difference;
        end
        stddev_q = integer_sqrt(variance_sum / 64'(LENGTH) + 1);

        for (int index = 0; index < LENGTH; index++) begin
            difference_q = (vectors[vector_index][index] <<< STAT_FRAC_BITS)
                         - mean_q;
            normalized = stddev_q == 0
                       ? 0 : (difference_q * NORM_SCALE) / stddev_q;
            affine = (normalized * gamma_codes[index]) >>> 8;
            affine += beta_codes[index];
            if (affine > 127)
                affine = 127;
            else if (affine < -128)
                affine = -128;
            expected_codes[vector_index][index] = affine;
        end
    endtask

    task automatic send_vector(input logic [1:0] vector_index);
        for (int index = 0; index < LENGTH; index++) begin
            @(negedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tdata  = 8'(vectors[vector_index][index]);
            s_axis_tgamma = 16'(gamma_codes[index]);
            s_axis_tbeta  = 8'(beta_codes[index]);
            s_axis_tlast  = index == LENGTH - 1;
            #1;
            assert (s_axis_tready) else $fatal(1, "layer norm input blocked");
            @(posedge clk);
            #1;
        end
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
    endtask

    task automatic receive_vector(input logic [1:0] vector_index);
        logic signed [7:0] held_data;
        logic held_last;

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
                else $fatal(1, "layer norm output changed under backpressure");
        end

        m_axis_tready = 1'b1;
        for (int index = 0; index < LENGTH; index++) begin
            @(negedge clk);
            #1;
            assert (m_axis_tvalid) else $fatal(1, "layer norm output ended early");
            assert (int'($signed(m_axis_tdata))
                    == expected_codes[vector_index][index])
                else $fatal(1, "vector %0d output %0d: got %0d, expected %0d",
                            vector_index, index, $signed(m_axis_tdata),
                            expected_codes[vector_index][index]);
            assert (m_axis_tlast == (index == LENGTH - 1))
                else $fatal(1, "bad layer norm tlast at output %0d", index);
            @(posedge clk);
            #1;
        end
        m_axis_tready = 1'b0;
        assert (!m_axis_tvalid && !busy)
            else $fatal(1, "layer norm did not return idle");
    endtask

    initial begin
        clk           = 1'b0;
        rst_n         = 1'b0;
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = '0;
        s_axis_tgamma = '0;
        s_axis_tbeta  = '0;
        s_axis_tlast  = 1'b0;
        m_axis_tready = 1'b0;

        vectors[0] = '{5, 5, 5, 5, 5, 5, 5, 5};
        vectors[1] = '{-4, -3, -2, -1, 1, 2, 3, 4};
        vectors[2] = '{12, -7, 3, 9, -11, 4, 6, -2};
        vectors[3] = '{-12, -7, -3, -9, -11, -4, -6, -2};
        for (int index = 0; index < LENGTH; index++) begin
            gamma_codes[index] = 192 + index * 16;
            beta_codes[index] = index - 4;
        end
        for (int vector_index = 0; vector_index < 4; vector_index++)
            build_expected(2'(vector_index));

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;
        assert (s_axis_tready && !busy && !protocol_error)
            else $fatal(1, "layer norm did not reset idle");

        for (int vector_index = 0; vector_index < 4; vector_index++) begin
            send_vector(2'(vector_index));
            receive_vector(2'(vector_index));
        end

        @(negedge clk);
        s_axis_tvalid = 1'b1;
        s_axis_tlast = 1'b1;
        @(posedge clk);
        #1;
        s_axis_tvalid = 1'b0;
        assert (protocol_error) else $fatal(1, "bad layer norm tlast was missed");

        $display("PASS: fixed-point layer normalization matched its integer reference");
        $finish;
    end
endmodule
