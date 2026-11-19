// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
// This is the camera step in the game-scene example: one world position in,
// normalized screen X/Y and a clip-volume flag out. Positions and matrix
// coefficients use signed Q16.16; matrix element zero is in the low 32 bits.
// I use a combinational divide as a functional reference for now. A practical
// high-frequency board version still needs a pipeline or another divider.
// visible means inside the clip volume, not line of sight through the game.
module project_point (
    input wire signed [31:0] x,y,z,
    input wire [511:0] matrix_data,
    output reg signed [31:0] ndc_x,ndc_y,
    output reg visible
);
    reg signed [31:0] point[0:3];
    reg signed [67:0] clip[0:3];
    reg signed [83:0] scaled_x,scaled_y,quotient_x,quotient_y;
    integer row,column;
    always @* begin
        // The homogeneous coordinate is 1.0, stored as 65536. Multiplying
        // two Q16.16 values leaves 32 fractional bits in each clip sum.
        point[0]=x;point[1]=y;point[2]=z;point[3]=65536;
        for(row=0;row<4;row=row+1)begin
            clip[row]=0;
            for(column=0;column<4;column=column+1)
                clip[row]=clip[row]+$signed(matrix_data[(row*4+column)*32+:32])*$signed(point[column]);
        end
        ndc_x=0;ndc_y=0;visible=0;scaled_x=0;scaled_y=0;quotient_x=0;quotient_y=0;
        // I only divide by positive W. Shifting the numerator by 16 keeps
        // the normalized output in Q16.16 after division by clip W.
        if(clip[3]>0)begin
            scaled_x=clip[0];scaled_x=scaled_x<<<16;
            scaled_y=clip[1];scaled_y=scaled_y<<<16;
            quotient_x=scaled_x/clip[3];quotient_y=scaled_y/clip[3];
            // Keep the bounds explicitly wide and signed. An unsized
            // negative 32-bit limit produced different simulator behavior.
            if(quotient_x>=-84'sd2147483648&&quotient_x<=84'sd2147483647&&
               quotient_y>=-84'sd2147483648&&quotient_y<=84'sd2147483647)begin
                ndc_x=quotient_x[31:0];ndc_y=quotient_y[31:0];
                visible=clip[0]>=-clip[3]&&clip[0]<=clip[3]&&clip[1]>=-clip[3]&&
                        clip[1]<=clip[3]&&clip[2]>=-clip[3]&&clip[2]<=clip[3];
            end
        end
    end
endmodule
