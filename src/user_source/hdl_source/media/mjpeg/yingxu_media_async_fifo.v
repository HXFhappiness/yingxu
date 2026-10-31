`timescale 1ns/1ps
`default_nettype none
// Small distributed-RAM R/V FIFO. Common reset; Gray pointers cross via 2FF.
module yingxu_media_async_fifo #(parameter WIDTH=8,ABITS=6)(
    input wire wclk,rclk,rst,input wire wvalid,output wire wready,input wire [WIDTH-1:0] wdata,
    output wire rvalid,input wire rready,output wire [WIDTH-1:0] rdata,
    output wire [ABITS:0] wlevel
);
    (* ram_style="distributed" *) reg [WIDTH-1:0] memory[0:(1<<ABITS)-1];
    reg [ABITS:0] wp,rp,wg,rg;
    (* async_reg="true" *) reg [ABITS:0] wm,ws,rm,rs;
    wire [ABITS:0] wn=wp+1'b1,rn=rp+1'b1;
    wire full=wg=={~rs[ABITS:ABITS-1],rs[ABITS-2:0]};
    assign wready=!full;assign rvalid=rg!=ws;
    assign rdata=memory[rp[ABITS-1:0]];
    function [ABITS:0] binary(input [ABITS:0] g);
        integer i;begin binary[ABITS]=g[ABITS];for(i=ABITS-1;i>=0;i=i-1) binary[i]=binary[i+1]^g[i];end
    endfunction
    assign wlevel=wp-binary(rs);
    always @(posedge wclk) begin
        if(rst) begin wp<=0;wg<=0;rm<=0;rs<=0;end
        else begin rm<=rg;rs<=rm;
            if(wvalid && wready) begin memory[wp[ABITS-1:0]]<=wdata;wp<=wn;wg<=wn^(wn>>1);end
        end
    end
    always @(posedge rclk) begin
        if(rst) begin rp<=0;rg<=0;wm<=0;ws<=0;end
        else begin wm<=wg;ws<=wm;if(rvalid && rready) begin rp<=rn;rg<=rn^(rn>>1);end end
    end
endmodule
`default_nettype wire
