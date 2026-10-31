`timescale 1ns/1ps
`default_nettype none
// Two 512-byte MCU slots share one synchronous 1024x8 RAM.
module yingxu_jpeg_rgb(
    input wire clk,rst,
    input wire sample_valid,input wire sample_bank,input wire [2:0] sample_block,
    input wire [5:0] sample_index,input wire [7:0] sample_data,
    input wire mcu_done,input wire [5:0] mcu_x,input wire [4:0] mcu_y,
    output wire [1:0] bank_free,
    output wire pixel_valid,input wire pixel_ready,output wire [15:0] pixel,
    output wire [9:0] pixel_x,output wire [8:0] pixel_y
);
    reg [7:0] samples[0:1023];
    reg [7:0] q;
    reg [1:0] full;
    reg [5:0] bx[0:1];reg [4:0] by[0:1];
    reg bank;reg [7:0] pos;
    localparam IDLE=0,RY=1,RCB=2,RCR=3,MUL=4,OUT=5;
    reg [2:0] state;
    reg [7:0] y,cb;
    reg signed [31:0] pr,pg,pb;
    wire [8:0] wlocal=sample_block<4 ?
        {1'b0,sample_block[1],sample_index[5:3],sample_block[0],sample_index[2:0]} :
        (sample_block==4 ? 9'd256 : 9'd320)+{3'd0,sample_index};
    wire [8:0] clocal={3'd0,pos[7:5],pos[3:1]};
    wire [8:0] rlocal=state==RCB ? 9'd256+clocal :
        state==RCR ? 9'd320+clocal : {1'b0,pos};
    always @(posedge clk) begin
        q<=samples[{bank,rlocal}];
        if(sample_valid) samples[{sample_bank,wlocal}]<=sample_data;
    end
    function automatic [7:0] channel(input [7:0] luma,input signed [31:0] term);
        reg signed [32:0] v;
        begin v=$signed({1'b0,luma})+(($signed(term)+33'sd8192)>>>14);
            channel=v<0 ? 8'd0 : v>255 ? 8'd255 : v[7:0];
        end
    endfunction
    wire [7:0] r=channel(y,pr),g=channel(y,pg),b=channel(y,pb);
    assign pixel={r[7:3],g[7:2],b[7:3]};
    assign pixel_valid=(state==OUT);
    assign pixel_x={bx[bank],pos[3:0]};
    assign pixel_y={by[bank],pos[7:4]};
    assign bank_free=~full;
    always @(posedge clk) begin
        if(rst) begin full<=0;state<=IDLE;bank<=0;pos<=0;y<=0;cb<=0;pr<=0;pg<=0;pb<=0;end
        else begin
            if(mcu_done) begin full[sample_bank]<=1;bx[sample_bank]<=mcu_x;by[sample_bank]<=mcu_y;end
            case(state)
                IDLE: if(full!=0) begin bank<=full[0] ? 1'b0:1'b1;pos<=0;state<=RY;end
                RY: state<=RCB;
                RCB: begin y<=q;state<=RCR;end
                RCR: begin cb<=q;state<=MUL;end
                MUL: begin
                    pr<=32'sd22970*($signed({1'b0,q})-32'sd128);
                    pg<=-32'sd5638*($signed({1'b0,cb})-32'sd128)-32'sd11700*($signed({1'b0,q})-32'sd128);
                    pb<=32'sd29032*($signed({1'b0,cb})-32'sd128);
                    state<=OUT;
                end
                OUT: if(pixel_ready) begin
                    pos<=pos+1'b1;
                    if(pos==255) begin full[bank]<=0;state<=IDLE;end
                    else state<=RY;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
