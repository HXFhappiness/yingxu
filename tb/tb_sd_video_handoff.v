`timescale 1ns/1ps
// Real probe + old two-cycle stream core; only card transaction service modeled.
module tb_sd_video_handoff;
    reg clk=0;always #10 clk=~clk;reg rst=1,start=0,inhibit=1,owned=0,ready=0;
    reg [27:0] lba=32672;reg [15:0] count=1;
    wire init,busy,done,valid;wire [7:0] data;
    integer commands=0,bytes=0,cycles=0;reg [31:0] magic=0;
    yingxu_sd_integration_probe #(.DYNAMIC_COUNT(1),.SECTOR_COUNT(2)) dut(
        .clk(clk),.rst(rst),.trigger_sw(1'b0),.restart(start),.legacy_inhibit(inhibit),
        .dynamic_enable(owned),.dynamic_count(count),.start_sector(lba),.out_stream_data(data),.out_stream_valid(valid),.out_stream_ready(ready),
        .sd_miso(1'b1),.dbg_init_done(init),.dbg_busy(busy),.transaction_done(done));
    always @(posedge clk)if(!rst)begin
        cycles=cycles+1;
        if(dut.reader_start)begin
            if(inhibit)$fatal(1,"start during handoff");commands=commands+1;
            if(owned && (lba!=3000000 || count!=1))$fatal(1,"wrong video command");
        end
        if(valid && ready && owned)begin
            if(bytes<4)magic={magic[23:0],data};bytes=bytes+1;
        end
    end
    task pulse;
        begin @(negedge clk);start=1;@(negedge clk);start=0;end
    endtask
    initial begin
        repeat(8)@(negedge clk);rst=0;
        // A queued request while inhibited must not prevent automatic init.
        pulse();wait(init);repeat(8)@(negedge clk);
        if(commands!=0 || dut.restart_hold)$fatal(1,"init/queued cancellation");
        inhibit=0;pulse();wait(valid); // legacy transaction deliberately stalled
        pulse();if(!dut.restart_hold)$fatal(1,"legacy request not queued");
        inhibit=1;ready=1;repeat(4)@(negedge clk);
        if(dut.restart_hold)$fatal(1,"queued request survived takeover");
        wait(!busy);repeat(4)@(negedge clk);
        if(commands!=1)$fatal(1,"legacy restarted before claim");
        owned=1;lba=3000000;count=1;inhibit=0;pulse();
        wait(done);@(negedge clk);
        if(commands!=2 || bytes!=512 || magic!=32'h59585631)$fatal(1,"new consumer inherited legacy bytes %h count=%0d",magic,bytes);
        $display("HANDOFFCHK: PASS auto-init without restart; queued legacy canceled; busy read drained; first video LBA=3000000 count=1 magic=59585631 bytes=512/512");$finish;
    end
    initial begin #10000000;$fatal(1,"handoff timeout");end
endmodule
