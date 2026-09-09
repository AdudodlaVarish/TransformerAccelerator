`timescale 1ns/1ps

module transformer_accelerator_top #(
    parameter int ROWS = 4,
    parameter int COLS = 4,
    parameter int K = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH = 32,
    parameter int REQUANT_MULT_WIDTH = 16,
    parameter string BUFFER_RAM_STYLE = "block",
    parameter int AXI_ADDR_WIDTH = 32,
    parameter int AXI_DATA_WIDTH = (ROWS + COLS) * DATA_WIDTH,
    parameter int MAX_READ_BURST = 16,
    localparam int AXI_BYTES = AXI_DATA_WIDTH / 8,
    localparam int REQUANT_SHIFT_WIDTH =
        $clog2(ACC_WIDTH + REQUANT_MULT_WIDTH + 2)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic       s_axi_awvalid,
    output logic       s_axi_awready,
    input  logic [7:0] s_axi_awaddr,
    input  logic       s_axi_wvalid,
    output logic       s_axi_wready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0] s_axi_wstrb,
    output logic       s_axi_bvalid,
    input  logic       s_axi_bready,
    output logic [1:0] s_axi_bresp,
    input  logic       s_axi_arvalid,
    output logic       s_axi_arready,
    input  logic [7:0] s_axi_araddr,
    output logic       s_axi_rvalid,
    input  logic       s_axi_rready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,

    output logic                      m_axi_arvalid,
    input  logic                      m_axi_arready,
    output logic [AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]                m_axi_arlen,
    output logic [2:0]                m_axi_arsize,
    output logic [1:0]                m_axi_arburst,
    input  logic                      m_axi_rvalid,
    output logic                      m_axi_rready,
    input  logic [AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  logic                      m_axi_rlast,
    input  logic [1:0]                m_axi_rresp,

    output logic                      m_axi_awvalid,
    input  logic                      m_axi_awready,
    output logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]                m_axi_awlen,
    output logic [2:0]                m_axi_awsize,
    output logic [1:0]                m_axi_awburst,
    output logic                      m_axi_wvalid,
    input  logic                      m_axi_wready,
    output logic [AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output logic [AXI_BYTES-1:0]      m_axi_wstrb,
    output logic                      m_axi_wlast,
    input  logic                      m_axi_bvalid,
    output logic                      m_axi_bready,
    input  logic [1:0]                m_axi_bresp
);
    logic command_start;
    logic [31:0] source_address;
    logic [31:0] destination_address;
    logic [15:0] k_tiles;
    logic [REQUANT_MULT_WIDTH-1:0] requant_multiplier;
    logic [REQUANT_SHIFT_WIDTH-1:0] requant_shift;
    logic signed [DATA_WIDTH-1:0] requant_zero_point;
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

    accelerator_control #(
        .DATA_WIDTH(DATA_WIDTH),
        .REQUANT_MULT_WIDTH(REQUANT_MULT_WIDTH),
        .REQUANT_SHIFT_WIDTH(REQUANT_SHIFT_WIDTH)
    ) control (
        .clk,
        .rst_n,
        .s_axi_awvalid,
        .s_axi_awready,
        .s_axi_awaddr,
        .s_axi_wvalid,
        .s_axi_wready,
        .s_axi_wdata,
        .s_axi_wstrb,
        .s_axi_bvalid,
        .s_axi_bready,
        .s_axi_bresp,
        .s_axi_arvalid,
        .s_axi_arready,
        .s_axi_araddr,
        .s_axi_rvalid,
        .s_axi_rready,
        .s_axi_rdata,
        .s_axi_rresp,
        .command_start,
        .source_address,
        .destination_address,
        .k_tiles,
        .requant_multiplier,
        .requant_shift,
        .requant_zero_point,
        .accelerator_busy,
        .accelerator_done,
        .accelerator_error,
        .total_cycles,
        .compute_cycles,
        .input_stall_cycles,
        .output_stall_cycles,
        .memory_read_beats,
        .memory_write_beats,
        .tiles_completed,
        .results_transferred
    );

    transformer_axi_dma #(
        .ROWS(ROWS),
        .COLS(COLS),
        .K(K),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .REQUANT_MULT_WIDTH(REQUANT_MULT_WIDTH),
        .BUFFER_RAM_STYLE(BUFFER_RAM_STYLE),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .MAX_READ_BURST(MAX_READ_BURST)
    ) dma (
        .clk,
        .rst_n,
        .start(command_start),
        .source_address(AXI_ADDR_WIDTH'(source_address)),
        .destination_address(AXI_ADDR_WIDTH'(destination_address)),
        .k_tiles,
        .requant_multiplier,
        .requant_shift,
        .requant_zero_point,
        .busy(accelerator_busy),
        .done(accelerator_done),
        .error(accelerator_error),
        .m_axi_arvalid,
        .m_axi_arready,
        .m_axi_araddr,
        .m_axi_arlen,
        .m_axi_arsize,
        .m_axi_arburst,
        .m_axi_rvalid,
        .m_axi_rready,
        .m_axi_rdata,
        .m_axi_rlast,
        .m_axi_rresp,
        .m_axi_awvalid,
        .m_axi_awready,
        .m_axi_awaddr,
        .m_axi_awlen,
        .m_axi_awsize,
        .m_axi_awburst,
        .m_axi_wvalid,
        .m_axi_wready,
        .m_axi_wdata,
        .m_axi_wstrb,
        .m_axi_wlast,
        .m_axi_bvalid,
        .m_axi_bready,
        .m_axi_bresp,
        .memory_read_beats,
        .memory_write_beats,
        .total_cycles,
        .compute_cycles,
        .input_stall_cycles,
        .output_stall_cycles,
        .tiles_completed,
        .results_transferred
    );
endmodule
