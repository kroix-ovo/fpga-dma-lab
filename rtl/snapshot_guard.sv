// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
// I check a complete game snapshot before the caller uses its entity data.
// Words are little-endian, with CRC32/ISO-HDLC and at most 128 entities.
// This block validates the stream; it doesn't store or project the entities.
// The caller must retain the frame and only consume it after accepted is set.
module snapshot_guard (
    input wire clk,rst,start,
    input wire [31:0] in_data,
    input wire in_valid,in_last,
    output reg in_ready,
    output reg done,accepted,
    output reg [31:0] sequence_value,entity_count
);
    reg [31:0] crc,last_sequence,word_index;
    reg bad,last_sequence_valid;
    // Four bytes arrive per accepted word. This loop is combinational CRC
    // logic inside that clock's update, not four extra receive clocks.
    function automatic [31:0] crc_word(input [31:0] previous,input [31:0] data);
        reg [31:0] value;
        integer byte_index,bit_index;
        begin
            value=previous;
            for(byte_index=0;byte_index<4;byte_index=byte_index+1)begin
                value=value^((data>>(byte_index*8))&255);
                for(bit_index=0;bit_index<8;bit_index=bit_index+1)
                    value=value[0]?(value>>1)^32'hedb88320:value>>1;
            end
            crc_word=value;
        end
    endfunction
    always @(posedge clk)begin
        // done is a pulse. accepted keeps the result until start or reset;
        // I don't treat old data on the ports as a newly validated frame.
        done<=0;
        if(in_valid&&in_ready)begin
            if(word_index==0&&in_data!=32'h4c414d44)bad<=1;
            if(word_index==1&&in_data!=32'h31304241)bad<=1;
            if(word_index==2&&in_data!=1)bad<=1;
            // A publisher finishes a stable frame with an even sequence.
            // I advance last_sequence only after every other check passes.
            if(word_index==3)begin
                sequence_value<=in_data;
                if(in_data[0]||(last_sequence_valid&&in_data<=last_sequence))bad<=1;
            end
            if(word_index==22)begin entity_count<=in_data;if(in_data>128)bad<=1;end
            // Header: 23 words. Each entity: five words. The repeated
            // sequence follows the entities, then the final CRC word.
            if(word_index==23+5*entity_count&&in_data!=sequence_value)bad<=1;
            if(in_last)begin
                in_ready<=0;done<=1;
                accepted<=!bad&&word_index==24+5*entity_count&&in_data==(crc^32'hffffffff);
                if(!bad&&word_index==24+5*entity_count&&in_data==(crc^32'hffffffff))begin
                    last_sequence<=sequence_value;last_sequence_valid<=1;
                end
            end else begin crc<=crc_word(crc,in_data);word_index<=word_index+1;end
        end
        // Starting another frame clears its local CRC/error state but keeps
        // the last accepted sequence, so replaying an old frame still fails.
        if(start)begin in_ready<=1;accepted<=0;bad<=0;word_index<=0;crc<=32'hffffffff;sequence_value<=0;entity_count<=0;end
        if(rst)begin in_ready<=0;done<=0;accepted<=0;last_sequence_valid<=0;last_sequence<=0;bad<=0;word_index<=0;entity_count<=0;sequence_value<=0;crc<=32'hffffffff;end
    end
endmodule
