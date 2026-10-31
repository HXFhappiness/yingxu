`timescale 1ns/1ps
`default_nettype none
// Pixel-domain centered 640x480 replay. Swap/flush only after the window ends.
module yingxu_yxv_scanout(
    input wire clk,rst,input wire [10:0] x,input wire [9:0] y,input wire active,
    input wire frame_valid,output wire frame_ready,input wire frame_bank,input wire [31:0] frame_tag,
    output reg frame_done,output reg [31:0] displayed_tag,output reg displayed_valid,
    input wire [31:0] rd_data,input wire rd_empty,
    output reg rd_en,rd_load,output wire [20:0] rd_addr,rd_max,output wire [8:0] rd_len,
    output reg [23:0] rgb,output reg underflow
);
    reg bank,loading,primed,ack_pending;reg [7:0] load_count;
    reg [31:0] pair;
    wire window=active && x>=320 && x<960 && y>=120 && y<600;
    wire blank=(x==0 && y==600);
    wire [15:0] pixel=x[0] ? pair[15:0]:pair[31:16];
    assign frame_ready=blank && !loading;
    assign rd_addr=bank ? 21'h040000:21'h000000;
    assign rd_max=rd_addr+21'd153600;assign rd_len=128;
    always @(posedge clk) begin
        if(rst) begin bank<=0;loading<=0;primed<=0;ack_pending<=0;load_count<=0;pair<=0;
            rd_en<=0;rd_load<=0;rgb<=0;frame_done<=0;displayed_tag<=0;displayed_valid<=0;underflow<=0;end
        else begin
            rd_en<=0;frame_done<=0;
            if(frame_valid && frame_ready) begin
                bank<=frame_bank;displayed_tag<=frame_tag;displayed_valid<=1;
                loading<=1;load_count<=0;rd_load<=1;primed<=0;ack_pending<=1;
            end else if(blank && displayed_valid) begin
                loading<=1;load_count<=0;rd_load<=1;primed<=0;
            end else if(loading) begin
                load_count<=load_count+1'b1;
                if(load_count==255) begin loading<=0;rd_load<=0;end
            end else if(displayed_valid && !primed) begin
                if(!rd_empty) begin
                    pair<=rd_data;rd_en<=1;primed<=1;
                    if(ack_pending) begin frame_done<=1;ack_pending<=0;end
                end
            end else if(window && x[0] && primed && displayed_valid) begin
                rd_en<=1;
                if(!rd_empty) pair<=rd_data;else underflow<=1;
            end
            if(window && primed && displayed_valid)
                rgb<={pixel[15:11],pixel[15:13],pixel[10:5],pixel[10:9],pixel[4:0],pixel[4:2]};
            else rgb<=0;
        end
    end
endmodule
`default_nettype wire
