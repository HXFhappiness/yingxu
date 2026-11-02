`timescale 1ns/1ps
// Actual SD reader + pipeline + nested arbiters + four-port SDRAM service.
// Card transactions, FIFO/PLL and SDRAM cells are modeled; no pin timing claim.
module tb_yxv_preload #(parameter integer RECOVERY=1);
    reg sys=0,pix=0;always #10 sys=~sys;always #6.818 pix=~pix;
    wire clk;reg rst=1;wire owned,failed,sdstart,sdreset,sdready,sdvalid,sdinit,sdbusy,sddone;
    wire [7:0] sddata,code;wire [27:0] lba;wire [15:0] sectors,diagnosis,detail;
    wire [10:0] count;wire [9:0] index;wire [31:0] word;
    wire cv,cr,cw,wv,wr,wl,rv,rr,rl,mdone,merror,idle;wire [20:0] ca;wire [3:0] cn;wire [31:0] wd,rd,dq;
    integer block=0,n,fd,nfile,i,j,requests=0,payload,pcm_off,frames,pcm_sectors;
    integer beats=0,bursts=0,first_latency=0,age=0,max_latency=0,display_words=0;
    reg tracking=0,first_pcm_command=0;reg [7:0] source[0:8388607];reg [1023:0] filename;
    wire block_data=(block==1 || block==2) && first_pcm_command && beats>=(block==1 ? 0:4);
    wire block_grant=block==3 && dut.loader.purpose==2;
    wire block_done=block==4 && first_pcm_command;
    time fault_time=0,reset_time=0,init_drop_time=0;
    integer init_commands=0,replays=0,missing_cycles=0;reg initialized=0,dropped_once=0;
    wire positive=block==0 || block==8 || block==9 || block==10;
    always @(posedge clk)begin
        if(rst)begin dropped_once<=0;missing_cycles<=0;end
        else begin
            if((block==8 || block==10) && cv && dut.loader.purpose==2 && missing_cycles<3)begin
                missing_cycles<=missing_cycles+1;
                if(missing_cycles==2)dropped_once<=1;
            end
            if(block==9 && cv && cr && dut.loader.purpose==2)dropped_once<=1;
            if(block==10 && mdone)missing_cycles<=0;
        end
        if(!rst && dut.replay_write)replays=replays+1;
    end
    always @(posedge clk)if(!rst && dut.fault && fault_time==0)fault_time=$time;
    always @(posedge sys)if(!rst)begin
        if(probe.U_SD_STREAM.ctrl_start && probe.U_SD_STREAM.ctrl_mode==0)init_commands=init_commands+1;
        if(sdinit)initialized=1;
        if(sdreset && reset_time==0)reset_time=$time;
        if(initialized && !sdinit)begin
            if(!sdreset)$fatal(1,"init_done fell without actual reset");
            if(init_drop_time==0)init_drop_time=$time;
        end
    end
    wire phy_wr;wire [6:0] write_debug;wire block_command=dut.loader.purpose==2 && (block==7 ||
        (block==8 && !dropped_once) || (block==10 && missing_cycles<3) ||
        (block==9 && !dropped_once && phy.mj_port.port_adapter.state==5));
    function integer le32(input integer p);le32={source[p+3],source[p+2],source[p+1],source[p]};endfunction
    yingxu_sd_integration_probe #(.DYNAMIC_COUNT(1),.SECTOR_COUNT(1)) probe(
        .clk(sys),.rst(rst || sdreset),.trigger_sw(1'b0),.legacy_inhibit(1'b0),.dynamic_enable(owned),.dynamic_count(sectors),
        .start_sector(lba),.restart(sdstart),.transaction_done(sddone),.out_stream_data(sddata),.out_stream_valid(sdvalid),.out_stream_ready(sdready),
        .sd_miso(1'b1),.dbg_init_done(sdinit),.dbg_busy(sdbusy));
    yingxu_yxv_pipeline #(.STALL_LIMIT(100000),.RECOVER_LOST_WRITE(RECOVERY)) dut(
        .clk(clk),.sys_clk(sys),.pix_clk(pix),.rst(rst),.enable(1'b1),.mem_ready(!rst),
        .sd_init(sdinit),.sd_busy(sdbusy),.sd_done(sddone),.sd_data(sddata),.sd_data_valid(sdvalid),.sd_data_ready(sdready),
        .sd_start(sdstart),.sd_lba(lba),.sd_sectors(sectors),.sd_reset(sdreset),.owned(owned),.failed(failed),.error_code(code),
        .diagnosis(diagnosis),.detail(detail),.fail_count(count),.fail_index(index),.fail_word(word),
        .audio_ready(1'b0),.audio_pop(1'b0),.x(11'd0),.y(10'd0),.pixel_active(1'b0),.rd2_data(32'd0),.rd2_empty(1'b1),
        .cmd_valid(cv),.cmd_ready(cr),.cmd_write(cw),.cmd_addr(ca),.cmd_words(cn),.wvalid(wv),.wready(wr),.wdata(wd),.wlast(wl),
        .rvalid(rv),.rready(rr),.rdata(rd),.rlast(rl),.mem_done(mdone && !block_done),.mem_error(merror),.port_idle(idle),.port_debug_write(write_debug));
    assign wr=phy_wr && !block_data;
    yingxu_sdram_control_4port #(.MJPEG_PORT(1)) phy(
        .REF_CLK(sys),.RESET_N(!rst),.CLK(clk),.DQ(dq),
        .WR1_DATA(32'd0),.WR1(1'b0),.WR1_ADDR(21'd0),.WR1_MAX_ADDR(21'd128),.WR1_LENGTH(9'd128),.WR1_LOAD(1'b0),.WR1_CLK(clk),
        .WR2_DATA(32'd0),.WR2(1'b0),.WR2_ADDR(21'd0),.WR2_MAX_ADDR(21'd128),.WR2_LENGTH(9'd128),.WR2_LOAD(1'b0),.WR2_CLK(sys),
        .RD1(1'b0),.RD1_ADDR(21'd0),.RD1_MAX_ADDR(21'd128),.RD1_LENGTH(9'd128),.RD1_LOAD(1'b0),.RD1_CLK(pix),
        .RD2(1'b0),.RD2_ADDR(21'd0),.RD2_MAX_ADDR(21'd153600),.RD2_LENGTH(9'd128),.RD2_LOAD(block_grant),.RD2_CLK(pix),
        .MJ_ACTIVE(owned),.MJ_VALID(cv && !block_command),.MJ_READY(cr),.MJ_WRITE(cw),.MJ_ADDR(ca),.MJ_WORDS(cn),
        .MJ_WVALID(wv && !block_data),.MJ_WREADY(phy_wr),.MJ_WDATA(wd),.MJ_WLAST(wl),
        .MJ_RVALID(rv),.MJ_RREADY(rr),.MJ_RDATA(rd),.MJ_RLAST(rl),.MJ_DONE(mdone),.MJ_ERROR(merror),.MJ_IDLE(idle),.MJ_DEBUG_WRITE(write_debug));
    d3_sdram_memory memory(.clk(clk),.read(phy.Read),.write(phy.Write),.oe(phy.oe),.addr(phy.mADDR),
        .in_req(phy.IN_REQ),.out_valid(phy.OUT_VALID),.mask(phy.mj_owner ? phy.mj_mask:4'd0),.data(phy.mDATAIN),.dq(dq));
    always @(posedge sys)if(!rst && sdstart)begin
        if(requests==0 && (lba!=3000000 || sectors!=1))$fatal(1,"first header request");
        if(requests==1 && (lba!=3000001 || sectors!=7))$fatal(1,"remaining table request");
        if(requests==2 && (lba!=3000000+pcm_off/512 || sectors!=pcm_sectors))$fatal(1,"PCM LBA/count");
        requests=requests+1;
        if(requests==3)$display("PCM_REQUEST frames=%0d LBA=%0d sectors=%0d expected_bytes=%0d",frames,lba,sectors,sectors*512);$fflush();
    end
    always @(posedge clk)if(!rst)begin
        if(phy.OUT_VALID && phy.RD_MASK[1])display_words=display_words+1;
        if(cv && cr && cw)begin age=0;tracking=1;if(ca==21'h100000)first_pcm_command=1;end
        if(tracking)age=age+1;
        if(wv && wr)beats=beats+1;
        if(mdone && !merror)begin
            bursts=bursts+1;tracking=0;
            if(bursts==1)first_latency=age;
            if(age>max_latency)max_latency=age;
        end
        if(cr && idle)$fatal(1,"ready advertised before physical command capture");
        if(cv && cr && phy.mj_port.port_adapter.state!=5)$fatal(1,"command acknowledged outside captured ACCEPT");
        if(positive && dut.loader.mstate==2 && dut.loader.sent<8 &&
           phy.mj_port.port_adapter.state!=1 && !dut.replay_write)
            $fatal(1,"accepted loader write lost physical COLLECT at sent=%0d",dut.loader.sent);
        if(positive && dut.fault)$fatal(1,"positive preload fault phase=%h code=%h sent=%d phy=%d/%d ST=%d",dut.lp,dut.fault_code,dut.loader.sent,phy.mj_port.port_adapter.state,phy.mj_port.port_adapter.position,phy.ST);
    end
    initial begin
        #10000000;
        $display("PRELOAD_PROGRESS block=%0d owned=%b init=%b busy=%b start=%b requests=%d phase=%h count=%0d sdvalid=%b ready=%b diag=%h model=%d FIFO=%d/%d",
            block,owned,sdinit,sdbusy,sdstart,requests,dut.lp,dut.loader.count,sdvalid,sdready,diagnosis,probe.U_SD_STREAM.U_SD_CTRL.state,dut.sd_bytes.wp,dut.sd_bytes.rp);$fflush();
        if(!positive)$fatal(1,"negative must finish in 10ms");
    end
    reg [31:0] expected_word;
    initial begin
        n=$value$plusargs("block=%d",block);if(!$value$plusargs("file=%s",filename))$fatal(1,"fixture required");
        fd=$fopen(filename,"rb");nfile=$fread(source,fd);$fclose(fd);
        frames=le32(12);payload=le32(20);pcm_sectors=(payload+511)/512;
        pcm_off=(le32(32+(frames-1)*8)+le32(36+(frames-1)*8)+511)/512*512;
        repeat(8)@(negedge sys);rst=0;
        if(!positive)begin
            if(block==5 || block==6)begin
                wait(first_pcm_command);@(negedge clk);
                force phy.mj_port.port_adapter.phy_done=1'b0;
                if(block==5)force phy.mj_port.port_adapter.phy_in_req=1'b0;
            end
            wait(diagnosis!=0);repeat(50)@(negedge sys);
            $display("PCM_STALL_REPRO block=%0d MISE=%h SP=%h ACC=%h sent=%0d phy_state=%0d position=%0d ST=%0d reset=%b F=%h",
                block,diagnosis,detail,count,dut.loader.sent,phy.mj_port.port_adapter.state,phy.mj_port.port_adapter.position,phy.ST,sdreset,{owned,sdinit,sdbusy,1'b0});
            if(diagnosis!=(block==7 ? 16'h929f:16'h949f) || detail!=16'h0001 || count!=32 || requests!=3 || !sdreset || !owned || sdinit || !sdbusy)$fatal(1,"board signature not reproduced");
            if(dut.loader.sent!=(block==1 || block==7 ? 0:block==2 ? 4:8))$fatal(1,"bad write-beat witness");
            if(replays!=0)$fatal(1,"unexpected command replay count=%0d",replays);
            if(block!=7 && !word[23])$fatal(1,"write-wait extension marker absent");
            if((word & 32'h7ff) !== (block==1 ? 32'h010 : block==2 ? 32'h214 : block==3 ? 32'h420 : block==4 ? 32'h408 : block==5 ? 32'h430 : block==6 ? 32'h438 : 32'h000))
                $fatal(1,"compact write snapshot mismatch block=%0d I1=%h",block,word);
            if(init_commands!=1 || fault_time==0 || reset_time<=fault_time || init_drop_time<reset_time)
                $fatal(1,"reset ordering init=%0d fault=%0t reset=%0t init_drop=%0t",init_commands,fault_time,reset_time,init_drop_time);
            $display("SD_RESET_ORDERCHK: PASS init_commands=1 fault=%0t then abort_reset=%0t then init_drop=%0t; DNE was cleared at PCM request",fault_time,reset_time,init_drop_time);
            force write_debug=7'h7f;
            force dut.loader.sent=4'hf;
            repeat(30)@(negedge sys);
            if(word !== {8'd0,dut.frozen_write})$fatal(1,"write snapshot changed after fault");
            $display("WRITE_DIAGCHK: PASS block=%0d I1=%h sent=%0d state=%0d position=%0d inner=%b outer=%b RP/LR/CV/CR/WV/WR=%b",block,word,word[10:7],word[6:4],word[3:0],word[22:20],word[19:17],word[16:11]);
            if(block==7)$display("COMMAND_WAITCHK: PASS persistent missing valid stays before command acceptance; no ghost owner or replay");
            else $display("PCM_WAITCHK: PASS distinct real SDRAM waits still produce the original bounded write timeout");$finish;
        end
        wait(dut.loader_ready);@(negedge clk);
        if(requests!=3 || !sdinit || sdbusy || failed || dut.fault || dut.loader.count!=pcm_sectors*512 || bursts!=pcm_sectors*16 || beats!=pcm_sectors*128)
            $fatal(1,"preload terminal requests=%0d bursts=%0d beats=%0d count=%0d",requests,bursts,beats,dut.loader.count);
        for(i=0;i<pcm_sectors*128;i=i+1)begin
            j=pcm_off+i*4;
            expected_word={source[j+3],source[j+2],source[j+1],source[j]};
            if(memory.memory[21'h100000+i]!==expected_word)$fatal(1,"PCM word diff %0d got=%h expected=%h",i,memory.memory[21'h100000+i],expected_word);
        end
        if(block && (replays!=0 || init_commands!=1 || fault_time!=0 || sdreset))
            $fatal(1,"command replay recovery failed replays=%0d init=%0d fault=%0t",replays,init_commands,fault_time);
        if(block)$display("CAPTURE_ACKCHK: PASS block=%0d delayed/masked command valid, full PCM zero-diff, replays=0, no SD reset or repeated initialization",block);
        if(first_latency<8 || max_latency>1000 || display_words<128)$fatal(1,"vacuous/bounded write service");
        $display("PCM_FULLCHK: PASS frames=%0d sectors=%0d payload=%0d padded=%0d bursts=%0d/%0d words=%0d/%0d zero-diff init_done=1 failed=0",frames,pcm_sectors,payload,pcm_sectors*512,bursts,pcm_sectors*16,beats,pcm_sectors*128);
        $display("WRITE_RATIOCHK: PASS first_latency=%0d max_latency=%0d/1000 cycles display_words=%0d",first_latency,max_latency,display_words);$finish;
    end
    initial begin #4000000000;$fatal(1,"preload timeout");end
endmodule
