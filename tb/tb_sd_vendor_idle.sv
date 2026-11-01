`timescale 1ns/1ps
// Actual vendor controller, deliberately no SD response (MISO=1).
// Prove idle DIV/select interpretation, not a successful card read.
module tb_sd_vendor_idle;
    reg clk=0;always #10 clk=~clk;reg rst=1,start=0;
    wire [2:0] state;wire [1:0] sel;wire [5:0] div;
    sd_card_control #(.clock_freq(50000000),.spi_lowfreq(400000),.spi_highfreq(12500000)) dut(
        .clk(clk),.rst(rst),.start(start),.mode(2'd2),.miso(1'b1),.sector_addr(28'd3000001),
        .rd_ram_addr(9'd0),.wr_ram_din(8'd0),.wr_ram_addr(9'd0),.wr_ram_wea(1'b0),
        .dbg_ctrl_state(state),.dbg_select_num(sel),.dbg_spi_div_value(div));
    integer i;
    initial begin
        repeat(8)@(negedge clk);rst=0;repeat(8)@(negedge clk);
        if(state!=4 || sel!=0 || div!=62 || dut.init_start)$fatal(1,"idle interpretation");
        $display("VENDOR_IDLECHK: PASS actual controller CTRL=4 SEL=0 DIV=3E init_start=0; low divider is not initialization evidence");
        start=1;@(negedge clk);start=0;
        for(i=0;i<4096;i=i+1)begin @(negedge clk);if(dut.init_start)$fatal(1,"read became init");end
        if(state!=3 || sel!=2 || div!=2)$fatal(1,"mode2 selection");
        $display("VENDOR_SELECTCHK: PASS mode=2 stays read CTRL=3 SEL=2 DIV=02 with absent card response, init_start=0");$finish;
    end
endmodule
