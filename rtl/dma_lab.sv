// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
// I keep the game-frame application ports beside the DMA integration here.
// The upstream engine moves bytes; snapshot_guard and project_point give those
// bytes an application meaning. The simulation harness still joins RAM to the
// application ports, so this top isn't an autonomous game-frame processor yet.
module dma_lab #
(
    // TLP data width
    parameter TLP_DATA_WIDTH = 64,
    // TLP strobe width
    parameter TLP_STRB_WIDTH = TLP_DATA_WIDTH/32,
    // TLP header width
    parameter TLP_HDR_WIDTH = 128,
    // TLP segment count
    parameter TLP_SEG_COUNT = 1,
    // TX sequence number count
    parameter TX_SEQ_NUM_COUNT = 1,
    // TX sequence number width
    parameter TX_SEQ_NUM_WIDTH = 6,
    // TX sequence number tracking enable
    parameter TX_SEQ_NUM_ENABLE = 0,
    // RAM select width
    parameter RAM_SEL_WIDTH = 2,
    // RAM address width
    parameter RAM_ADDR_WIDTH = 16,
    // RAM segment count
    parameter RAM_SEG_COUNT = TLP_SEG_COUNT*2,
    // RAM segment data width
    parameter RAM_SEG_DATA_WIDTH = TLP_DATA_WIDTH*2/RAM_SEG_COUNT,
    // RAM segment byte enable width
    parameter RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH/8,
    // RAM segment address width
    parameter RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH),
    // PCIe address width
    parameter PCIE_ADDR_WIDTH = 64,
    // PCIe tag count
    parameter PCIE_TAG_COUNT = 4,
    // Immediate enable
    parameter IMM_ENABLE = 0,
    // Immediate width
    parameter IMM_WIDTH = 32,
    // Length field width
    parameter LEN_WIDTH = 20,
    // Tag field width
    parameter TAG_WIDTH = 8,
    // Operation table size (read)
    parameter READ_OP_TABLE_SIZE = PCIE_TAG_COUNT,
    // In-flight transmit limit (read)
    parameter READ_TX_LIMIT = 2**TX_SEQ_NUM_WIDTH,
    // Completion header flow control credit limit (read)
    parameter READ_CPLH_FC_LIMIT = 0,
    // Completion data flow control credit limit (read)
    parameter READ_CPLD_FC_LIMIT = READ_CPLH_FC_LIMIT*4,
    // Operation table size (write)
    parameter WRITE_OP_TABLE_SIZE = 2**TX_SEQ_NUM_WIDTH,
    // In-flight transmit limit (write)
    parameter WRITE_TX_LIMIT = 2**TX_SEQ_NUM_WIDTH,
    // Force 64 bit address
    parameter TLP_FORCE_64_BIT_ADDR = 0,
    // Requester ID mash
    parameter CHECK_BUS_NUMBER = 1
)
(
    input wire clk,
    input wire rst,
    input wire [TLP_DATA_WIDTH-1:0]                     rx_cpl_tlp_data,
    input wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]        rx_cpl_tlp_hdr,
    input wire [TLP_SEG_COUNT*4-1:0]                    rx_cpl_tlp_error,
    input wire [TLP_SEG_COUNT-1:0]                      rx_cpl_tlp_valid,
    input wire [TLP_SEG_COUNT-1:0]                      rx_cpl_tlp_sop,
    input wire [TLP_SEG_COUNT-1:0]                      rx_cpl_tlp_eop,
    output wire rx_cpl_tlp_ready,
    output wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]        tx_rd_req_tlp_hdr,
    output wire [TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH-1:0]     tx_rd_req_tlp_seq,
    output wire [TLP_SEG_COUNT-1:0]                      tx_rd_req_tlp_valid,
    output wire [TLP_SEG_COUNT-1:0]                      tx_rd_req_tlp_sop,
    output wire [TLP_SEG_COUNT-1:0]                      tx_rd_req_tlp_eop,
    input wire tx_rd_req_tlp_ready,
    output wire [TLP_DATA_WIDTH-1:0]                     tx_wr_req_tlp_data,
    output wire [TLP_STRB_WIDTH-1:0]                     tx_wr_req_tlp_strb,
    output wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]        tx_wr_req_tlp_hdr,
    output wire [TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH-1:0]     tx_wr_req_tlp_seq,
    output wire [TLP_SEG_COUNT-1:0]                      tx_wr_req_tlp_valid,
    output wire [TLP_SEG_COUNT-1:0]                      tx_wr_req_tlp_sop,
    output wire [TLP_SEG_COUNT-1:0]                      tx_wr_req_tlp_eop,
    input wire tx_wr_req_tlp_ready,
    input wire [TX_SEQ_NUM_COUNT*TX_SEQ_NUM_WIDTH-1:0]  s_axis_rd_req_tx_seq_num,
    input wire [TX_SEQ_NUM_COUNT-1:0]                   s_axis_rd_req_tx_seq_num_valid,
    input wire [TX_SEQ_NUM_COUNT*TX_SEQ_NUM_WIDTH-1:0]  s_axis_wr_req_tx_seq_num,
    input wire [TX_SEQ_NUM_COUNT-1:0]                   s_axis_wr_req_tx_seq_num_valid,
    input wire ext_tag_enable,
    input wire rcb_128b,
    input wire [15:0]                                   requester_id,
    input wire [2:0]                                    max_read_request_size,
    input wire [2:0]                                    max_payload_size,
    output wire status_rd_busy,
    output wire status_wr_busy,
    output wire status_error_cor,
    output wire status_error_uncor,
    output wire [$clog2(READ_OP_TABLE_SIZE)-1:0]         stat_rd_op_start_tag,
    output wire [LEN_WIDTH-1:0]                          stat_rd_op_start_len,
    output wire stat_rd_op_start_valid,
    output wire [$clog2(READ_OP_TABLE_SIZE)-1:0]         stat_rd_op_finish_tag,
    output wire [3:0]                                    stat_rd_op_finish_status,
    output wire stat_rd_op_finish_valid,
    output wire [$clog2(PCIE_TAG_COUNT)-1:0]             stat_rd_req_start_tag,
    output wire [12:0]                                   stat_rd_req_start_len,
    output wire stat_rd_req_start_valid,
    output wire [$clog2(PCIE_TAG_COUNT)-1:0]             stat_rd_req_finish_tag,
    output wire [3:0]                                    stat_rd_req_finish_status,
    output wire stat_rd_req_finish_valid,
    output wire stat_rd_req_timeout,
    output wire stat_rd_op_table_full,
    output wire stat_rd_no_tags,
    output wire stat_rd_tx_limit,
    output wire stat_rd_tx_stall,
    output wire [$clog2(WRITE_OP_TABLE_SIZE)-1:0]        stat_wr_op_start_tag,
    output wire [LEN_WIDTH-1:0]                          stat_wr_op_start_len,
    output wire stat_wr_op_start_valid,
    output wire [$clog2(WRITE_OP_TABLE_SIZE)-1:0]        stat_wr_op_finish_tag,
    output wire [3:0]                                    stat_wr_op_finish_status,
    output wire stat_wr_op_finish_valid,
    output wire [$clog2(WRITE_OP_TABLE_SIZE)-1:0]        stat_wr_req_start_tag,
    output wire [12:0]                                   stat_wr_req_start_len,
    output wire stat_wr_req_start_valid,
    output wire [$clog2(WRITE_OP_TABLE_SIZE)-1:0]        stat_wr_req_finish_tag,
    output wire [3:0]                                    stat_wr_req_finish_status,
    output wire stat_wr_req_finish_valid,
    output wire stat_wr_op_table_full,
    output wire stat_wr_tx_limit,
    output wire stat_wr_tx_stall,
    input wire [TLP_DATA_WIDTH-1:0]               rx_req_tlp_data,
    input wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]  rx_req_tlp_hdr,
    input wire [TLP_SEG_COUNT-1:0]                rx_req_tlp_valid,
    input wire [TLP_SEG_COUNT-1:0]                rx_req_tlp_sop,
    input wire [TLP_SEG_COUNT-1:0]                rx_req_tlp_eop,
    output wire rx_req_tlp_ready,
    output wire [TLP_DATA_WIDTH-1:0]               tx_cpl_tlp_data,
    output wire [TLP_STRB_WIDTH-1:0]               tx_cpl_tlp_strb,
    output wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]  tx_cpl_tlp_hdr,
    output wire [TLP_SEG_COUNT-1:0]                tx_cpl_tlp_valid,
    output wire [TLP_SEG_COUNT-1:0]                tx_cpl_tlp_sop,
    output wire [TLP_SEG_COUNT-1:0]                tx_cpl_tlp_eop,
    input wire tx_cpl_tlp_ready,
    input wire [15:0]                             completer_id,
    input wire bus_master_enable,
    input wire [31:0] fir_in_data,
    input wire fir_in_valid, fir_out_ready,
    output wire fir_in_ready, fir_out_valid, fir_saturated,
    output wire [31:0] fir_out_data,
    input wire snapshot_start, snapshot_in_valid, snapshot_in_last,
    input wire [31:0] snapshot_in_data,
    output wire snapshot_in_ready, snapshot_done, snapshot_accepted,
    output wire [31:0] snapshot_sequence, snapshot_entity_count,
    input wire signed [31:0] point_x,point_y,point_z,
    input wire [511:0] point_matrix,
    output wire signed [31:0] point_ndc_x,point_ndc_y,
    output wire point_visible
);
    wire [PCIE_ADDR_WIDTH-1:0]                    s_axis_read_desc_pcie_addr;
    wire [RAM_SEL_WIDTH-1:0]                      s_axis_read_desc_ram_sel;
    wire [RAM_ADDR_WIDTH-1:0]                     s_axis_read_desc_ram_addr;
    wire [LEN_WIDTH-1:0]                          s_axis_read_desc_len;
    wire [TAG_WIDTH-1:0]                          s_axis_read_desc_tag;
    wire s_axis_read_desc_valid;
    wire s_axis_read_desc_ready;
    wire [TAG_WIDTH-1:0]                          m_axis_read_desc_status_tag;
    wire [3:0]                                    m_axis_read_desc_status_error;
    wire m_axis_read_desc_status_valid;
    wire [PCIE_ADDR_WIDTH-1:0]                    s_axis_write_desc_pcie_addr;
    wire [RAM_SEL_WIDTH-1:0]                      s_axis_write_desc_ram_sel;
    wire [RAM_ADDR_WIDTH-1:0]                     s_axis_write_desc_ram_addr;
    wire [IMM_WIDTH-1:0]                          s_axis_write_desc_imm;
    wire s_axis_write_desc_imm_en;
    wire [LEN_WIDTH-1:0]                          s_axis_write_desc_len;
    wire [TAG_WIDTH-1:0]                          s_axis_write_desc_tag;
    wire s_axis_write_desc_valid;
    wire s_axis_write_desc_ready;
    wire [TAG_WIDTH-1:0]                          m_axis_write_desc_status_tag;
    wire [3:0]                                    m_axis_write_desc_status_error;
    wire m_axis_write_desc_status_valid;
    wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]        ram_rd_cmd_sel;
    wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]   ram_rd_cmd_addr;
    wire [RAM_SEG_COUNT-1:0]                      ram_rd_cmd_valid;
    wire [RAM_SEG_COUNT-1:0]                      ram_rd_cmd_ready;
    wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]   ram_rd_resp_data;
    wire [RAM_SEG_COUNT-1:0]                      ram_rd_resp_valid;
    wire [RAM_SEG_COUNT-1:0]                      ram_rd_resp_ready;
    wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]        ram_wr_cmd_sel;
    wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]     ram_wr_cmd_be;
    wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]   ram_wr_cmd_addr;
    wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]   ram_wr_cmd_data;
    wire [RAM_SEG_COUNT-1:0]                      ram_wr_cmd_valid;
    wire [RAM_SEG_COUNT-1:0]                      ram_wr_cmd_ready;
    wire [RAM_SEG_COUNT-1:0]                      ram_wr_done;
    wire read_enable;
    wire write_enable;
    wire [17-1:0]              m_axil_awaddr;
    wire [2:0]                              m_axil_awprot;
    wire m_axil_awvalid;
    wire m_axil_awready;
    wire [32-1:0]              m_axil_wdata;
    wire [4-1:0]              m_axil_wstrb;
    wire m_axil_wvalid;
    wire m_axil_wready;
    wire [1:0]                              m_axil_bresp;
    wire m_axil_bvalid;
    wire m_axil_bready;
    wire [17-1:0]              m_axil_araddr;
    wire [2:0]                              m_axil_arprot;
    wire m_axil_arvalid;
    wire m_axil_arready;
    wire [32-1:0]              m_axil_rdata;
    wire [1:0]                              m_axil_rresp;
    wire m_axil_rvalid;
    wire m_axil_rready;
    wire bar_status_error_cor;
    wire bar_status_error_uncor;
wire halted, engine_reset;
dma_if_pcie #(
    .TLP_DATA_WIDTH(TLP_DATA_WIDTH),
    .TLP_STRB_WIDTH(TLP_STRB_WIDTH),
    .TLP_HDR_WIDTH(TLP_HDR_WIDTH),
    .TLP_SEG_COUNT(TLP_SEG_COUNT),
    .TX_SEQ_NUM_COUNT(TX_SEQ_NUM_COUNT),
    .TX_SEQ_NUM_WIDTH(TX_SEQ_NUM_WIDTH),
    .TX_SEQ_NUM_ENABLE(TX_SEQ_NUM_ENABLE),
    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .RAM_SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .PCIE_ADDR_WIDTH(PCIE_ADDR_WIDTH),
    .PCIE_TAG_COUNT(PCIE_TAG_COUNT),
    .IMM_ENABLE(IMM_ENABLE),
    .IMM_WIDTH(IMM_WIDTH),
    .LEN_WIDTH(LEN_WIDTH),
    .TAG_WIDTH(TAG_WIDTH),
    .READ_OP_TABLE_SIZE(READ_OP_TABLE_SIZE),
    .READ_TX_LIMIT(READ_TX_LIMIT),
    .READ_CPLH_FC_LIMIT(READ_CPLH_FC_LIMIT),
    .READ_CPLD_FC_LIMIT(READ_CPLD_FC_LIMIT),
    .WRITE_OP_TABLE_SIZE(WRITE_OP_TABLE_SIZE),
    .WRITE_TX_LIMIT(WRITE_TX_LIMIT),
    .TLP_FORCE_64_BIT_ADDR(TLP_FORCE_64_BIT_ADDR),
    .CHECK_BUS_NUMBER(CHECK_BUS_NUMBER)
) engine (
    .clk(clk),
    .rst(rst || engine_reset),
    .rx_cpl_tlp_data(rx_cpl_tlp_data),
    .rx_cpl_tlp_hdr(rx_cpl_tlp_hdr),
    .rx_cpl_tlp_error(rx_cpl_tlp_error),
    .rx_cpl_tlp_valid(rx_cpl_tlp_valid),
    .rx_cpl_tlp_sop(rx_cpl_tlp_sop),
    .rx_cpl_tlp_eop(rx_cpl_tlp_eop),
    .rx_cpl_tlp_ready(rx_cpl_tlp_ready),
    .tx_rd_req_tlp_hdr(tx_rd_req_tlp_hdr),
    .tx_rd_req_tlp_seq(tx_rd_req_tlp_seq),
    .tx_rd_req_tlp_valid(tx_rd_req_tlp_valid),
    .tx_rd_req_tlp_sop(tx_rd_req_tlp_sop),
    .tx_rd_req_tlp_eop(tx_rd_req_tlp_eop),
    .tx_rd_req_tlp_ready(tx_rd_req_tlp_ready),
    .tx_wr_req_tlp_data(tx_wr_req_tlp_data),
    .tx_wr_req_tlp_strb(tx_wr_req_tlp_strb),
    .tx_wr_req_tlp_hdr(tx_wr_req_tlp_hdr),
    .tx_wr_req_tlp_seq(tx_wr_req_tlp_seq),
    .tx_wr_req_tlp_valid(tx_wr_req_tlp_valid),
    .tx_wr_req_tlp_sop(tx_wr_req_tlp_sop),
    .tx_wr_req_tlp_eop(tx_wr_req_tlp_eop),
    .tx_wr_req_tlp_ready(tx_wr_req_tlp_ready),
    .s_axis_rd_req_tx_seq_num(s_axis_rd_req_tx_seq_num),
    .s_axis_rd_req_tx_seq_num_valid(s_axis_rd_req_tx_seq_num_valid),
    .s_axis_wr_req_tx_seq_num(s_axis_wr_req_tx_seq_num),
    .s_axis_wr_req_tx_seq_num_valid(s_axis_wr_req_tx_seq_num_valid),
    .s_axis_read_desc_pcie_addr(s_axis_read_desc_pcie_addr),
    .s_axis_read_desc_ram_sel(s_axis_read_desc_ram_sel),
    .s_axis_read_desc_ram_addr(s_axis_read_desc_ram_addr),
    .s_axis_read_desc_len(s_axis_read_desc_len),
    .s_axis_read_desc_tag(s_axis_read_desc_tag),
    .s_axis_read_desc_valid(s_axis_read_desc_valid),
    .s_axis_read_desc_ready(s_axis_read_desc_ready),
    .m_axis_read_desc_status_tag(m_axis_read_desc_status_tag),
    .m_axis_read_desc_status_error(m_axis_read_desc_status_error),
    .m_axis_read_desc_status_valid(m_axis_read_desc_status_valid),
    .s_axis_write_desc_pcie_addr(s_axis_write_desc_pcie_addr),
    .s_axis_write_desc_ram_sel(s_axis_write_desc_ram_sel),
    .s_axis_write_desc_ram_addr(s_axis_write_desc_ram_addr),
    .s_axis_write_desc_imm(s_axis_write_desc_imm),
    .s_axis_write_desc_imm_en(s_axis_write_desc_imm_en),
    .s_axis_write_desc_len(s_axis_write_desc_len),
    .s_axis_write_desc_tag(s_axis_write_desc_tag),
    .s_axis_write_desc_valid(s_axis_write_desc_valid),
    .s_axis_write_desc_ready(s_axis_write_desc_ready),
    .m_axis_write_desc_status_tag(m_axis_write_desc_status_tag),
    .m_axis_write_desc_status_error(m_axis_write_desc_status_error),
    .m_axis_write_desc_status_valid(m_axis_write_desc_status_valid),
    .ram_rd_cmd_sel(ram_rd_cmd_sel),
    .ram_rd_cmd_addr(ram_rd_cmd_addr),
    .ram_rd_cmd_valid(ram_rd_cmd_valid),
    .ram_rd_cmd_ready(ram_rd_cmd_ready),
    .ram_rd_resp_data(ram_rd_resp_data),
    .ram_rd_resp_valid(ram_rd_resp_valid),
    .ram_rd_resp_ready(ram_rd_resp_ready),
    .ram_wr_cmd_sel(ram_wr_cmd_sel),
    .ram_wr_cmd_be(ram_wr_cmd_be),
    .ram_wr_cmd_addr(ram_wr_cmd_addr),
    .ram_wr_cmd_data(ram_wr_cmd_data),
    .ram_wr_cmd_valid(ram_wr_cmd_valid),
    .ram_wr_cmd_ready(ram_wr_cmd_ready),
    .ram_wr_done(ram_wr_done),
    .read_enable(bus_master_enable && !halted),
    .write_enable(bus_master_enable && !halted),
    .ext_tag_enable(ext_tag_enable),
    .rcb_128b(rcb_128b),
    .requester_id(requester_id),
    .max_read_request_size(max_read_request_size),
    .max_payload_size(max_payload_size),
    .status_rd_busy(status_rd_busy),
    .status_wr_busy(status_wr_busy),
    .status_error_cor(status_error_cor),
    .status_error_uncor(status_error_uncor),
    .stat_rd_op_start_tag(stat_rd_op_start_tag),
    .stat_rd_op_start_len(stat_rd_op_start_len),
    .stat_rd_op_start_valid(stat_rd_op_start_valid),
    .stat_rd_op_finish_tag(stat_rd_op_finish_tag),
    .stat_rd_op_finish_status(stat_rd_op_finish_status),
    .stat_rd_op_finish_valid(stat_rd_op_finish_valid),
    .stat_rd_req_start_tag(stat_rd_req_start_tag),
    .stat_rd_req_start_len(stat_rd_req_start_len),
    .stat_rd_req_start_valid(stat_rd_req_start_valid),
    .stat_rd_req_finish_tag(stat_rd_req_finish_tag),
    .stat_rd_req_finish_status(stat_rd_req_finish_status),
    .stat_rd_req_finish_valid(stat_rd_req_finish_valid),
    .stat_rd_req_timeout(stat_rd_req_timeout),
    .stat_rd_op_table_full(stat_rd_op_table_full),
    .stat_rd_no_tags(stat_rd_no_tags),
    .stat_rd_tx_limit(stat_rd_tx_limit),
    .stat_rd_tx_stall(stat_rd_tx_stall),
    .stat_wr_op_start_tag(stat_wr_op_start_tag),
    .stat_wr_op_start_len(stat_wr_op_start_len),
    .stat_wr_op_start_valid(stat_wr_op_start_valid),
    .stat_wr_op_finish_tag(stat_wr_op_finish_tag),
    .stat_wr_op_finish_status(stat_wr_op_finish_status),
    .stat_wr_op_finish_valid(stat_wr_op_finish_valid),
    .stat_wr_req_start_tag(stat_wr_req_start_tag),
    .stat_wr_req_start_len(stat_wr_req_start_len),
    .stat_wr_req_start_valid(stat_wr_req_start_valid),
    .stat_wr_req_finish_tag(stat_wr_req_finish_tag),
    .stat_wr_req_finish_status(stat_wr_req_finish_status),
    .stat_wr_req_finish_valid(stat_wr_req_finish_valid),
    .stat_wr_op_table_full(stat_wr_op_table_full),
    .stat_wr_tx_limit(stat_wr_tx_limit),
    .stat_wr_tx_stall(stat_wr_tx_stall)
);
pcie_axil_master #(.TLP_DATA_WIDTH(TLP_DATA_WIDTH), .AXIL_ADDR_WIDTH(17)) bar_bridge (
    .clk(clk),
    .rst(rst),
    .rx_req_tlp_data(rx_req_tlp_data),
    .rx_req_tlp_hdr(rx_req_tlp_hdr),
    .rx_req_tlp_valid(rx_req_tlp_valid),
    .rx_req_tlp_sop(rx_req_tlp_sop),
    .rx_req_tlp_eop(rx_req_tlp_eop),
    .rx_req_tlp_ready(rx_req_tlp_ready),
    .tx_cpl_tlp_data(tx_cpl_tlp_data),
    .tx_cpl_tlp_strb(tx_cpl_tlp_strb),
    .tx_cpl_tlp_hdr(tx_cpl_tlp_hdr),
    .tx_cpl_tlp_valid(tx_cpl_tlp_valid),
    .tx_cpl_tlp_sop(tx_cpl_tlp_sop),
    .tx_cpl_tlp_eop(tx_cpl_tlp_eop),
    .tx_cpl_tlp_ready(tx_cpl_tlp_ready),
    .m_axil_awaddr(m_axil_awaddr),
    .m_axil_awprot(m_axil_awprot),
    .m_axil_awvalid(m_axil_awvalid),
    .m_axil_awready(m_axil_awready),
    .m_axil_wdata(m_axil_wdata),
    .m_axil_wstrb(m_axil_wstrb),
    .m_axil_wvalid(m_axil_wvalid),
    .m_axil_wready(m_axil_wready),
    .m_axil_bresp(m_axil_bresp),
    .m_axil_bvalid(m_axil_bvalid),
    .m_axil_bready(m_axil_bready),
    .m_axil_araddr(m_axil_araddr),
    .m_axil_arprot(m_axil_arprot),
    .m_axil_arvalid(m_axil_arvalid),
    .m_axil_arready(m_axil_arready),
    .m_axil_rdata(m_axil_rdata),
    .m_axil_rresp(m_axil_rresp),
    .m_axil_rvalid(m_axil_rvalid),
    .m_axil_rready(m_axil_rready),
    .completer_id(completer_id),
    .status_error_cor(bar_status_error_cor),
    .status_error_uncor(bar_status_error_uncor)
);
lab_control control (
    .clk(clk),
    .rst(rst),
    .bus_master_enable(bus_master_enable),
    .halted(halted),
    .engine_reset(engine_reset),
    .m_axil_awaddr(m_axil_awaddr),
    .m_axil_awprot(m_axil_awprot),
    .m_axil_awvalid(m_axil_awvalid),
    .m_axil_awready(m_axil_awready),
    .m_axil_wdata(m_axil_wdata),
    .m_axil_wstrb(m_axil_wstrb),
    .m_axil_wvalid(m_axil_wvalid),
    .m_axil_wready(m_axil_wready),
    .m_axil_bresp(m_axil_bresp),
    .m_axil_bvalid(m_axil_bvalid),
    .m_axil_bready(m_axil_bready),
    .m_axil_araddr(m_axil_araddr),
    .m_axil_arprot(m_axil_arprot),
    .m_axil_arvalid(m_axil_arvalid),
    .m_axil_arready(m_axil_arready),
    .m_axil_rdata(m_axil_rdata),
    .m_axil_rresp(m_axil_rresp),
    .m_axil_rvalid(m_axil_rvalid),
    .m_axil_rready(m_axil_rready),
    .s_axis_read_desc_pcie_addr(s_axis_read_desc_pcie_addr),
    .s_axis_read_desc_ram_sel(s_axis_read_desc_ram_sel),
    .s_axis_read_desc_ram_addr(s_axis_read_desc_ram_addr),
    .s_axis_read_desc_len(s_axis_read_desc_len),
    .s_axis_read_desc_tag(s_axis_read_desc_tag),
    .s_axis_read_desc_valid(s_axis_read_desc_valid),
    .s_axis_read_desc_ready(s_axis_read_desc_ready),
    .m_axis_read_desc_status_tag(m_axis_read_desc_status_tag),
    .m_axis_read_desc_status_error(m_axis_read_desc_status_error),
    .m_axis_read_desc_status_valid(m_axis_read_desc_status_valid),
    .s_axis_write_desc_pcie_addr(s_axis_write_desc_pcie_addr),
    .s_axis_write_desc_ram_sel(s_axis_write_desc_ram_sel),
    .s_axis_write_desc_ram_addr(s_axis_write_desc_ram_addr),
    .s_axis_write_desc_imm(s_axis_write_desc_imm),
    .s_axis_write_desc_imm_en(s_axis_write_desc_imm_en),
    .s_axis_write_desc_len(s_axis_write_desc_len),
    .s_axis_write_desc_tag(s_axis_write_desc_tag),
    .s_axis_write_desc_valid(s_axis_write_desc_valid),
    .s_axis_write_desc_ready(s_axis_write_desc_ready),
    .m_axis_write_desc_status_tag(m_axis_write_desc_status_tag),
    .m_axis_write_desc_status_error(m_axis_write_desc_status_error),
    .m_axis_write_desc_status_valid(m_axis_write_desc_status_valid),
    .ram_rd_cmd_sel(ram_rd_cmd_sel),
    .ram_rd_cmd_addr(ram_rd_cmd_addr),
    .ram_rd_cmd_valid(ram_rd_cmd_valid),
    .ram_rd_cmd_ready(ram_rd_cmd_ready),
    .ram_rd_resp_data(ram_rd_resp_data),
    .ram_rd_resp_valid(ram_rd_resp_valid),
    .ram_rd_resp_ready(ram_rd_resp_ready),
    .ram_wr_cmd_sel(ram_wr_cmd_sel),
    .ram_wr_cmd_be(ram_wr_cmd_be),
    .ram_wr_cmd_addr(ram_wr_cmd_addr),
    .ram_wr_cmd_data(ram_wr_cmd_data),
    .ram_wr_cmd_valid(ram_wr_cmd_valid),
    .ram_wr_cmd_ready(ram_wr_cmd_ready),
    .ram_wr_done(ram_wr_done)
);
// These blocks exist in parallel with the DMA engine. I drive them from the
// simulation harness after checking the received RAM bytes. A board version
// still needs a memory sequencer to do that work without the testbench.
fir7 fir(.clk(clk),.rst(rst),.in_data(fir_in_data),.in_valid(fir_in_valid),
    .in_ready(fir_in_ready),.out_data(fir_out_data),.out_valid(fir_out_valid),
    .out_ready(fir_out_ready),.saturated(fir_saturated));
snapshot_guard snapshots(.clk(clk),.rst(rst),.start(snapshot_start),
    .in_data(snapshot_in_data),.in_valid(snapshot_in_valid),.in_last(snapshot_in_last),
    .in_ready(snapshot_in_ready),.done(snapshot_done),.accepted(snapshot_accepted),
    .sequence_value(snapshot_sequence),.entity_count(snapshot_entity_count));
project_point projector(.x(point_x),.y(point_y),.z(point_z),.matrix_data(point_matrix),
    .ndc_x(point_ndc_x),.ndc_y(point_ndc_y),.visible(point_visible));
endmodule
