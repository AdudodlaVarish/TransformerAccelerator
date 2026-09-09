`timescale 1ns/1ps

module tb_transformer_activation;
    localparam int SAMPLE_COUNT = 11;

    logic clk;
    logic rst_n;
    logic s_axis_tvalid;
    logic s_axis_tready;
    logic signed [7:0] s_axis_tdata;
    logic s_axis_tlast;
    logic [1:0] mode;
    logic m_axis_tvalid;
    logic m_axis_tready;
    logic signed [7:0] m_axis_tdata;
    logic m_axis_tlast;
    integer signed samples[SAMPLE_COUNT];

    always #5 clk <= ~clk;

    transformer_activation dut (.*);

    task automatic check_value(input int sample_index, input logic [1:0] test_mode);
        integer signed expected;
        real x;
        real expected_gelu;
        real difference;

        if (test_mode == 0)
            expected = samples[sample_index];
        else if (test_mode == 1)
            expected = samples[sample_index] < 0 ? 0 : samples[sample_index];
        else begin
            x = $itor(samples[sample_index]) / 16.0;
            expected_gelu = 0.5 * x
                          * (1.0 + $tanh(0.7978845608
                                        * (x + 0.044715*x*x*x))) * 16.0;
            difference = $itor($signed(m_axis_tdata)) - expected_gelu;
            if (difference < 0.0)
                difference = -difference;
            assert (difference <= 3.0)
                else $fatal(1, "GELU input %0d differs by %f codes",
                            samples[sample_index], difference);
            expected = int'($signed(m_axis_tdata));
        end

        assert (int'($signed(m_axis_tdata)) == expected)
            else $fatal(1, "mode %0d input %0d: got %0d, expected %0d",
                        test_mode, samples[sample_index], $signed(m_axis_tdata),
                        expected);
        assert (m_axis_tlast == (sample_index == SAMPLE_COUNT - 1))
            else $fatal(1, "activation tlast mismatch");
    endtask

    task automatic run_mode(input logic [1:0] test_mode);
        for (int index = 0; index < SAMPLE_COUNT; index++) begin
            @(negedge clk);
            mode = test_mode;
            m_axis_tready = index == 0 ? 1'b0 : 1'b1;
            s_axis_tvalid = 1'b1;
            s_axis_tdata = 8'(samples[index]);
            s_axis_tlast = index == SAMPLE_COUNT - 1;
            #1;
            assert (s_axis_tready) else $fatal(1, "activation input blocked");
            @(posedge clk);
            #1;
            s_axis_tvalid = 1'b0;

            if (index == 0) begin
                repeat (2) begin
                    assert (m_axis_tvalid) else $fatal(1, "activation output missing");
                    check_value(index, test_mode);
                    @(posedge clk);
                    #1;
                end
                @(negedge clk);
                m_axis_tready = 1'b1;
            end else begin
                assert (m_axis_tvalid) else $fatal(1, "activation output missing");
                check_value(index, test_mode);
            end

            @(posedge clk);
            #1;
            assert (!m_axis_tvalid) else $fatal(1, "activation output did not advance");
            if (index == 0)
                m_axis_tready = 1'b0;
        end
    endtask

    initial begin
        clk           = 1'b0;
        rst_n         = 1'b0;
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = '0;
        s_axis_tlast  = 1'b0;
        mode          = '0;
        m_axis_tready = 1'b0;
        samples = '{-128, -64, -32, -16, -8, 0, 8, 16, 32, 64, 127};

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;
        assert (s_axis_tready && !m_axis_tvalid)
            else $fatal(1, "activation did not reset idle");

        run_mode(2'b00);
        run_mode(2'b01);
        run_mode(2'b10);

        $display("PASS: bypass, ReLU, and fixed-point GELU respected backpressure");
        $finish;
    end
endmodule
