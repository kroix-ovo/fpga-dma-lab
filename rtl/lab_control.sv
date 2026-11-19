// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
// This is the transport side of a game frame: registered host buffers,
// queued descriptors, reference FPGA RAM and completion records. I keep the
// scene schema out of this controller so another application can reuse it.
module lab_control #
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
    input wire bus_master_enable,
    output reg halted,
    output reg engine_reset,
    output wire [PCIE_ADDR_WIDTH-1:0]                    s_axis_read_desc_pcie_addr,
    output wire [RAM_SEL_WIDTH-1:0]                      s_axis_read_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                     s_axis_read_desc_ram_addr,
    output wire [LEN_WIDTH-1:0]                          s_axis_read_desc_len,
    output wire [TAG_WIDTH-1:0]                          s_axis_read_desc_tag,
    output wire s_axis_read_desc_valid,
    input wire s_axis_read_desc_ready,
    input wire [TAG_WIDTH-1:0]                          m_axis_read_desc_status_tag,
    input wire [3:0]                                    m_axis_read_desc_status_error,
    input wire m_axis_read_desc_status_valid,
    output wire [PCIE_ADDR_WIDTH-1:0]                    s_axis_write_desc_pcie_addr,
    output wire [RAM_SEL_WIDTH-1:0]                      s_axis_write_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                     s_axis_write_desc_ram_addr,
    output wire [IMM_WIDTH-1:0]                          s_axis_write_desc_imm,
    output wire s_axis_write_desc_imm_en,
    output wire [LEN_WIDTH-1:0]                          s_axis_write_desc_len,
    output wire [TAG_WIDTH-1:0]                          s_axis_write_desc_tag,
    output wire s_axis_write_desc_valid,
    input wire s_axis_write_desc_ready,
    input wire [TAG_WIDTH-1:0]                          m_axis_write_desc_status_tag,
    input wire [3:0]                                    m_axis_write_desc_status_error,
    input wire m_axis_write_desc_status_valid,
    input wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]        ram_rd_cmd_sel,
    input wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]   ram_rd_cmd_addr,
    input wire [RAM_SEG_COUNT-1:0]                      ram_rd_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                      ram_rd_cmd_ready,
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]   ram_rd_resp_data,
    output wire [RAM_SEG_COUNT-1:0]                      ram_rd_resp_valid,
    input wire [RAM_SEG_COUNT-1:0]                      ram_rd_resp_ready,
    input wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]        ram_wr_cmd_sel,
    input wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]     ram_wr_cmd_be,
    input wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]   ram_wr_cmd_addr,
    input wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]   ram_wr_cmd_data,
    input wire [RAM_SEG_COUNT-1:0]                      ram_wr_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                      ram_wr_cmd_ready,
    output wire [RAM_SEG_COUNT-1:0]                      ram_wr_done,
    input wire [17-1:0]              m_axil_awaddr,
    input wire [2:0]                              m_axil_awprot,
    input wire m_axil_awvalid,
    output reg m_axil_awready,
    input wire [32-1:0]              m_axil_wdata,
    input wire [4-1:0]              m_axil_wstrb,
    input wire m_axil_wvalid,
    output reg m_axil_wready,
    output reg [1:0]                              m_axil_bresp,
    output reg m_axil_bvalid,
    input wire m_axil_bready,
    input wire [17-1:0]              m_axil_araddr,
    input wire [2:0]                              m_axil_arprot,
    input wire m_axil_arvalid,
    output reg m_axil_arready,
    output reg [32-1:0]              m_axil_rdata,
    output reg [1:0]                              m_axil_rresp,
    output reg m_axil_rvalid,
    input wire m_axil_rready
);
// I generate the register/status constants from spec/interface.json.
// One descriptor executes at a time. The read engine can still issue four
// TLPs for that descriptor; that isn't four game frames running in parallel.
localparam IDLE=0, READ_SEND=1, READ_WAIT=2, WRITE_SEND=3,
           WRITE_WAIT=4, FENCE_SEND=5, FENCE_WAIT=6, FINISH=7;
`include "interface.svh"
reg enabled;
reg [3:0] state;
reg [63:0] region_base[0:15], region_size[0:15];
reg [31:0] region_gen[0:15], region_perm[0:15];
reg [31:0] stage_slot, stage_gen, stage_fpga, stage_length, stage_id;
reg [63:0] stage_offset;
reg [63:0] queue_addr[0:31];
reg [15:0] queue_ram[0:31];
reg [19:0] queue_length[0:31];
reg [31:0] queue_id[0:31], queue_error[0:31];
reg [4:0] read_head, read_tail, write_head, write_tail;
reg prefer_write;
wire [4:0] read_count=read_tail-read_head;
wire [4:0] write_count=write_tail-write_head;
reg [31:0] completion_id[0:15], completion_error[0:15], completion_length[0:15], completion_epoch[0:15];
reg [4:0] completion_head, completion_tail;
wire [4:0] completion_count=completion_tail-completion_head;
reg [63:0] active_address, fence_address;
reg [15:0] active_ram;
reg [19:0] active_length;
reg [31:0] active_id, active_error, epoch, submit_status, cancel_status;
reg [31:0] timeout_limit, elapsed, completed_count;
reg [7:0] active_tag;
reg [16:0] awaddr;
reg [31:0] wdata;
reg [3:0] wstrb;
reg awheld,wheld;
integer i,j,k,slot,qindex;
reg [31:0] validation;
reg [64:0] range_end;
reg found_cancel;
// This byte array is the functional reference RAM. A board port needs
// banked memory and arbitration; I don't assume this infers useful BRAM.
reg [7:0] memory[0:65535];
reg [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] ram_response;
reg [RAM_SEG_COUNT-1:0] ram_response_valid;

initial begin
    for (integer n=0;n<65536;n=n+1) memory[n]=0;
end

assign s_axis_read_desc_pcie_addr = state==FENCE_SEND ? fence_address : active_address;
assign s_axis_read_desc_ram_sel = 0;
assign s_axis_read_desc_ram_addr = state==FENCE_SEND ? 16'hfff0 : active_ram;
assign s_axis_read_desc_len = state==FENCE_SEND ? 20'd4 : active_length;
assign s_axis_read_desc_tag = active_tag;
assign s_axis_read_desc_valid = state==READ_SEND || state==FENCE_SEND;
assign s_axis_write_desc_pcie_addr = active_address;
assign s_axis_write_desc_ram_sel = 0;
assign s_axis_write_desc_ram_addr = active_ram;
assign s_axis_write_desc_len = active_length;
assign s_axis_write_desc_tag = active_tag;
assign s_axis_write_desc_imm = 0;
assign s_axis_write_desc_imm_en = 0;
assign s_axis_write_desc_valid = state==WRITE_SEND;
assign ram_wr_cmd_ready = {RAM_SEG_COUNT{1'b1}};
assign ram_rd_cmd_ready = ~ram_response_valid | ram_rd_resp_ready;
assign ram_rd_resp_data = ram_response;
assign ram_rd_resp_valid = ram_response_valid;
reg [RAM_SEG_COUNT-1:0] ram_done;
assign ram_wr_done=ram_done;

always @(posedge clk) begin
    ram_done<=ram_wr_cmd_valid;
    for (integer segment=0;segment<RAM_SEG_COUNT;segment=segment+1) begin
        if (ram_rd_cmd_ready[segment]) begin
            ram_response_valid[segment]<=ram_rd_cmd_valid[segment];
            if (ram_rd_cmd_valid[segment])
                for (integer lane=0;lane<RAM_SEG_BE_WIDTH;lane=lane+1)
                    ram_response[segment*RAM_SEG_DATA_WIDTH+lane*8+:8]<=memory[
                        ram_rd_cmd_addr[segment*RAM_SEG_ADDR_WIDTH+:RAM_SEG_ADDR_WIDTH]*16+segment*8+lane];
        end
        if (ram_wr_cmd_valid[segment])
            for (integer lane=0;lane<RAM_SEG_BE_WIDTH;lane=lane+1)
                if (ram_wr_cmd_be[segment*RAM_SEG_BE_WIDTH+lane])
                    memory[ram_wr_cmd_addr[segment*RAM_SEG_ADDR_WIDTH+:RAM_SEG_ADDR_WIDTH]*16+segment*8+lane]
                        <=ram_wr_cmd_data[segment*RAM_SEG_DATA_WIDTH+lane*8+:8];
    end
    if(rst) begin
        ram_response_valid<=0;ram_done<=0;
    end
end

// AXI-Lite can deliver the address and write data on different clocks.
// I hold each independently so a host register write stays one operation.
always @* begin
    m_axil_awready=!awheld&&!m_axil_bvalid;
    m_axil_wready=!wheld&&!m_axil_bvalid;
    m_axil_arready=!m_axil_rvalid;
end

always @(posedge clk) begin
    engine_reset<=0;
    if(m_axil_bvalid&&m_axil_bready) m_axil_bvalid<=0;
    if(m_axil_rvalid&&m_axil_rready) m_axil_rvalid<=0;
    if(m_axil_awready&&m_axil_awvalid)begin awaddr<=m_axil_awaddr;awheld<=1;end
    if(m_axil_wready&&m_axil_wvalid)begin wdata<=m_axil_wdata;wstrb<=m_axil_wstrb;wheld<=1;end
    if(awheld&&wheld&&!m_axil_bvalid)begin
        awheld<=0;wheld<=0;m_axil_bvalid<=1;m_axil_bresp<=0;
        if(awaddr[16])begin
            if(state!=IDLE||read_count!=0||write_count!=0) m_axil_bresp<=2;
            else for(integer lane=0;lane<4;lane=lane+1)
                if(wstrb[lane]) memory[{awaddr[15:2],2'b00}+lane]<=wdata[lane*8+:8];
        end else if(wstrb!=4'hf) m_axil_bresp<=2;
        else if(awaddr>=17'h100&&awaddr<17'h300)begin
            slot=(awaddr-17'h100)>>5;
            // I won't replace a mapping while an old descriptor can still use it.
            // The host must drain both queues and the active request first.
            if(state!=IDLE||read_count!=0||write_count!=0) m_axil_bresp<=2;
            else case(awaddr[4:0])
                0:region_base[slot][31:0]<=wdata;
                4:region_base[slot][63:32]<=wdata;
                8:region_size[slot][31:0]<=wdata;
                12:region_size[slot][63:32]<=wdata;
                16:region_gen[slot]<=wdata;
                20:region_perm[slot]<=wdata;
                default:m_axil_bresp<=2;
            endcase
        end else case(awaddr)
            R_CONTROL:begin
                if(wdata[1])begin
                    // A normal reset is only safe with no DMA in flight.
                    // I keep a timed-out endpoint halted: clearing a queue
                    // can't recall an old PCIe request or make its mapping safe.
                    if(state==IDLE&&read_count==0&&write_count==0&&!halted)begin
                        enabled<=0;epoch<=epoch+1;completion_head<=0;completion_tail<=0;
                        for(i=0;i<16;i=i+1)region_perm[i]<=0;
                        engine_reset<=1;
                    end else m_axil_bresp<=2;
                end else if(!halted) enabled<=wdata[0];
            end
            R_FENCE_LO,R_FENCE_HI:begin
                if(state==IDLE&&read_count==0&&write_count==0)begin
                    if(awaddr==R_FENCE_LO)fence_address[31:0]<=wdata;
                    else fence_address[63:32]<=wdata;
                end else m_axil_bresp<=2;
            end
            R_TIMEOUT_CYCLES:timeout_limit<=wdata;
            R_STAGE_SLOT:stage_slot<=wdata;
            R_STAGE_GENERATION:stage_gen<=wdata;
            R_STAGE_OFFSET_LO:stage_offset[31:0]<=wdata;
            R_STAGE_OFFSET_HI:stage_offset[63:32]<=wdata;
            R_STAGE_FPGA_OFFSET:stage_fpga<=wdata;
            R_STAGE_LENGTH:stage_length<=wdata;
            R_STAGE_REQUEST_ID:stage_id<=wdata;
            R_SUBMIT:begin
                submit_status<=OK;
                if((!wdata[0]&&read_count==16)||(wdata[0]&&write_count==16)) submit_status<=QUEUE_FULL;
                else begin
                    // Check the complete span before giving an address to
                    // the DMA engine. A bad frame descriptor still gets an
                    // error completion, but it must not issue a memory request.
                    validation=OK;
                    if(!enabled||!bus_master_enable||halted)validation=DISABLED;
                    else if(stage_slot>=16)validation=BAD_REGION;
                    else if(region_perm[stage_slot]==0||region_gen[stage_slot]!=stage_gen)validation=BAD_REGION;
                    else if((region_perm[stage_slot]&(wdata[0]?2:1))==0)validation=PERMISSION;
                    else begin
                        range_end={1'b0,stage_offset}+{33'd0,stage_length};
                        if(range_end[64]||range_end>{1'b0,region_size[stage_slot]}||
                           {1'b0,region_base[stage_slot]}+range_end>65'h0ffffffffffffffff||
                           stage_fpga>65520||stage_length>65520-stage_fpga)validation=BOUNDS;
                    end
                    qindex=wdata[0]?16+write_tail[3:0]:read_tail[3:0];
                    queue_addr[qindex]<=stage_slot<16?region_base[stage_slot]+stage_offset:0;
                    queue_ram[qindex]<=stage_fpga[15:0];queue_length[qindex]<=stage_length[19:0];
                    queue_id[qindex]<=stage_id;queue_error[qindex]<=validation;
                    if(wdata[0])write_tail<=write_tail+1;else read_tail<=read_tail+1;
                end
            end
            R_CANCEL_ID:begin
                found_cancel=0;cancel_status<=2;
                for(i=0;i<16;i=i+1)begin
                    if(i<read_count)begin
                        qindex=(read_head[3:0]+i)&15;
                        if(queue_id[qindex]==wdata)begin queue_error[qindex]<=CANCELLED;found_cancel=1;end
                    end
                    if(i<write_count)begin
                        qindex=16+((write_head[3:0]+i)&15);
                        if(queue_id[qindex]==wdata)begin queue_error[qindex]<=CANCELLED;found_cancel=1;end
                    end
                end
                if(found_cancel)cancel_status<=0;
                if(state!=IDLE&&active_id==wdata)cancel_status<=1;
            end
            R_COMPLETION_POP:if(completion_count!=0)completion_head<=completion_head+1;
            default:m_axil_bresp<=2;
        endcase
    end
    if(m_axil_arvalid&&m_axil_arready)begin
        m_axil_rvalid<=1;m_axil_rdata<=0;m_axil_rresp<=0;
        if(m_axil_araddr[16])begin
            if(state!=IDLE||read_count!=0||write_count!=0)m_axil_rresp<=2;
            else for(integer lane=0;lane<4;lane=lane+1)
                m_axil_rdata[lane*8+:8]<=memory[{m_axil_araddr[15:2],2'b00}+lane];
        end else case(m_axil_araddr)
            R_SIGNATURE:m_axil_rdata<=32'h444d414c;
            R_CONTROL:m_axil_rdata<={31'd0,enabled};
            R_DEVICE_STATUS:m_axil_rdata<={29'd0,halted,state!=IDLE,bus_master_enable};
            R_COMPLETION_COUNT:m_axil_rdata<={27'd0,completion_count};
            R_QUEUE_COUNTS:m_axil_rdata<={11'd0,write_count,11'd0,read_count};
            R_TIMEOUT_CYCLES:m_axil_rdata<=timeout_limit;
            R_FPGA_CAPACITY:m_axil_rdata<=65520;
            R_EPOCH:m_axil_rdata<=epoch;
            R_ABI_VERSION:m_axil_rdata<=32'h00010000;
            R_SUBMIT_STATUS:m_axil_rdata<=submit_status;
            R_CANCEL_STATUS:m_axil_rdata<=cancel_status;
            R_COMPLETION_ID:m_axil_rdata<=(completion_count!=0)?completion_id[completion_head[3:0]]:0;
            R_COMPLETION_STATUS:m_axil_rdata<=(completion_count!=0)?completion_error[completion_head[3:0]]:0;
            R_COMPLETION_BYTES:m_axil_rdata<=(completion_count!=0)?completion_length[completion_head[3:0]]:0;
            R_COMPLETION_EPOCH:m_axil_rdata<=(completion_count!=0)?completion_epoch[completion_head[3:0]]:0;
            R_COMPLETED_TOTAL:m_axil_rdata<=completed_count;
            default:m_axil_rresp<=2;
        endcase
    end
    case(state)
        IDLE:if(completion_count<16&&(read_count!=0||write_count!=0))begin
            if(write_count!=0&&(prefer_write||read_count==0))begin
                qindex=16+write_head[3:0];write_head<=write_head+1;prefer_write<=0;
            end else begin qindex=read_head[3:0];read_head<=read_head+1;prefer_write<=1;end
            active_address<=queue_addr[qindex];active_ram<=queue_ram[qindex];
            active_length<=queue_length[qindex];active_id<=queue_id[qindex];
            active_error<=queue_error[qindex];active_tag<=active_tag+1;elapsed<=0;
            if(awheld&&wheld&&!m_axil_bvalid&&awaddr==R_CANCEL_ID&&wstrb==15&&queue_id[qindex]==wdata)begin
                active_error<=CANCELLED;state<=FINISH;
            end else if(queue_error[qindex]!=OK||queue_length[qindex]==0||halted)begin
                if(halted)active_error<=DISABLED;
                state<=FINISH;
            end else state<=qindex>=16?WRITE_SEND:READ_SEND;
        end
        READ_SEND:if(s_axis_read_desc_ready)state<=READ_WAIT;
        READ_WAIT:if(m_axis_read_desc_status_valid)begin
            active_error<=m_axis_read_desc_status_error==0?OK:DMA_ERROR;state<=FINISH;
        end
        WRITE_SEND:if(s_axis_write_desc_ready)state<=WRITE_WAIT;
        WRITE_WAIT:if(m_axis_write_desc_status_valid)begin
            if(m_axis_write_desc_status_error!=0)begin active_error<=DMA_ERROR;state<=FINISH;end
            else state<=FENCE_SEND;
        end
        // The write engine finishing doesn't mean a posted write has reached
        // host memory. I follow it with a read of a private fence word. That
        // orders writes in this model; it can't detect every dropped write.
        FENCE_SEND:if(s_axis_read_desc_ready)state<=FENCE_WAIT;
        FENCE_WAIT:if(m_axis_read_desc_status_valid)begin
            active_error<=m_axis_read_desc_status_error==0?OK:DMA_ERROR;state<=FINISH;
        end
        FINISH:begin
            completion_id[completion_tail[3:0]]<=active_id;
            completion_error[completion_tail[3:0]]<=active_error;
            completion_length[completion_tail[3:0]]<=active_error==OK?active_length:0;
            completion_epoch[completion_tail[3:0]]<=epoch;
            completion_tail<=completion_tail+1;completed_count<=completed_count+1;state<=IDLE;
        end
    endcase
    // I give the watchdog priority over a normal state transition above.
    // On timeout, mappings must stay alive until endpoint/link teardown.
    if(state!=IDLE&&state!=FINISH)begin
        elapsed<=elapsed+1;
        if(timeout_limit!=0&&elapsed>=timeout_limit)begin
            active_error<=TIMEOUT;state<=FINISH;halted<=1;engine_reset<=1;enabled<=0;
        end
    end
    if(rst)begin
        fence_address<=0;
        state<=IDLE;enabled<=0;halted<=0;engine_reset<=0;
        awheld<=0;wheld<=0;m_axil_bvalid<=0;m_axil_rvalid<=0;m_axil_bresp<=0;m_axil_rresp<=0;
        read_head<=0;read_tail<=0;write_head<=0;write_tail<=0;
        completion_head<=0;completion_tail<=0;prefer_write<=0;
        active_tag<=0;epoch<=0;submit_status<=0;cancel_status<=2;elapsed<=0;timeout_limit<=100000;
        completed_count<=0;stage_slot<=0;stage_gen<=0;stage_offset<=0;stage_fpga<=0;stage_length<=0;stage_id<=0;
        for(i=0;i<16;i=i+1)begin region_perm[i]<=0;region_gen[i]<=0;region_base[i]<=0;region_size[i]<=0;end
    end
end

endmodule
