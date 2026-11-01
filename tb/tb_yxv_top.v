`timescale 1ns/1ps
// Actual board top, wrapper, SD scheduler, decoder, physical controller, WAV.
// Only the external media and vendor PLL/FIFO/HDMI primitives are modeled.
bind yingxu_sdram_control_4port d3_sdram_memory model(
    .clk(CLK),.read(Read),.write(Write),.oe(oe),.addr(mADDR),
    .in_req(IN_REQ),.out_valid(OUT_VALID),.mask(mj_owner?mj_mask:4'd0),.data(mDATAIN),.dq(DQ));

`define VIDEO dut.design_top_wrapper.U_VIDEO
`define WRAPPER dut.design_top_wrapper
`define CTRL dut.design_top_wrapper.U_yingxu_sdram_framebuffer.U_sdram_ctrl
module tb_yxv_top #(parameter integer ACQUIRE_LIMIT_TEST=250_000_000, parameter integer SWITCH_TEST=119);
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0;reg [7:0] sw=SWITCH_TEST; // D4a: SW7 ON + SW3 ON (video), SW4/5/6 OFF
    wire uart_tx;
    hardware_test #(.SIM_FAST_BOOT(1),.VIDEO_ACQUIRE_LIMIT(ACQUIRE_LIMIT_TEST)) dut(.clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(uart_tx),
        .sd_miso(1'b1),.I2S_DI(1'b0),.I2S_RCLK(1'b0),.I2S_BCLK(1'b0),
        .key_0(1'b1),.key_1(1'b1),.ir(1'b1),.sw(sw),.eth_rxc(1'b0),.eth_rxd(4'd0),.eth_rxdv(1'b0),
        .camera_vsync(1'b0),.camera_href(1'b0),.camera_pclk(1'b0),.camera_data(8'd0));
    reg [7:0] container[0:2999999];reg [15:0] gold[0:307199];
    reg [1023:0] filename,goldname;
    integer fd,gfd,nfile,n,pcm_off,pcm_bytes,nframes,i,base,gold_frames=0;
    integer pops=0,underflows=0,pixels=0,max_av=0,avs=0,negative=0,frames_goal=72;
    integer reloads=0,swaps=0,checked_words=0,played_frame,av,location,noinit=0,pending=0;
    reg [15:0] sl,sr;reg [23:0] el,er;
    time first_audio=0,last_audio=0;
    integer sd_play_bytes=0,hdmi_audio_samples=0;
    reg [1023:0] uartname;integer uartfd,uartbit;reg [7:0] uartbyte;
    longint rate_expected,rate_actual,rate_error;
    // Decode the real 115200 8N1 pad, without peeking at the formatter.
    initial begin
        if(!$value$plusargs("uart=%s",uartname))uartname="out/mjpeg_d3/top_uart.txt";
        uartfd=$fopen(uartname,"w");if(!uartfd)$fatal(1,"UART capture open");
        wait(rst_n);
        forever begin
            @(negedge uart_tx);repeat(651)@(posedge clk);
            for(uartbit=0;uartbit<8;uartbit=uartbit+1)begin uartbyte[uartbit]=uart_tx;repeat(434)@(posedge clk);end
            if(!uart_tx)$fatal(1,"UART stop-bit error");
            $fwrite(uartfd,"%c",uartbyte);$fflush(uartfd);
        end
    end
    always @(posedge clk)if(first_audio!=0 && dut.sd_bmp_sd_valid && dut.sd_bmp_sd_ready)sd_play_bytes=sd_play_bytes+1;
    function integer le32(input integer a);
        le32={container[a+3],container[a+2],container[a+1],container[a]};
    endfunction
    always @(posedge clk) if(dut.video_photo_reload) reloads=reloads+1;
    always @(posedge `WRAPPER.video_mem_clk) if(!`VIDEO.local_rst)begin
        if(dut.video_sd_start && !dut.video_first_seen && (dut.video_sd_lba!=3000000 || dut.video_sd_sectors!=1))$fatal(1,"first SD request is not header");
        if(dut.video_first_count==4 && !negative && dut.video_first_bytes!=32'h59585631)$fatal(1,"first YXV magic corrupted");
        if(`VIDEO.decode_done && !`VIDEO.decode_error)begin
            n=$fseek(gfd,(`VIDEO.decode_tag%nframes)*614400,0);
            n=$fread(gold,gfd,0,307200);if(n!=614400)$fatal(1,"top golden extent");
            base=`VIDEO.decode_bank ? 'h40000:0;
            for(i=0;i<153600;i=i+1)
                if(`CTRL.model.memory[base+i]!=={gold[i*2],gold[i*2+1]})
                    $fatal(1,"TOP_PIXCHK tag=%0d word=%0d got=%h expected=%h",`VIDEO.decode_tag,i,`CTRL.model.memory[base+i],{gold[i*2],gold[i*2+1]});
            gold_frames=gold_frames+1;checked_words=checked_words+153600;
            $display("TOP_FRAMECHK tag=%0d cycles=%0d pixels=307200/307200 zero-diff t=%0t",`VIDEO.decode_tag,`VIDEO.decode_cycles,$time);
            $fflush();
        end
        if(`CTRL.mj_owner && `CTRL.IN_REQ && `CTRL.mADDR<'h80000 && `VIDEO.front_valid)begin
            if((`CTRL.mADDR<'h40000)==!`VIDEO.front_bank)
                $fatal(1,"front buffer overwritten");
        end
        if(`VIDEO.replay_write && !negative && !noinit && !pending)$fatal(1,"healthy transaction replayed");
        if(`VIDEO.fault && !negative && !noinit && !pending)$fatal(1,"video fault=%h samples=%0d decoded=%0d display=%0d SDslots=%b",`VIDEO.fault_code,`VIDEO.sample_count,`VIDEO.completed,`VIDEO.present_number,`VIDEO.slots);
    end
    reg [10:0] old_x;reg [9:0] old_y;reg [23:0] pixel_expected;
    reg [15:0] pixel565;integer pixel_addr;
    reg player_expected_valid=0;reg [23:0] player_expected;
    integer hdmi_location;reg [15:0] hdmi_l,hdmi_r;reg [23:0] hdmi_el,hdmi_er;
    always @(posedge `WRAPPER.S_pixel_clk)if(!`VIDEO.local_rst && `WRAPPER.video_go_pix[1] && `WRAPPER.A_valid && pops>0)begin
        hdmi_location=pcm_off+((pops-1)%(pcm_bytes/4))*4;
        hdmi_l={container[hdmi_location+1],container[hdmi_location]};hdmi_r={container[hdmi_location+3],container[hdmi_location+2]};
        hdmi_el={{2{hdmi_l[15]}},hdmi_l,6'd0};hdmi_er={{2{hdmi_r[15]}},hdmi_r,6'd0};
        if(`WRAPPER.A_left!==hdmi_el || `WRAPPER.A_right!==hdmi_er)$fatal(1,"actual HDMI PCM mux mismatch");
        hdmi_audio_samples=hdmi_audio_samples+1;
    end
    always @(posedge `WRAPPER.S_pixel_clk) if(!`VIDEO.local_rst)begin
        if(`VIDEO.scanout.frame_done)swaps=swaps+1;
        if(`WRAPPER.video_actual_pop && `WRAPPER.video_go_pix[1])begin
            location=pcm_off+(pops%(pcm_bytes/4))*4;
            sl={container[location+1],container[location]};sr={container[location+3],container[location+2]};
            el={{2{sl[15]}},sl,6'd0};er={{2{sr[15]}},sr,6'd0};
            if(pops==0)begin first_audio=$time;$display("TOP_START audio after preload t=%0t",$time);end
            pops=pops+1;last_audio=$time;
            #1;if(`WRAPPER.wav_l!==el || `WRAPPER.wav_r!==er)
                $fatal(1,"TOP_PCMCHK sample=%0d L=%h/%h R=%h/%h",pops-1,`WRAPPER.wav_l,el,`WRAPPER.wav_r,er);
        end
        if(`VIDEO.audio_pix[1] && `VIDEO.scanout.displayed_valid)begin
            av=pops-`VIDEO.scanout.displayed_tag*2000;
            if(av<0)av=-av;
            if(av>max_av)max_av=av;
            if(av>=2000)$fatal(1,"AVCHK offset >=1frame samples=%0d tag=%0d abs=%0d",pops,`VIDEO.scanout.displayed_tag,av);
            avs=avs+1;
        end
        if(`VIDEO.scanout.underflow)$fatal(1,"scanout underflow");
        if(`WRAPPER.video_go_pix[1] && `WRAPPER.u_wav.rate_tick && !`WRAPPER.video_actual_pop)
            $fatal(1,"WAV underflow or unexpected inactive player");
    end
    always @(posedge `WRAPPER.S_pixel_clk) if(!`VIDEO.local_rst)begin
        old_x=`WRAPPER.S_pixel_x;old_y=`WRAPPER.S_pixel_y;
        if(`VIDEO.scanout.primed && `VIDEO.scanout.displayed_valid && old_x>=320 && old_x<960 && old_y>=120 && old_y<600)begin
            pixel_addr=(`VIDEO.scanout.bank?'h40000:0)+(old_y-120)*320+(old_x-320)/2;
            pixel565=old_x[0]?`CTRL.model.memory[pixel_addr][15:0]:`CTRL.model.memory[pixel_addr][31:16];
            pixel_expected={pixel565[15:11],pixel565[15:13],pixel565[10:5],pixel565[10:9],pixel565[4:0],pixel565[4:2]};
            #1;if(`VIDEO.rgb!==pixel_expected)$fatal(1,"SCAN_PIXCHK x=%0d y=%0d tag=%0d got=%h expected=%h pair=%h",old_x,old_y,`VIDEO.pixel_tag,`VIDEO.rgb,pixel_expected,`VIDEO.scanout.pair);
            if(player_expected_valid && (`WRAPPER.S_player_rgb!==player_expected || `WRAPPER.S_base_rgb!==player_expected))
                $fatal(1,"actual replay/compositor video mux mismatch");
            player_expected=pixel_expected;player_expected_valid=1;
            pixels=pixels+1;
        end else player_expected_valid=0;
    end
    initial begin
        if(!$value$plusargs("file=%s",filename)||!$value$plusargs("gold=%s",goldname))$fatal(1,"file/gold required");
        n=$value$plusargs("sw=%h",sw);
        n=$value$plusargs("bad=%d",negative);n=$value$plusargs("frames=%d",frames_goal);
        n=$value$plusargs("noinit=%d",noinit);n=$value$plusargs("pending=%d",pending);
        fd=$fopen(filename,"rb");nfile=$fread(container,fd);$fclose(fd);
        nframes=le32(12);pcm_bytes=le32(20);pcm_off=(le32(32+(nframes-1)*8)+le32(36+(nframes-1)*8)+511)/512*512;
        gfd=$fopen(goldname,"rb");if(!gfd)$fatal(1,"top gold open");
        #200;rst_n=1;
        // D5 boots into the menu. Exercise the physical DIP escape before
        // the existing D4 direct-mode playback/fault regressions.
        repeat(10)@(negedge clk);sw[0]=~sw[0];
        repeat(10)@(negedge clk);sw[0]=~sw[0];
        if(pending)begin
            // Test-only injection: keep a memory command pending, then inject
            // the same no-progress fault tested by tb_yxv_fault_pending.
            if(pending==2)begin
                wait(`VIDEO.loader.purpose==2 && `VIDEO.loader.mstate==2 && `VIDEO.loader.sent==4);
                @(negedge `WRAPPER.video_mem_clk);
                force `WRAPPER.vm_wready=1'b0;force `WRAPPER.vm_wvalid=1'b0;
            end else begin
                wait(`VIDEO.loader.purpose==2 && `VIDEO.loader.mstate==1);
                force `VIDEO.cmd_ready=1'b0;
            end
            force `VIDEO.fault_code=8'h9F;force `VIDEO.fault=1'b1;
            repeat(50)@(negedge clk);
            if(!dut.video_owned || dut.video_failed || !dut.video_sd_reset || !dut.sd_rst || dut.sd_dbg_init_done || !dut.sd_dbg_busy)
                $fatal(1,"pending fault signature");
            if(dut.video_diagnosis[7:0]!=8'h9f || !dut.video_diag_valid)$fatal(1,"pending diagnostic absent");
            if(pending==2 && (dut.video_diagnosis!=16'h949f || dut.video_fail_word!=32'hdc0214))
                $fatal(1,"half-write snapshot not on actual top I1=%h",dut.video_fail_word);
            #250000000;
            if(dut.video_failed || !dut.video_owned || dut.video_diagnosis[7:0]!=8'h9f)$fatal(1,"pending fault unstable");
            $display("PENDING_UARTCHK: PASS held SD reset owned=1 failed=0 init_done=0; fault visible before release MISE=%h SP=%h LS=6 F=A",dut.video_diagnosis,dut.video_detail);$finish;
        end
        if(negative || noinit)begin
            wait(dut.video_failed && !dut.video_owned);repeat(20)@(posedge clk);
            if(reloads!=1 || !dut.video_failed || dut.game_mode || !dut.sd_dbg_busy)$fatal(1,"fallback did not reload photo reloads=%0d busy=%b",reloads,dut.sd_dbg_busy);
            if(noinit && `VIDEO.error_code!=8'h9F)$fatal(1,"no-init acquisition watchdog wrong error");
            if(noinit)begin
                if(dut.t_mise!==16'h069F)$fatal(1,"acquire diagnostic not on MISE");
            end else if(negative==1)begin
                if(dut.t_mise!==16'h3992 || dut.t_sprc[15:8]!==8'd1 || dut.video_fail_count!=512 || dut.video_fail_word!==0 || dut.video_fail_index!==0)
                    $fatal(1,"header diagnostic not retained");
            end
            #250000000;
            if(!dut.video_failed || dut.video_owned)$fatal(1,"fault snapshot cleared while photo runs");
            $display("DIAGWIRECHK: MISE=%h SP=%h ACC=%h WC=%h DATA_DISABLED=%h",dut.t_mise,dut.t_sprc,dut.video_fail_count,dut.video_fail_index,dut.video_fail_word);
            $display("FALLBACKCHK: PASS bad-header=%0d no-init=%0d finite reject owned=0 failed=1 photo-reloads=1 next-LBA=%0d",negative,noinit,dut.img_lba);$finish;
        end
        wait(pops>=frames_goal*2000+1);
        if(gold_frames<frames_goal || swaps<frames_goal || pixels<frames_goal*307200 || avs<1000000 || max_av>=2000 || dut.video_dropped!=0)
            $fatal(1,"vacuous integration coverage frames=%0d swaps=%0d pixels=%0d avs=%0d",gold_frames,swaps,pixels,avs);
        if(last_audio-first_audio < (frames_goal*2000-2)*20800)$fatal(1,"audio timing accelerated");
        rate_expected=(pops-1)*64'd1000000000;rate_actual=(last_audio-first_audio)*64'd48000;
        rate_error=rate_actual>rate_expected?rate_actual-rate_expected:rate_expected-rate_actual;
        if(rate_error*10000>rate_expected || hdmi_audio_samples<pops-2)$fatal(1,"48k/HDMI rate ratio failed");
        if(sd_play_bytes*64'd1000000000>(last_audio-first_audio)*64'd1300000)$fatal(1,"playback SD budget exceeded");
        $display("PLAYCHK: PASS samples=%0d/%0d duration_ns=%0d frames=%0d swaps=%0d drops=%0d/%0d ratio_x1M=%0d",pops,frames_goal*2000+1,(last_audio-first_audio),gold_frames,swaps,dut.video_dropped,frames_goal,dut.video_dropped*1000000/frames_goal);
        $display("AVCHK: PASS max_abs_samples=%0d/2000 ratio_x10000=%0d checks=%0d",max_av,max_av*10000/2000,avs);
        $display("TOP_PIXCHK: PASS words=%0d decoded zero-diff scanout pixels=%0d RGB565-high-half-first",checked_words,pixels);
        $display("TOP_PCMCHK: PASS samples=%0d L/R zero-diff including EOF loop 48k actual-clock",pops);
        $display("RATECHK: PASS 48k error_ppm=%0d limit=100 HDMI_samples=%0d zero-diff",rate_error/(rate_expected/1000000),hdmi_audio_samples);
        $display("SDBUDGETCHK: PASS bytes=%0d measured_Bps=%0d limit_Bps=1300000 PCM-from-SDRAM",sd_play_bytes,sd_play_bytes*64'd1000000000/(last_audio-first_audio));
        sw[3]=1;wait(!dut.video_owned);repeat(20)@(posedge clk);
        if(reloads!=1 || dut.game_mode)$fatal(1,"mode exit missing effective photo mode/reload");
        $display("MODECHK: PASS switch-out quiescent photo-reload=1");$finish;
    end
    initial begin #4500000000; $display("DEBUG owned=%b SDinit=%b SDbusy=%b loader=%0d mstate=%0d ready=%b enable=%b phys=%0d decode=%b cmd=%b/%b bytes=%0d",dut.video_owned,dut.sd_dbg_init_done,dut.sd_dbg_busy,`VIDEO.loader.state,`VIDEO.loader.mstate,`VIDEO.loader_ready,`VIDEO.request_sync,`CTRL.ST,`VIDEO.decode_busy,`VIDEO.cmd_valid,`VIDEO.cmd_ready,`VIDEO.loader.absolute);$fatal(1,"top playback timeout pops=%0d frames=%0d",pops,gold_frames);end
endmodule
`undef VIDEO
`undef WRAPPER
`undef CTRL
