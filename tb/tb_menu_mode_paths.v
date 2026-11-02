`timescale 1ns/1ps
// Actual board top; all menu/control RTL is production code.
bind yingxu_sdram_control_4port d3_sdram_memory model(
    .clk(CLK),.read(Read),.write(Write),.oe(oe),.addr(mADDR),
    .in_req(IN_REQ),.out_valid(OUT_VALID),.mask(mj_owner?mj_mask:4'd0),.data(mDATAIN),.dq(DQ));
module tb_menu_mode_paths;
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0,key0=1,key1=1;reg[7:0]sw=8'hff;
    hardware_test #(.SIM_FAST_BOOT(1)) dut(
        .clk(clk),.rst_n(rst_n),.sw(sw),.key_0(key0),.key_1(key1),
        .sd_miso(1'b1),.uart_rx(1'b1),.I2S_DI(1'b0),.I2S_RCLK(1'b0),.I2S_BCLK(1'b0),
        .ir(1'b1),.eth_rxc(1'b0),.eth_rxd(4'd0),.eth_rxdv(1'b0),
        .camera_vsync(1'b0),.camera_href(1'b0),.camera_pclk(1'b0),.camera_data(8'd0));
    integer path,glitch,k,cases=0,events=0,base_events,video_requests=0;
    integer breakout_writes=0,invader_writes=0,game_x;
    reg protect_override=0;
    always @(negedge clk)if(rst_n)begin
        if(dut.menu_real_change)begin
            events=events+1;
            if(protect_override)$fatal(1,"false physical DIP exit path=%0d",path);
        end
        if(protect_override && !dut.menu_override)$fatal(1,"override lost");
        if(dut.menu_ui && (dut.img_restart || dut.load_start || dut.sd_bmp_start_pulse ||
                          dut.design_top_wrapper.I_bmp_start))$fatal(1,"menu triggered BMP path");
    end
    always @(posedge clk)if(rst_n && dut.video_sd_start)video_requests=video_requests+1;
    always @(posedge dut.design_top_wrapper.S_pixel_clk)begin
        if(!rst_n)begin breakout_writes=0;invader_writes=0;end
        else if(dut.design_top_wrapper.tbl_we && dut.design_top_wrapper.tbl_en &&
                !dut.design_top_wrapper.clr_active)begin
            if(dut.design_top_wrapper.sel_breakout)breakout_writes=breakout_writes+1;
            if(dut.design_top_wrapper.sel_hw)invader_writes=invader_writes+1;
        end
    end
    task reset_menu;
        begin
            protect_override=0;
            @(negedge clk);rst_n=0;key0=1;key1=1;sw=8'hff;
            repeat(8)@(negedge clk);rst_n=1;repeat(16)@(negedge clk);
            if(!dut.menu_ui || dut.sd_dbg_init_done || !dut.design_top_wrapper.menu_ctx_qq)
                $fatal(1,"menu depends on SD initialization");
            // Only elapsed boot time is accelerated in these mode tests.
            dut.sw_boot_cnt=27'd24_999_997;
            wait(dut.sw_real_valid && dut.sd_dbg_init_done && !dut.sd_dbg_busy &&
                 dut.design_top_wrapper.video_mem_ready);
            repeat(12)@(negedge clk);protect_override=1;
            if(!dut.menu_ui || dut.menu_sel!=0 || dut.menu_page || dut.menu_pattern!=8'hff)
                $fatal(1,"boot menu");
        end
    endtask
    task next_selection;
        begin
            @(negedge clk);dut.key_lock=0;key1=0;
            repeat(4)@(negedge clk);key1=1;repeat(12)@(negedge clk);
        end
    endtask
    task confirm(input integer spike);
        begin
            @(negedge clk);dut.key_lock=0;key0=0;
            @(negedge clk);if(spike)sw=8'hfe;
            @(negedge clk);sw=8'hff;
            repeat(2)@(negedge clk);key0=1;repeat(128)@(negedge clk);
        end
    endtask
    task short_return;
        begin
            @(negedge clk);dut.key_lock=0;sw=8'h7f;key0=0;
            repeat(16)@(negedge clk);
            if(!dut.menu_ui || dut.menu_page || dut.menu_sel!=0 || dut.img_idx!=0)
                $fatal(1,"SW7+key0 return / held key reconfirmed");
            key0=1;wait(!dut.video_owned);
            wait(dut.sw_real_valid);repeat(128)@(negedge clk);
            if(!dut.menu_ui || !dut.menu_override || dut.game_mode || dut.music_on_w ||
               dut.cart_active || dut.video_requested || dut.video_owned || dut.video_failed)
                $fatal(1,"short return did not persist beyond DIP qualification");
        end
    endtask
    initial begin
        // A >20ms stable physical preset DURING startup must not escape.
        repeat(8)@(negedge clk);rst_n=1;
        repeat(16)@(negedge clk);sw=8'h6f;repeat(1000016)@(negedge clk);
        if(!dut.menu_ui || dut.sw_real_valid || dut.menu_real_change)$fatal(1,"D6 boot inhibition");
        sw=8'hff;repeat(16)@(negedge clk);dut.sw_boot_cnt=27'd24_999_998;
        repeat(2)@(negedge clk);
        if(dut.sw_boot_cnt!=25_000_000 || dut.sw_real_valid)$fatal(1,"D6 half-second boundary");
        wait(dut.sw_real_valid);
        if(!dut.menu_ui || events)$fatal(1,"boot baseline emitted DIP event");
        $display("D6_BOOT PASS >20ms startup preset ignored, 25000000-cycle terminal, initial baseline has no event");$fflush();
        for(glitch=0;glitch<2;glitch=glitch+1)for(path=0;path<5;path=path+1)begin
            reset_menu();base_events=events;video_requests=0;
            if(path==1 || path==2)begin
                next_selection();confirm(glitch);
                if(!dut.menu_ui || !dut.menu_page || dut.menu_sel!=0 || dut.game_mode)
                    $fatal(1,"game item did not open submenu");
                if(path==2)next_selection();
            end else repeat(path==0 ? 0:path-1)next_selection();
            confirm(glitch);
            if(dut.menu_ui || !dut.menu_override)$fatal(1,"confirm did not enter mode");
            repeat(1000016)@(negedge clk);
            case(path)
                0:if(dut.img_idx!=1 || dut.game_mode || dut.menu_pattern!=8'hff)$fatal(1,"photo path");
                1:if(dut.menu_pattern!=8'h7f || !dut.game_mode || dut.game_sel2!=0 || dut.cart_active ||
                     !dut.design_top_wrapper.U_hw_breakout.enable || breakout_writes<2 ||
                     dut.design_top_wrapper.brick_mask==0)$fatal(1,"hardware breakout not drawing");
                2:if(dut.menu_pattern!=8'h5f || !dut.game_mode || dut.game_sel2!=1 || dut.cart_active ||
                     !dut.design_top_wrapper.U_hw_inv.enable || invader_writes<2 ||
                     dut.design_top_wrapper.U_hw_breakout.enable)$fatal(1,"hardware plane not drawing");
                3:if(dut.menu_pattern!=8'h77 || !dut.video_requested || !dut.video_owned || dut.video_failed || video_requests==0)$fatal(1,"video ownership");
                4:if(dut.menu_pattern!=8'h6f || !dut.music_on_w || dut.cart_active ||
                     dut.design_top_wrapper.U_hw_breakout.enable)$fatal(1,"music path started game");
            endcase
            if(path==1 || path==2)begin
                // Actual pins and real frame ticks: the selected engine must
                // move its paddle/player both ways, beyond merely decoding mode.
                if(path==1)game_x=dut.design_top_wrapper.U_hw_breakout.paddle_x;
                else game_x=dut.design_top_wrapper.U_hw_inv.px;
                key1=0;repeat(1000016)@(negedge clk);key1=1;
                if(path==1)begin
                    if(dut.design_top_wrapper.U_hw_breakout.paddle_x<=game_x)$fatal(1,"breakout right key");
                    game_x=dut.design_top_wrapper.U_hw_breakout.paddle_x;
                end else begin
                    if(dut.design_top_wrapper.U_hw_inv.px<=game_x)$fatal(1,"invaders right key");
                    game_x=dut.design_top_wrapper.U_hw_inv.px;
                end
                key0=0;repeat(1000016)@(negedge clk);key0=1;
                if(path==1 && dut.design_top_wrapper.U_hw_breakout.paddle_x>=game_x)$fatal(1,"breakout left key");
                if(path==2 && dut.design_top_wrapper.U_hw_inv.px>=game_x)$fatal(1,"invaders left key");
                repeat(16)@(negedge clk);
                $display("D8_GAMEPLAY PASS path=%0d sprite writes and real-key left/right movement",path);$fflush();
            end
            short_return();
            if(events!=base_events)$fatal(1,"virtual mode/return produced DIP exit");
            cases=cases+1;$display("D7_PATH PASS path=%0d glitch=%0d mode persists, SW7+key0 return",path,glitch);$fflush();
        end
        reset_menu();repeat(5)next_selection();
        if(dut.menu_sel!=0)$fatal(1,"main five-item wrap");
        repeat(4)next_selection();confirm(0);
        if(!dut.menu_ui || dut.menu_page || dut.menu_sel!=4)$fatal(1,"about placeholder");
        next_selection();next_selection();confirm(0);next_selection();next_selection();
        if(!dut.menu_page || dut.menu_sel!=0)$fatal(1,"submenu two-item wrap");
        short_return();
        // 2s fallback is retained, with an exact terminal boundary check.
        reset_menu();confirm(0);
        @(negedge clk);key0=0;dut.menu_hold_cnt=27'd99_999_998;
        repeat(2)@(negedge clk);if(dut.menu_ui)$fatal(1,"fallback too early");
        @(negedge clk);if(!dut.menu_ui)$fatal(1,"fallback hold missing");key0=1;
        reset_menu();
        for(k=0;k<8;k=k+1)begin
            @(negedge clk);sw=8'hff^(8'b1<<k);@(negedge clk);sw=8'hff;repeat(16)@(negedge clk);
        end
        base_events=events;sw=8'h6f;repeat(999998)@(negedge clk);
        if(!dut.menu_override)$fatal(1,"DIP early exit");
        sw=8'hff;repeat(8)@(negedge clk);
        if(events!=base_events)$fatal(1,"bounce accumulated time");
        protect_override=0;sw=8'h6f;repeat(1000016)@(negedge clk);
        if(dut.menu_override || !dut.music_on_w || events!=base_events+1)$fatal(1,"maintenance DIP escape");
        sw=8'h5f;repeat(16)@(negedge clk);
        if(dut.game_sel2!=2 || !dut.cart_active)$fatal(1,"physical DIP mapping changed");
        short_return();protect_override=1;
        $display("D7_CONTROL_ACCEPTANCE PASS paths=%0d pages/wrap/about, no menu BMP, D6 short exit, hold fallback, boot window, raw DIP glitches/bounce/maintenance",cases);
        $finish;
    end
    initial begin #1500000000;$fatal(1,"menu path timeout");end
endmodule
