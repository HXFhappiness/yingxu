`timescale 1ns/1ps
// D4e: reproduce a fault while a PCM memory command cannot retire.
// SD transaction service is abstract; no pin-level card result is claimed.
module tb_yxv_fault_pending;
    reg clk=0,sys=0,pix=0;always #5 clk=~clk;always #10 sys=~sys;always #7 pix=~pix;
    reg rst=1,busy=0,done=0,reading=0,init_done=1;
    wire owned,failed,start,sdreset,ready;wire [27:0] lba;wire [15:0] sectors,diagnosis,detail;
    wire [7:0] code;wire [10:0] count;wire [9:0] index;wire [31:0] word;
    reg [7:0] meta[0:4095];integer fd,n,pos=0,left=0,offset=0,requests=0;
    yingxu_yxv_pipeline #(.STALL_LIMIT(1000)) dut(
        .clk(clk),.sys_clk(sys),.pix_clk(pix),.rst(rst),.enable(1'b1),.mem_ready(1'b1),
        .sd_init(init_done),.sd_busy(busy),.sd_done(done),.sd_data(offset<4096 ? meta[offset]:8'h5a),
        .sd_data_valid(reading),.sd_data_ready(ready),.sd_start(start),.sd_lba(lba),.sd_sectors(sectors),.sd_reset(sdreset),
        .owned(owned),.failed(failed),.error_code(code),.diagnosis(diagnosis),.detail(detail),.fail_count(count),.fail_index(index),.fail_word(word),
        .audio_ready(1'b0),.audio_pop(1'b0),.x(11'd0),.y(10'd0),.pixel_active(1'b0),.rd2_data(32'd0),.rd2_empty(1'b1),
        .cmd_ready(1'b0),.wready(1'b0),.rvalid(1'b0),.rdata(32'd0),.rlast(1'b0),.mem_done(1'b0),.mem_error(1'b0),.port_idle(1'b1),.port_debug_write(7'd0),.port_debug_cmd(5'd0));
    always @(posedge sys)begin
        if(rst)begin busy<=0;done<=0;reading<=0;init_done<=1;offset<=0;requests<=0;end
        else begin
            done<=0;
            if(start)begin
                if(requests==0 && (lba!=3000000 || sectors!=1))$fatal(1,"header request");
                if(requests==1 && (lba!=3000001 || sectors!=7))$fatal(1,"table request");
                if(requests==2 && sectors!=7594)$fatal(1,"486 PCM request");
                offset<=requests==0 ? 0:requests==1 ? 512:4096;
                left<=sectors*512;reading<=1;busy<=1;requests<=requests+1;
            end
            if(reading && ready)begin offset<=offset+1;left<=left-1;if(left==1)begin reading<=0;busy<=0;done<=1;end end
            // Actual core reset semantics: init_done=0,busy=1 while held reset.
            if(sdreset)begin init_done<=0;busy<=1;reading<=0;done<=0;end
        end
    end
    initial begin
        fd=$fopen("out/mjpeg_d3/diag486.yxv","rb");if(!fd)$fatal(1,"fixture missing");
        n=$fread(meta,fd);$fclose(fd);if(n!=4096)$fatal(1,"fixture table extent");
        repeat(8)@(negedge sys);rst=0;
        wait(sdreset);repeat(50)@(negedge sys);
        $display("PENDING_SIGNATURE F=%h owned=%b init_done=%b busy=%b reset=%b failed=%b code=%h loader=%d/%d diagnosis=%h requests=%0d",
            {owned,init_done,busy,1'b0},owned,init_done,busy,sdreset,failed,dut.fault_code,dut.loader.state,dut.loader.mstate,diagnosis,requests);
        if(!owned || failed || init_done || !busy || !sdreset || requests!=3 || dut.loader.mstate!=1 || dut.fault_code!=8'h9f)$fatal(1,"did not reproduce pending fault");
        if(diagnosis!=16'h929f || code!=8'h9f || count!=32)$fatal(1,"pending fault hidden until ownership release");
        if(detail[15:8]!=0 || index!=0 || word!=32'h94c000)$fatal(1,"unexpected validation failure");
        repeat(100)@(negedge sys);
        if(diagnosis!=16'h929f || !owned)$fatal(1,"pending snapshot not stable");
        $display("LIVEFAULTCHK: PASS PCM blocked before command acceptance; F=A reset held, three read requests; diagnosis=929F ACC=020 I1=94C000 visible while owned=1 failed=0 (receiver debug stub=0)");$finish;
    end
    initial begin #1000000;$fatal(1,"pending fault timeout");end
endmodule
