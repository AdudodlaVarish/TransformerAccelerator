`timescale 1ns/1ps

module tb_transformer_accelerator_top;
    localparam int ROWS = 4;
    localparam int COLS = 4;
    localparam int K = 4;
    localparam int AXI_DATA_WIDTH = (ROWS + COLS) * 8;
    localparam int AXI_BYTES = AXI_DATA_WIDTH / 8;
    localparam int SOURCE = 32'h0000_0800;
    localparam int DESTINATION = 32'h0000_1000;

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

    logic m_axi_arvalid;
    logic m_axi_arready;
    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_rvalid;
    logic m_axi_rready;
    logic [AXI_DATA_WIDTH-1:0] m_axi_rdata;
    logic m_axi_rlast;
    logic [1:0] m_axi_rresp;
    logic m_axi_awvalid;
    logic m_axi_awready;
    logic [31:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_wvalid;
    logic m_axi_wready;
    logic [AXI_DATA_WIDTH-1:0] m_axi_wdata;
    logic [AXI_BYTES-1:0] m_axi_wstrb;
    logic m_axi_wlast;
    logic m_axi_bvalid;
    logic m_axi_bready;
    logic [1:0] m_axi_bresp;

    logic [AXI_DATA_WIDTH-1:0] memory[0:2047];
    integer signed a[ROWS][K];
    integer signed b[K][COLS];
    integer signed expected[ROWS][COLS];
    logic read_active;
    integer read_word;
    integer read_left;
    logic write_active;
    integer write_word;
    integer write_left;
    logic [31:0] read_data;
    integer timeout;

    always #5 clk <= ~clk;

    assign m_axi_arready = !read_active;
    assign m_axi_rvalid = read_active;
    assign m_axi_rdata = memory[read_word];
    assign m_axi_rlast = read_active && read_left == 1;
    assign m_axi_rresp = 2'b00;
    assign m_axi_awready = !write_active && !m_axi_bvalid;
    assign m_axi_wready = write_active;
    assign m_axi_bresp = 2'b00;

    transformer_accelerator_top dut (.*);

    task automatic axi_write(input logic [7:0] address, input logic [31:0] data);
        @(negedge clk);
        s_axi_awaddr = address;
        s_axi_awvalid = 1'b1;
        #1;
        assert (s_axi_awready) else $fatal(1, "top AXI-Lite AW blocked");
        @(posedge clk);
        #1;
        s_axi_awvalid = 1'b0;

        @(negedge clk);
        s_axi_wdata = data;
        s_axi_wvalid = 1'b1;
        #1;
        assert (s_axi_wready) else $fatal(1, "top AXI-Lite W blocked");
        @(posedge clk);
        #1;
        s_axi_wvalid = 1'b0;
        while (!s_axi_bvalid) begin
            @(posedge clk);
            #1;
        end
        assert (s_axi_bresp == 0) else $fatal(1, "top AXI-Lite write failed");
        s_axi_bready = 1'b1;
        @(posedge clk);
        #1;
        s_axi_bready = 1'b0;
    endtask

    task automatic axi_read(input logic [7:0] address, output logic [31:0] data);
        @(negedge clk);
        s_axi_araddr = address;
        s_axi_arvalid = 1'b1;
        #1;
        assert (s_axi_arready) else $fatal(1, "top AXI-Lite AR blocked");
        @(posedge clk);
        #1;
        s_axi_arvalid = 1'b0;
        assert (s_axi_rvalid && s_axi_rresp == 0)
            else $fatal(1, "top AXI-Lite read failed");
        data = s_axi_rdata;
        s_axi_rready = 1'b1;
        @(posedge clk);
        #1;
        s_axi_rready = 1'b0;
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            read_active <= 1'b0;
            read_word <= 0;
            read_left <= 0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) begin
                assert (m_axi_araddr == SOURCE && m_axi_arlen == 8'(K-1)
                        && m_axi_arsize == 3 && m_axi_arburst == 2'b01)
                    else $fatal(1, "top emitted bad AXI read command");
                read_active <= 1'b1;
                read_word <= m_axi_araddr / AXI_BYTES;
                read_left <= int'(m_axi_arlen) + 1;
            end
            if (m_axi_rvalid && m_axi_rready) begin
                if (read_left == 1) begin
                    read_active <= 1'b0;
                    read_left <= 0;
                end else begin
                    read_word <= read_word + 1;
                    read_left <= read_left - 1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            write_active <= 1'b0;
            write_word <= 0;
            write_left <= 0;
            m_axi_bvalid <= 1'b0;
        end else begin
            if (m_axi_awvalid && m_axi_awready) begin
                assert (m_axi_awaddr == DESTINATION && m_axi_awlen == 1
                        && m_axi_awsize == 3 && m_axi_awburst == 2'b01)
                    else $fatal(1, "top emitted bad AXI write command");
                write_active <= 1'b1;
                write_word <= m_axi_awaddr / AXI_BYTES;
                write_left <= int'(m_axi_awlen) + 1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                assert (m_axi_wstrb == '1 && m_axi_wlast == (write_left == 1))
                    else $fatal(1, "top emitted bad AXI write beat");
                memory[write_word] <= m_axi_wdata;
                if (write_left == 1) begin
                    write_active <= 1'b0;
                    write_left <= 0;
                    m_axi_bvalid <= 1'b1;
                end else begin
                    write_word <= write_word + 1;
                    write_left <= write_left - 1;
                end
            end
            if (m_axi_bvalid && m_axi_bready)
                m_axi_bvalid <= 1'b0;
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        s_axi_awvalid = 1'b0;
        s_axi_awaddr = '0;
        s_axi_wvalid = 1'b0;
        s_axi_wdata = '0;
        s_axi_wstrb = 4'hf;
        s_axi_bready = 1'b0;
        s_axi_arvalid = 1'b0;
        s_axi_araddr = '0;
        s_axi_rready = 1'b0;
        for (int word = 0; word < 2048; word++)
            memory[word] = '0;
        for (int row = 0; row < ROWS; row++)
            for (int index = 0; index < K; index++)
                a[row][index] = ((row + index + 1) % 5) - 2;
        for (int index = 0; index < K; index++)
            for (int col = 0; col < COLS; col++)
                b[index][col] = ((2*index - col + 3) % 5) - 2;
        for (int row = 0; row < ROWS; row++) begin
            for (int col = 0; col < COLS; col++) begin
                expected[row][col] = 0;
                for (int index = 0; index < K; index++)
                    expected[row][col] += a[row][index] * b[index][col];
            end
        end
        for (int index = 0; index < K; index++) begin
            for (int row = 0; row < ROWS; row++)
                memory[SOURCE/AXI_BYTES+index][row*8 +: 8] = 8'(a[row][index]);
            for (int col = 0; col < COLS; col++)
                memory[SOURCE/AXI_BYTES+index][(ROWS+col)*8 +: 8] = 8'(b[index][col]);
        end

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        axi_write(8'h08, SOURCE);
        axi_write(8'h0c, DESTINATION);
        axi_write(8'h10, 1);
        axi_write(8'h14, 1);
        axi_write(8'h18, 0);
        axi_write(8'h1c, 0);
        axi_write(8'h00, 1);

        timeout = 0;
        read_data = 0;
        while (!read_data[1] && timeout < 100) begin
            axi_read(8'h04, read_data);
            assert (!read_data[2]) else $fatal(1, "top reported an error");
            timeout++;
        end
        assert (read_data[1] && !read_data[0]) else $fatal(1, "top timed out");

        for (int index = 0; index < ROWS*COLS; index++) begin
            assert (int'($signed(memory[DESTINATION/AXI_BYTES+(index/AXI_BYTES)]
                                       [(index%AXI_BYTES)*8 +: 8]))
                    == expected[index/COLS][index%COLS])
                else $fatal(1, "top output %0d mismatch", index);
        end
        axi_read(8'h28, read_data);
        assert (read_data == K+ROWS+COLS-2) else $fatal(1, "top compute counter mismatch");
        axi_read(8'h40, read_data);
        assert (read_data == K) else $fatal(1, "top read counter mismatch");
        axi_read(8'h48, read_data);
        assert (read_data == 2) else $fatal(1, "top write counter mismatch");
        axi_read(8'h50, read_data);
        assert (read_data == 1) else $fatal(1, "top tile counter mismatch");
        axi_read(8'h54, read_data);
        assert (read_data == 1) else $fatal(1, "top result counter mismatch");

        $display("PASS: AXI-Lite to DMA top completed a verified DDR GEMM transaction");
        $finish;
    end
endmodule
