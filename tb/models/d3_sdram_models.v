`timescale 1ns/1ps
// Functional PLL/FIFO models only. The self-authored controller/FSM is real.
module Sdram_PLL(input reset,refclk,output clk0_out,clk1_out);
    reg c=0;always #5 c=~c;assign clk0_out=c;assign clk1_out=~c;
endmodule
module Sdram_RD_FIFO(input rst,input [31:0] di,input clkw,we,clkr,re,
    output [31:0] \do ,output empty_flag,full_flag,afull_flag);
    reg [31:0] m[0:511];integer wp=0,rp=0;
    always @(posedge clkw or posedge rst) if(rst) wp<=0;else if(we) begin m[wp%512]<=di;wp<=wp+1;end
    always @(posedge clkr or posedge rst) if(rst) rp<=0;else if(re && rp!=wp) rp<=rp+1;
    assign \do =m[rp%512];assign empty_flag=wp==rp;assign full_flag=wp-rp>=512;assign afull_flag=wp-rp>=128;
endmodule
module Sdram_WR_FIFO(input rst,input [31:0] di,input clkw,we,clkr,re,
    output [31:0] \do ,output afull_flag,aempty_flag);
    reg [31:0] m[0:511];integer wp=0,rp=0;
    always @(posedge clkw or posedge rst) if(rst) wp<=0;else if(we) begin m[wp%512]<=di;wp<=wp+1;end
    always @(posedge clkr or posedge rst) if(rst) rp<=0;else if(re && rp!=wp) rp<=rp+1;
    assign \do =m[rp%512];assign aempty_flag=wp-rp<128;assign afull_flag=wp-rp>=384;
endmodule
// Service-level 8MB SDRAM model. Returns through the REAL mDATAOUT register.
// It does not replace controller arbitration, IN_REQ/OUT_VALID or done timing.
module d3_sdram_memory(input clk,read,write,oe,input [20:0] addr,
    input in_req,out_valid,input [3:0] mask,input [31:0] data,inout [31:0] dq);
    reg [31:0] memory[0:2097151];integer ri=0,wi=0,k;
    assign dq=(read && !oe) ? memory[addr+(out_valid ? ri+1:0)]:32'bz;
    always @(posedge clk) begin
        if(!out_valid) ri<=0;else ri<=ri+1;
        if(!in_req) wi<=0;
        else begin for(k=0;k<4;k=k+1) if(!mask[k]) memory[addr+wi][k*8+:8]<=data[k*8+:8];wi<=wi+1;end
    end
endmodule
