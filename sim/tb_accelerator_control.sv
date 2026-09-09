`timescale 1ns/1ps

module tb_accelerator_control;
    logic clk;
    logic rst_n;
    logic s_axi_awvalid;
    logic s_axi_awready;
    logic [7:0] s_axi_awaddr;
    logic s_axi_wvalid;
    logic s_axi_wready;
    logic [31:0] s_axi_wdata;
    logic [3:0] s_axi_wstrb;
    logic s_axi_bvalid;
    logic s_axi_bready;
    logic [1:0] s_axi_bresp;
    logic s_axi_arvalid;
    logic s_axi_arready;
    logic [7:0] s_axi_araddr;
    logic s_axi_rvalid;
    logic s_axi_rready;
    logic [31:0] s_axi_rdata;
    logic [1:0] s_axi_rresp;

    logic command_start;
    logic [31:0] source_address;
    logic [31:0] destination_address;
    logic [15:0] k_tiles;
    logic [15:0] requant_multiplier;
    logic [5:0] requant_shift;
    logic signed [7:0] requant_zero_point;
    logic accelerator_busy;
    logic accelerator_done;
    logic accelerator_error;
    logic [63:0] total_cycles;
    logic [63:0] compute_cycles;
    logic [63:0] input_stall_cycles;
    logic [63:0] output_stall_cycles;
    logic [63:0] memory_read_beats;
    logic [63:0] memory_write_beats;
    logic [31:0] tiles_completed;
    logic [31:0] results_transferred;
    integer completion_countdown;
    integer start_count;
    logic [31:0] read_result;

    always #5 clk <= ~clk;

    accelerator_control dut (.*);

    task automatic axi_write(
        input logic [7:0] address,
        input logic [31:0] data
    );
        @(negedge clk);
        s_axi_awaddr = address;
        s_axi_awvalid = 1'b1;
        #1;
        assert (s_axi_awready) else $fatal(1, "AXI-Lite AW was not accepted");
        @(posedge clk);
        #1;
        s_axi_awvalid = 1'b0;

        @(negedge clk);
        s_axi_wdata = data;
        s_axi_wstrb = 4'hf;
        s_axi_wvalid = 1'b1;
        #1;
        assert (s_axi_wready) else $fatal(1, "AXI-Lite W was not accepted");
        @(posedge clk);
        #1;
        s_axi_wvalid = 1'b0;

        while (!s_axi_bvalid) begin
            @(posedge clk);
            #1;
        end
        assert (s_axi_bresp == 2'b00) else $fatal(1, "AXI-Lite write failed");
        @(negedge clk);
        s_axi_bready = 1'b1;
        @(posedge clk);
        #1;
        s_axi_bready = 1'b0;
    endtask

    task automatic axi_read(
        input logic [7:0] address,
        output logic [31:0] data
    );
        @(negedge clk);
        s_axi_araddr = address;
        s_axi_arvalid = 1'b1;
        #1;
        assert (s_axi_arready) else $fatal(1, "AXI-Lite AR was not accepted");
        @(posedge clk);
        #1;
        assert (s_axi_rvalid && s_axi_rresp == 2'b00)
            else $fatal(1, "AXI-Lite read failed");
        data = s_axi_rdata;
        s_axi_arvalid = 1'b0;
        @(negedge clk);
        s_axi_rready = 1'b1;
        @(posedge clk);
        #1;
        s_axi_rready = 1'b0;
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            accelerator_busy <= 1'b0;
            accelerator_done <= 1'b0;
            completion_countdown <= 0;
            start_count <= 0;
        end else begin
            accelerator_done <= 1'b0;
            if (command_start) begin
                assert (source_address == 32'h1000
                        && destination_address == 32'h2000
                        && k_tiles == 3 && requant_multiplier == 123
                        && requant_shift == 7 && requant_zero_point == -4)
                    else $fatal(1, "command used incorrect register values");
                accelerator_busy <= 1'b1;
                completion_countdown <= 4;
                start_count <= start_count + 1;
            end else if (completion_countdown != 0) begin
                completion_countdown <= completion_countdown - 1;
                if (completion_countdown == 1) begin
                    accelerator_busy <= 1'b0;
                    accelerator_done <= 1'b1;
                end
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        s_axi_awvalid = 1'b0;
        s_axi_awaddr = '0;
        s_axi_wvalid = 1'b0;
        s_axi_wdata = '0;
        s_axi_wstrb = '0;
        s_axi_bready = 1'b0;
        s_axi_arvalid = 1'b0;
        s_axi_araddr = '0;
        s_axi_rready = 1'b0;
        accelerator_error = 1'b0;
        total_cycles = 64'h1234_5678_9abc_def0;
        compute_cycles = 64'h1122_3344_5566_7788;
        input_stall_cycles = 64'd3;
        output_stall_cycles = 64'd5;
        memory_read_beats = 64'd15;
        memory_write_beats = 64'd2;
        tiles_completed = 32'd3;
        results_transferred = 32'd1;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        axi_write(8'h08, 32'h1000);
        axi_write(8'h0c, 32'h2000);
        axi_write(8'h10, 32'd3);
        axi_write(8'h14, 32'd123);
        axi_write(8'h18, 32'd7);
        axi_write(8'h1c, 32'hffff_fffc);
        axi_read(8'h1c, read_result);
        assert ($signed(read_result) == -4) else $fatal(1, "signed config readback failed");

        axi_write(8'h00, 32'd1);
        while (start_count == 0) @(posedge clk);
        axi_write(8'h00, 32'd1);
        assert (start_count == 1) else $fatal(1, "busy accelerator restarted");
        while (accelerator_busy) @(posedge clk);
        repeat (2) @(posedge clk);

        axi_read(8'h04, read_result);
        assert (read_result[1] && !read_result[2] && !read_result[0])
            else $fatal(1, "completion status was not sticky");
        axi_read(8'h20, read_result);
        assert (read_result == 32'h9abc_def0) else $fatal(1, "counter low read failed");
        axi_read(8'h24, read_result);
        assert (read_result == 32'h1234_5678) else $fatal(1, "counter high read failed");
        axi_read(8'h50, read_result);
        assert (read_result == 3) else $fatal(1, "tile counter read failed");

        axi_write(8'h00, 32'd2);
        axi_read(8'h04, read_result);
        assert (read_result[2:1] == 0) else $fatal(1, "status clear failed");

        @(negedge clk);
        accelerator_error = 1'b1;
        @(posedge clk);
        #1;
        accelerator_error = 1'b0;
        axi_read(8'h04, read_result);
        assert (read_result[2]) else $fatal(1, "accelerator error was not sticky");

        axi_write(8'h00, 32'd1);
        while (start_count != 2) @(posedge clk);
        axi_read(8'h04, read_result);
        assert (!read_result[2]) else $fatal(1, "old error survived a new command");
        while (accelerator_busy) @(posedge clk);

        $display("PASS: AXI-Lite control sequenced a command and exposed counters");
        $finish;
    end
endmodule
