`timescale 1ns/1ps
// Run the exact extracted production DIP process for the full 0.5 seconds.
module tb_menu_boot_filter;
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0,override_en=1;reg[7:0]sw=8'hff;
    wire changed,valid;wire[7:0]baseline;integer i,events=0;
    menu_dip_filter dut(.clk(clk),.rst_n(rst_n),.menu_override(override_en),
        .sw(sw),.menu_real_change(changed),.sw_real_q(baseline),.sw_real_valid(valid));
    always @(negedge clk)if(changed)events=events+1;
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        for(i=0;i<25000000;i=i+1)begin
            @(negedge clk);
            if(valid || changed)$fatal(1,"D6 startup escape at cycle %0d",i);
            if(i==5000000)sw=8'h6f;
            if(i==15000000)sw=8'h7f;
        end
        if(dut.sw_boot_cnt!=25000000)$fatal(1,"boot count terminal");
        repeat(1000016)@(negedge clk);
        if(!valid || baseline!=8'h7f || events)$fatal(1,"initial DIP baseline event");
        sw=8'hff;repeat(999998)@(negedge clk);
        if(events)$fatal(1,"post-boot move too early");
        repeat(32)@(negedge clk);
        if(events!=1 || baseline!=8'hff)$fatal(1,"post-boot deliberate move missing");
        $display("D6_FULL_BOOT PASS 25000000 real cycles inhibited; long startup presets ignored; 20ms baseline/move; one event");
        $finish;
    end
    initial begin #550000000;$fatal(1,"boot filter timeout");end
endmodule
