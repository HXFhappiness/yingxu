`timescale 1ns/1ps
module tb_sd_restart_semantics;
    reg clk=0;always #10 clk=~clk;reg rst=1,restart=0,owned=0;
    reg [27:0] lba=1000;reg [15:0] sectors=1;wire init_done,busy,done,dne,valid;
    wire [7:0] data;wire [31:0] offset;wire [27:0] sector;wire [8:0] byte_addr;
    integer cycle=0,accepted=0,transactions=0,dne_clears=0,previous=0,per_request=0,j;
    wire ready=cycle%17!=5 && cycle%17!=6;
    yingxu_sd_integration_probe #(.DYNAMIC_COUNT(1),.SECTOR_COUNT(1)) dut(
        .clk(clk),.rst(rst),.trigger_sw(1'b0),.restart(restart),.legacy_inhibit(1'b0),
        .dynamic_enable(owned),.dynamic_count(sectors),.start_sector(lba),
        .out_stream_data(data),.out_stream_valid(valid),.out_stream_ready(ready),
        .sd_miso(1'b1),.dbg_init_done(init_done),.dbg_busy(busy),.transaction_done(done),.dbg_done_latched(dne),
        .dbg_stream_offset(offset),.dbg_stream_sector(sector),.dbg_stream_sector_byte(byte_addr));
    always @(posedge clk)if(!rst)begin
        cycle=cycle+1;
        if(transactions>0 && !init_done)$fatal(1,"init_done fell on normal restart");
        if(dut.reader_start)begin
            transactions=transactions+1;per_request=0;
            if(transactions>1 && !dne)$fatal(1,"previous terminal missing");
        end
        if(previous && !dne)dne_clears=dne_clears+1;
        previous=dne;
        if(valid && ready)begin
            if(data!==(sector[7:0]^byte_addr[7:0]^{7'd0,byte_addr[8]}) || offset!=per_request || sector!=lba+per_request/512 || byte_addr!=per_request%512)
                $fatal(1,"stream mismatch byte=%d off=%d",per_request,offset);
            per_request=per_request+1;accepted=accepted+1;
        end
    end
    task request(input integer n,input integer dynamic_mode);
        begin
            @(negedge clk);owned=dynamic_mode;sectors=n;restart=1;
            @(negedge clk);restart=0;wait(busy);repeat(3)@(negedge clk);
            if(dne || !init_done)$fatal(1,"DNE clear / init preservation");
            wait(done);repeat(3)@(negedge clk);
            if(!dne || busy || !init_done || per_request!=n*512)$fatal(1,"read terminal / extent");
            lba=lba+n;
        end
    endtask
    initial begin
        repeat(8)@(negedge clk);rst=0;wait(init_done);
        for(j=0;j<38;j=j+1)request(1,0);
        $display("CART_RESTARTCHK: PASS 38 separate reads init_commands=1 init_done remains 1; DNE clears for each new transaction, final DNE=1 bytes=%0d/19456",accepted);
        request(1,1);request(7,1);request(7594,1);
        if(transactions!=41 || dne_clears!=40 || accepted!=3911680 || dut.U_SD_STREAM.U_SD_CTRL.init_commands!=1 || dut.U_SD_STREAM.U_SD_CTRL.read_commands!=7640)
            $fatal(1,"vacuous totals requests=%0d clears=%0d bytes=%0d",transactions,dne_clears,accepted);
        $display("VIDEO_RESTARTCHK: PASS counts=1/7/7594; total reads=7640 bytes=3911680/3911680 zero-diff stalls; init_commands=1 init_done_drops=0 DNE_clears=40/40");$finish;
    end
    initial begin #500000000;$fatal(1,"restart semantics timeout");end
endmodule
