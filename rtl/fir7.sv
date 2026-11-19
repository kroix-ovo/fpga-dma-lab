// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
// I keep this as a second application of the DMA path, separate from the
// game scene. It filters signed-16 I/Q with [1,2,3,4,3,2,1]/16 coefficients.
// History only advances when an input is accepted. If the output stalls,
// its data and valid bit stay put until the next stage can take them.
module fir7 (
    input wire clk, rst,
    input wire [31:0] in_data,
    input wire in_valid,
    output wire in_ready,
    output reg [31:0] out_data,
    output reg out_valid,
    input wire out_ready,
    output reg saturated
);
    reg signed [15:0] history_i[0:5], history_q[0:5];
    reg signed [31:0] sum_i,sum_q,rounded_i,rounded_q;
    integer index;
    // I can accept a sample when the output slot is empty or when its old
    // sample leaves on this edge. Both cases make room for the next result.
    assign in_ready=!out_valid||out_ready;
    always @* begin
        sum_i=$signed(in_data[15:0])+2*$signed(history_i[0])+3*$signed(history_i[1])+
              4*$signed(history_i[2])+3*$signed(history_i[3])+2*$signed(history_i[4])+$signed(history_i[5]);
        sum_q=$signed(in_data[31:16])+2*$signed(history_q[0])+3*$signed(history_q[1])+
              4*$signed(history_q[2])+3*$signed(history_q[3])+2*$signed(history_q[4])+$signed(history_q[5]);
        // Round half away from zero before narrowing. These positive,
        // unity-gain coefficients keep signed-16 inputs inside the clamp.
        rounded_i=sum_i>=0?(sum_i+8)>>>4:-((-sum_i+8)>>>4);
        rounded_q=sum_q>=0?(sum_q+8)>>>4:-((-sum_q+8)>>>4);
    end
    always @(posedge clk) begin
        saturated<=0;
        if(in_ready)begin
            out_valid<=in_valid;
            if(in_valid)begin
                for(index=5;index>0;index=index-1)begin
                    history_i[index]<=history_i[index-1];
                    history_q[index]<=history_q[index-1];
                end
                history_i[0]<=in_data[15:0];history_q[0]<=in_data[31:16];
                out_data[15:0]<=rounded_i>32767?16'h7fff:rounded_i< -32768?16'h8000:rounded_i[15:0];
                out_data[31:16]<=rounded_q>32767?16'h7fff:rounded_q< -32768?16'h8000:rounded_q[15:0];
                saturated<=rounded_i>32767||rounded_i< -32768||rounded_q>32767||rounded_q< -32768;
            end
        end
        if(rst)begin
            out_valid<=0;out_data<=0;saturated<=0;
            for(index=0;index<6;index=index+1)begin history_i[index]<=0;history_q[index]<=0;end
        end
    end
endmodule
