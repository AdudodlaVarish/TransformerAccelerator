`timescale 1ns/1ps

module accelerator_control #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 8,
    parameter int REQUANT_MULT_WIDTH = 16,
    parameter int REQUANT_SHIFT_WIDTH = 6
) (
    input  logic clk,
    input  logic rst_n,

    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,
    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,
    input  logic [31:0]           s_axi_wdata,
    input  logic [3:0]            s_axi_wstrb,
    output logic                  s_axi_bvalid,
    input  logic                  s_axi_bready,
    output logic [1:0]            s_axi_bresp,
    input  logic                  s_axi_arvalid,
    output logic                  s_axi_arready,
    input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
    output logic                  s_axi_rvalid,
    input  logic                  s_axi_rready,
    output logic [31:0]           s_axi_rdata,
    output logic [1:0]            s_axi_rresp,

    output logic                  command_start,
    output logic [31:0]           source_address,
    output logic [31:0]           destination_address,
    output logic [15:0]           k_tiles,
    output logic [REQUANT_MULT_WIDTH-1:0] requant_multiplier,
    output logic [REQUANT_SHIFT_WIDTH-1:0] requant_shift,
    output logic signed [DATA_WIDTH-1:0] requant_zero_point,
    input  logic                  accelerator_busy,
    input  logic                  accelerator_done,
    input  logic                  accelerator_error,
    input  logic [63:0]           total_cycles,
    input  logic [63:0]           compute_cycles,
    input  logic [63:0]           input_stall_cycles,
    input  logic [63:0]           output_stall_cycles,
    input  logic [63:0]           memory_read_beats,
    input  logic [63:0]           memory_write_beats,
    input  logic [31:0]           tiles_completed,
    input  logic [31:0]           results_transferred
);
    logic aw_pending;
    logic [ADDR_WIDTH-1:0] awaddr;
    logic w_pending;
    logic [31:0] wdata;
    logic [3:0] wstrb;
    logic done_sticky;
    logic error_sticky;

    function automatic logic [31:0] apply_strobes(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0] strobes
    );
        logic [31:0] merged;
        begin
            merged = old_value;
            for (int byte_index = 0; byte_index < 4; byte_index++) begin
                if (strobes[byte_index])
                    merged[byte_index*8 +: 8] = new_value[byte_index*8 +: 8];
            end
            apply_strobes = merged;
        end
    endfunction

    assign s_axi_awready = rst_n && !aw_pending && !s_axi_bvalid;
    assign s_axi_wready  = rst_n && !w_pending && !s_axi_bvalid;
    assign s_axi_arready = rst_n && !s_axi_rvalid;
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            aw_pending          <= 1'b0;
            awaddr              <= '0;
            w_pending           <= 1'b0;
            wdata               <= '0;
            wstrb               <= '0;
            s_axi_bvalid        <= 1'b0;
            s_axi_rvalid        <= 1'b0;
            s_axi_rdata         <= '0;
            command_start       <= 1'b0;
            source_address      <= '0;
            destination_address <= '0;
            k_tiles             <= '0;
            requant_multiplier  <= REQUANT_MULT_WIDTH'(1);
            requant_shift       <= '0;
            requant_zero_point  <= '0;
            done_sticky         <= 1'b0;
            error_sticky        <= 1'b0;
        end else begin
            command_start <= 1'b0;
            if (accelerator_done)
                done_sticky <= 1'b1;
            if (accelerator_error)
                error_sticky <= 1'b1;
            // command_start is observed by the DMA on this edge; discard old status.
            if (command_start) begin
                done_sticky <= 1'b0;
                error_sticky <= 1'b0;
            end

            if (s_axi_awvalid && s_axi_awready) begin
                aw_pending <= 1'b1;
                awaddr <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_pending <= 1'b1;
                wdata <= s_axi_wdata;
                wstrb <= s_axi_wstrb;
            end

            if (aw_pending && w_pending && !s_axi_bvalid) begin
                case (awaddr)
                    ADDR_WIDTH'(8'h00): begin
                        if (wstrb[0] && wdata[1]) begin
                            done_sticky <= 1'b0;
                            error_sticky <= 1'b0;
                        end
                        if (wstrb[0] && wdata[0] && !accelerator_busy) begin
                            command_start <= 1'b1;
                            done_sticky <= 1'b0;
                            error_sticky <= 1'b0;
                        end
                    end
                    ADDR_WIDTH'(8'h08): source_address <=
                        apply_strobes(source_address, wdata, wstrb);
                    ADDR_WIDTH'(8'h0c): destination_address <=
                        apply_strobes(destination_address, wdata, wstrb);
                    ADDR_WIDTH'(8'h10): k_tiles <=
                        apply_strobes({16'b0, k_tiles}, wdata, wstrb)[15:0];
                    ADDR_WIDTH'(8'h14): requant_multiplier <=
                        REQUANT_MULT_WIDTH'(
                            apply_strobes(32'(requant_multiplier), wdata, wstrb));
                    ADDR_WIDTH'(8'h18): requant_shift <=
                        REQUANT_SHIFT_WIDTH'(
                            apply_strobes(32'(requant_shift), wdata, wstrb));
                    ADDR_WIDTH'(8'h1c): requant_zero_point <= $signed(
                        apply_strobes(32'(requant_zero_point), wdata, wstrb)
                        [DATA_WIDTH-1:0]);
                    default: begin end
                endcase
                aw_pending <= 1'b0;
                w_pending <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr)
                    ADDR_WIDTH'(8'h00): s_axi_rdata <= '0;
                    ADDR_WIDTH'(8'h04): s_axi_rdata <= {29'b0, error_sticky,
                                            done_sticky, accelerator_busy};
                    ADDR_WIDTH'(8'h08): s_axi_rdata <= source_address;
                    ADDR_WIDTH'(8'h0c): s_axi_rdata <= destination_address;
                    ADDR_WIDTH'(8'h10): s_axi_rdata <= {16'b0, k_tiles};
                    ADDR_WIDTH'(8'h14): s_axi_rdata <= 32'(requant_multiplier);
                    ADDR_WIDTH'(8'h18): s_axi_rdata <= 32'(requant_shift);
                    ADDR_WIDTH'(8'h1c): s_axi_rdata <= 32'($signed(requant_zero_point));
                    ADDR_WIDTH'(8'h20): s_axi_rdata <= total_cycles[31:0];
                    ADDR_WIDTH'(8'h24): s_axi_rdata <= total_cycles[63:32];
                    ADDR_WIDTH'(8'h28): s_axi_rdata <= compute_cycles[31:0];
                    ADDR_WIDTH'(8'h2c): s_axi_rdata <= compute_cycles[63:32];
                    ADDR_WIDTH'(8'h30): s_axi_rdata <= input_stall_cycles[31:0];
                    ADDR_WIDTH'(8'h34): s_axi_rdata <= input_stall_cycles[63:32];
                    ADDR_WIDTH'(8'h38): s_axi_rdata <= output_stall_cycles[31:0];
                    ADDR_WIDTH'(8'h3c): s_axi_rdata <= output_stall_cycles[63:32];
                    ADDR_WIDTH'(8'h40): s_axi_rdata <= memory_read_beats[31:0];
                    ADDR_WIDTH'(8'h44): s_axi_rdata <= memory_read_beats[63:32];
                    ADDR_WIDTH'(8'h48): s_axi_rdata <= memory_write_beats[31:0];
                    ADDR_WIDTH'(8'h4c): s_axi_rdata <= memory_write_beats[63:32];
                    ADDR_WIDTH'(8'h50): s_axi_rdata <= tiles_completed;
                    ADDR_WIDTH'(8'h54): s_axi_rdata <= results_transferred;
                    default: s_axi_rdata <= '0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end
endmodule
