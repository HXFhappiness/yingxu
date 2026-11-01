`timescale 1ns/1ps
// Actual SD reader + pipeline + nested arbiters + four-port SDRAM service.
// Card transactions, FIFO/PLL and SDRAM cells are modeled; no pin timing claim.
module tb_yxv_preload;
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
    wire phy_wr;wire [6:0] write_debug;
    function integer le32(input integer p);le32={source[p+3],source[p+2],source[p+1],source[p]};endfunction
    yingxu_sd_integration_probe #(.DYNAMIC_COUNT(1),.SECTOR_COUNT(1)) probe(
        .clk(sys),.rst(rst || sdreset),.trigger_sw(1'b0),.legacy_inhibit(1'b0),.dynamic_enable(owned),.dynamic_count(sectors),
        .start_sector(lba),.restart(sdstart),.transaction_done(sddone),.out_stream_data(sddata),.out_stream_valid(sdvalid),.out_stream_ready(sdready),
        .sd_miso(1'b1),.dbg_init_done(sdinit),.dbg_busy(sdbusy));
    yingxu_yxv_pipeline #(.STALL_LIMIT(100000)) dut(
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
        .MJ_ACTIVE(owned),.MJ_VALID(cv),.MJ_READY(cr),.MJ_WRITE(cw),.MJ_ADDR(ca),.MJ_WORDS(cn),
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
        if(!block && dut.fault)$fatal(1,"positive preload fault phase=%h code=%h sent=%d phy=%d/%d ST=%d",dut.lp,dut.fault_code,dut.loader.sent,phy.mj_port.port_adapter.state,phy.mj_port.port_adapter.position,phy.ST);
    end
    initial begin
        #10000000;
        $display("PRELOAD_PROGRESS block=%0d owned=%b init=%b busy=%b start=%b requests=%d phase=%h count=%0d sdvalid=%b ready=%b diag=%h model=%d FIFO=%d/%d",
            block,owned,sdinit,sdbusy,sdstart,requests,dut.lp,dut.loader.count,sdvalid,sdready,diagnosis,probe.U_SD_STREAM.U_SD_CTRL.state,dut.sd_bytes.wp,dut.sd_bytes.rp);$fflush();
        if(block)$fatal(1,"negative must finish in 10ms");
    end
    reg [31:0] expected_word;
    initial begin
        n=$value$plusargs("block=%d",block);if(!$value$plusargs("file=%s",filename))$fatal(1,"fixture required");
        fd=$fopen(filename,"rb");nfile=$fread(source,fd);$fclose(fd);
        frames=le32(12);payload=le32(20);pcm_sectors=(payload+511)/512;
        pcm_off=(le32(32+(frames-1)*8)+le32(36+(frames-1)*8)+511)/512*512;
        repeat(8)@(negedge sys);rst=0;
        if(block)begin
            if(block>=5)begin
                wait(first_pcm_command);@(negedge clk);
                force phy.mj_port.port_adapter.phy_done=1'b0;
                if(block==5)force phy.mj_port.port_adapter.phy_in_req=1'b0;
            end
            wait(diagnosis!=0);repeat(50)@(negedge sys);
            $display("PCM_STALL_REPRO block=%0d MISE=%h SP=%h ACC=%h sent=%0d phy_state=%0d position=%0d ST=%0d reset=%b F=%h",
                block,diagnosis,detail,count,dut.loader.sent,phy.mj_port.port_adapter.state,phy.mj_port.port_adapter.position,phy.ST,sdreset,{owned,sdinit,sdbusy,1'b0});
            if(diagnosis!=16'h949f || detail!=16'h0001 || count!=32 || requests!=3 || !sdreset || !owned || sdinit || !sdbusy)$fatal(1,"board signature not reproduced");
            if(dut.loader.sent!=(block==1 ? 0:block==2 ? 4:8))$fatal(1,"bad write-beat witness");
            if(word !== (block==1 ? 32'h010 : block==2 ? 32'h214 : block==3 ? 32'h420 : block==4 ? 32'h408 : block==5 ? 32'h430 : 32'h438))
                $fatal(1,"compact write snapshot mismatch block=%0d I1=%h",block,word);
            force write_debug=7'h7f;
            force dut.loader.sent=4'hf;
            repeat(30)@(negedge sys);
            if(word !== {21'd0,dut.frozen_write})$fatal(1,"write snapshot changed after fault");
            $display("WRITE_DIAGCHK: PASS block=%0d I1=%h sent=%0d state=%0d position=%0d",block,word,word[10:7],word[6:4],word[3:0]);
            $display("PCM_WAITCHK: PASS identical board signature for distinct SDRAM waits; not uniquely an SD fault");$finish;
        end
        wait(dut.loader_ready);@(negedge clk);
        if(requests!=3 || !sdinit || sdbusy || failed || dut.fault || dut.loader.count!=pcm_sectors*512 || bursts!=pcm_sectors*16 || beats!=pcm_sectors*128)
            $fatal(1,"preload terminal requests=%0d bursts=%0d beats=%0d count=%0d",requests,bursts,beats,dut.loader.count);
        for(i=0;i<pcm_sectors*128;i=i+1)begin
            j=pcm_off+i*4;
            expected_word={source[j+3],source[j+2],source[j+1],source[j]};
            if(memory.memory[21'h100000+i]!==expected_word)$fatal(1,"PCM word diff %0d got=%h expected=%h",i,memory.memory[21'h100000+i],expected_word);
        end
        if(first_latency<8 || max_latency>1000 || display_words<128)$fatal(1,"vacuous/bounded write service");
        $display("PCM_FULLCHK: PASS frames=%0d sectors=%0d payload=%0d padded=%0d bursts=%0d/%0d words=%0d/%0d zero-diff init_done=1 failed=0",frames,pcm_sectors,payload,pcm_sectors*512,bursts,pcm_sectors*16,beats,pcm_sectors*128);
        $display("WRITE_RATIOCHK: PASS first_latency=%0d max_latency=%0d/1000 cycles display_words=%0d",first_latency,max_latency,display_words);$finish;
    end
    initial begin #4000000000;$fatal(1,"preload timeout");end
endmodule
