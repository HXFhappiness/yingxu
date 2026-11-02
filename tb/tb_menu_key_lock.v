`timescale 1ns/1ps
`default_nettype none
// The DUT is the exact production key FSM, extracted by menu_keys_verify.py.
module tb_menu_key_lock;
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0,key0=1,key1=1,ret=0;
    wire[23:0]lock;wire[2:0]sel;wire[3:0]image;wire ui;
    integer i;
    menu_key_fsm dut(.clk(clk),.rst_n(rst_n),.key_0(key0),.key_1(key1),.menu_return(ret),
        .game_mode(1'b0),.video_requested(1'b0),.video_owned(1'b0),.sd_dbg_busy(1'b0),.sw_eff(8'hff),
        .key_lock(lock),.menu_sel(sel),.img_idx(image),.menu_ui(ui));
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        @(negedge clk);key1=0;@(negedge clk);
        if(lock!==5000000 || sel!=1)$fatal(1,"initial 100ms lock/selection");
        for(i=1;i<5000000;i=i+1)begin
            @(negedge clk);
            if(lock!==5000000-i || sel!=1)$fatal(1,"lock terminal cycle=%0d lock=%0d sel=%0d",i,lock,sel);
            if(i==1)key1=1;
            if(i==100)key1=0; // early press must not repeat, including after expiry
        end
        @(negedge clk);if(lock!=0 || sel!=1)$fatal(1,"100ms expiry");
        repeat(3)@(negedge clk);if(sel!=1)$fatal(1,"held key repeated");
        key1=1;@(negedge clk);key1=0;@(negedge clk);
        if(sel!=2 || lock!=5000000)$fatal(1,"next press after 100ms ignored");
        // The exit key is consumed by return; holding it beyond the full lock
        // cannot turn the returned menu into the photo browser.
        key0=0;ret=1;@(negedge clk);ret=0;
        if(!ui || image!=0 || lock!=5000000)$fatal(1,"return state/lock");
        repeat(5000003)@(negedge clk);
        if(!ui || image!=0 || lock!=0)$fatal(1,"held return key reconfirmed");
        $display("MENU_KEY_LOCK PASS exact 5000000 cycles (100ms), early-edge rejection, no held-key repeat/reconfirm, next press accepted");
        $finish;
    end
    initial begin #210000000;$fatal(1,"key lock timeout");end
endmodule
`default_nettype wire
