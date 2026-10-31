`timescale 1ns/1ps
`default_nettype none
// Strict priority only at transaction boundaries: 0 display, 1 decode write,
// 2 prefetch/other. Physical refresh is implemented above this service layer.
module yingxu_mjpeg_arbiter(
    input wire clk,rst,
    input wire [2:0] cvalid,output reg [2:0] cready,
    input wire [2:0] cwrite,input wire [62:0] caddr,input wire [11:0] cwords,
    input wire [2:0] cwvalid,output reg [2:0] cwready,input wire [95:0] cwdata,input wire [2:0] cwlast,
    output reg [2:0] crvalid,input wire [2:0] crready,output wire [31:0] crdata,output wire crlast,
    output reg [2:0] cdone,cerror,
    output wire mvalid,input wire mready,output wire mwrite,output wire [20:0] maddr,output wire [3:0] mwords,
    output wire mwvalid,input wire mwready,output wire [31:0] mwdata,output wire mwlast,
    input wire mrvalid,output wire mrready,input wire [31:0] mrdata,input wire mrlast,
    input wire mdone,merror
);
    reg active;reg [1:0] owner;
    reg held;reg [1:0] chosen;
    wire [1:0] priority_owner=cvalid[0] ? 2'd0:cvalid[1] ? 2'd1:2'd2;
    wire [1:0] select_owner=held ? chosen:priority_owner;
    assign mvalid=!active && (held || |cvalid);
    assign mwrite=cwrite[select_owner];
    assign maddr=caddr[select_owner*21+:21];
    assign mwords=cwords[select_owner*4+:4];
    assign mwvalid=active && cwvalid[owner];
    assign mwdata=cwdata[owner*32+:32];
    assign mwlast=cwlast[owner];
    assign mrready=active && crready[owner];
    assign crdata=mrdata;assign crlast=mrlast;
    always @* begin
        cready=0;cwready=0;crvalid=0;cdone=0;cerror=0;
        if(!active && mvalid) cready[select_owner]=mready;
        if(active) begin
            cwready[owner]=mwready;crvalid[owner]=mrvalid;
            cdone[owner]=mdone;cerror[owner]=merror;
        end
    end
    always @(posedge clk) begin
        if(rst) begin active<=0;owner<=0;held<=0;chosen<=0;end
        else begin
            // Hold selection as soon as a stalled physical command is exposed;
            // a later high-priority arrival cannot change valid payload.
            if(mvalid && !mready && !held) begin held<=1;chosen<=select_owner;end
            if(mvalid && mready) begin active<=1;owner<=select_owner;held<=0;end
            if(active && (mdone || merror)) active<=0;
        end
    end
endmodule
`default_nettype wire
