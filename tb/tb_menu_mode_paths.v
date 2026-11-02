`timescale 1ns/1ps
// Actual board top; all menu/control RTL is production code.
bind yingxu_sdram_control_4port d3_sdram_memory model(
    .clk(CLK),.read(Read),.write(Write),.oe(oe),.addr(mADDR),
    .in_req(IN_REQ),.out_valid(OUT_VALID),.mask(mj_owner?mj_mask:4'd0),.data(mDATAIN),.dq(DQ));
module tb_menu_mode_paths #(parameter integer BOOT_MENU=1);
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0,key0=1,key1=1;reg[7:0]sw=8'hff;
    hardware_test #(.SIM_FAST_BOOT(1),.BOOT_MENU(BOOT_MENU)) dut(
        .clk(clk),.rst_n(rst_n),.sw(sw),.key_0(key0),.key_1(key1),
        .sd_miso(1'b1),.uart_rx(1'b1),.I2S_DI(1'b0),.I2S_RCLK(1'b0),.I2S_BCLK(1'b0),
        .ir(1'b1),.eth_rxc(1'b0),.eth_rxd(4'd0),.eth_rxdv(1'b0),
        .camera_vsync(1'b0),.camera_href(1'b0),.camera_pclk(1'b0),.camera_data(8'd0));
    integer path,glitch,k,cases=0,events=0,base_events,video_requests=0;
    integer breakout_writes=0,invader_writes=0,game_x,cart_writes=0,j,pixel_checks=0;
    reg [23:0] menu_expected;
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
        if(!rst_n)begin breakout_writes=0;invader_writes=0;cart_writes=0;end
        else if(dut.design_top_wrapper.tbl_we && dut.design_top_wrapper.tbl_en &&
                !dut.design_top_wrapper.clr_active)begin
            if(dut.design_top_wrapper.sel_cart)cart_writes=cart_writes+1;
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
        reg[7:0] saved_sw;
        begin
            saved_sw=sw;
            @(negedge clk);dut.key_lock=0;key0=0;
            @(negedge clk);if(spike)sw=saved_sw^8'h01;
            @(negedge clk);sw=saved_sw;
            repeat(2)@(negedge clk);key0=1;repeat(128)@(negedge clk);
        end
    endtask
    task short_return;
        begin
            @(negedge clk);sw=sw & 8'h7f;
            // Reproduce the real operation: move SW7, wait >20ms, THEN press.
            repeat(1000016)@(negedge clk);
            if(!dut.menu_override && BOOT_MENU)$fatal(1,"SW7 stole menu ownership");
            @(negedge clk);dut.key_lock=0;key0=0;
            repeat(16)@(negedge clk);
            if(!dut.menu_ui || dut.menu_page || dut.menu_sel!=0 || dut.img_idx!=0)
                $fatal(1,"SW7+key0 return / held key reconfirmed");
            key0=1;wait(!dut.video_owned);
            wait(!dut.design_top_wrapper.clr_active && !dut.design_top_wrapper.game_reset_pix);
            repeat(1000016)@(negedge clk);repeat(128)@(negedge clk);
            if(!dut.menu_ui || !dut.menu_override || dut.game_mode || dut.music_on_w ||
               dut.cart_active || dut.video_requested || dut.video_owned || dut.video_failed)
                $fatal(1,"short return did not persist beyond DIP qualification");
            if(dut.cart_lstate_w!=0 || dut.cart_retire_w!=0 || dut.cart_flags_w!=0 ||
               dut.cart_pc_w!=0 || dut.design_top_wrapper.brick_mask!=0)
                $fatal(1,"cartridge state/CPU still active after exit");
            for(j=0;j<15;j=j+1)if(dut.design_top_wrapper.U_sprite.spr_tab[j][66])
                $fatal(1,"sprite %0d survived menu entry",j);
        end
    endtask
    initial begin
        if(!BOOT_MENU)begin
            sw=8'h7f;repeat(8)@(negedge clk);rst_n=1;
            repeat(1000016)@(negedge clk);
            if(dut.menu_override || !dut.design_top_wrapper.U_hw_breakout.enable || breakout_writes<2)
                $fatal(1,"maintenance hardware Breakout unavailable");
            dut.sw_boot_cnt=27'd25_000_000;
            sw=8'h3f;repeat(1000016)@(negedge clk);
            if(!dut.design_top_wrapper.U_hw_inv.enable || invader_writes<2)$fatal(1,"maintenance Invaders unavailable");
            sw=8'h1f;repeat(1000016)@(negedge clk);
            if(!dut.cart_active || dut.cart_wcnt_w!=604)$fatal(1,"maintenance cartridge unavailable");
            short_return();
            sw=8'h77;repeat(1000016)@(negedge clk);
            if(!dut.menu_ui || !dut.menu_override)$fatal(1,"DIP stole menu after direct return");
            $display("D9_DIRECT PASS BOOT_MENU=0 hardware presets and YX-8 retained; explicit return transfers exclusive ownership");$finish;
        end
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
            // Simulate an old photo stream while the cartridge restart is
            // queued: the real reader would withhold start while busy.
            if(path==1 && glitch==0)force dut.U_SD_INTEGRATION.reader_start=1'b0;
            confirm(glitch);
            if(dut.menu_ui || !dut.menu_override)$fatal(1,"confirm did not enter mode");
            if(path==1 && glitch==0)begin
                wait(dut.design_top_wrapper.u_cart.stream_armed);
                @(negedge clk);
                force dut.sd_bmp_sd_valid=1'b1;
                force dut.sd_bmp_sd_data=8'hff;
                force dut.sd_dbg_stream_sector=28'd76032;
                repeat(64)@(negedge clk);
                if(dut.design_top_wrapper.u_cart.bq_wp!=0 ||
                   dut.design_top_wrapper.u_cart.hdr_idx!=0)
                    $fatal(1,"old photo bytes entered queued cartridge request");
                release dut.sd_bmp_sd_valid;release dut.sd_bmp_sd_data;release dut.sd_dbg_stream_sector;
                release dut.U_SD_INTEGRATION.reader_start;
                $display("CART_STREAM_OWNER PASS old photo bytes rejected while cartridge request queued");$fflush();
            end
            repeat(1000016)@(negedge clk);
            case(path)
                0:if(dut.img_idx!=1 || dut.game_mode || dut.menu_pattern!=8'hff)$fatal(1,"photo path");
                1:if(dut.menu_pattern!=8'h5f || !dut.game_mode || dut.game_sel2!=2 || !dut.cart_active ||
                     !dut.design_top_wrapper.u_cart.cpu_on_i || cart_writes<2 || dut.cart_wcnt_w!=492 ||
                     dut.cart_lba_sel!=1001000)$fatal(1,"YX-8 BREAKOUT not loaded/drawing");
                2:if(dut.menu_pattern!=8'h1f || !dut.game_mode || dut.game_sel2!=2 || !dut.cart_active ||
                     !dut.design_top_wrapper.u_cart.cpu_on_i || cart_writes<2 || dut.cart_wcnt_w!=604 ||
                     dut.cart_lba_sel!=1000000)$fatal(1,"YX-8 INVADERS not loaded/drawing");
                3:if(dut.menu_pattern!=8'h77 || !dut.video_requested || !dut.video_owned || dut.video_failed || video_requests==0)$fatal(1,"video ownership");
                4:if(dut.menu_pattern!=8'h6f || !dut.music_on_w || dut.cart_active ||
                     dut.design_top_wrapper.U_hw_breakout.enable)$fatal(1,"music path started game");
            endcase
            if(path==1 || path==2)begin
                // Both titles execute on the YX-8 CPU. Slot 0 is the paddle/player.
                game_x=dut.design_top_wrapper.U_sprite.spr_tab[0][65:55];
                key1=0;repeat(1000016)@(negedge clk);key1=1;
                if(dut.design_top_wrapper.U_sprite.spr_tab[0][65:55]<=game_x)$fatal(1,"YX-8 right key");
                game_x=dut.design_top_wrapper.U_sprite.spr_tab[0][65:55];
                key0=0;repeat(1000016)@(negedge clk);key0=1;
                if(dut.design_top_wrapper.U_sprite.spr_tab[0][65:55]>=game_x)$fatal(1,"YX-8 left key");
                repeat(16)@(negedge clk);
                $display("D9_CART_GAMEPLAY PASS path=%0d real SD image, CPU retired instructions, sprites, left/right movement",path);$fflush();
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
        sw=8'h6f;repeat(1000016)@(negedge clk);
        if(!dut.menu_override || !dut.menu_ui || events!=base_events)$fatal(1,"stable DIP stole menu");
        // Leave SW7 ON in the main menu: KEY0 must still confirm, once.
        confirm(0);
        if(dut.menu_ui || dut.img_idx!=1)$fatal(1,"SW7 ON locked main KEY0 into return");
        short_return();
        // A complete post-game/return frame must contain only the hardware menu.
        while(!(dut.design_top_wrapper.S_pixel_x==0 && dut.design_top_wrapper.S_pixel_y==0))
            @(negedge dut.design_top_wrapper.S_pixel_clk);
        while(dut.design_top_wrapper.S_pixel_y<720)begin
            if(dut.design_top_wrapper.S_pixel_active)begin
                menu_expected=dut.design_top_wrapper.menu_rgb;
                if(dut.design_top_wrapper.S_pixel_x>=930 && dut.design_top_wrapper.S_pixel_x<942 &&
                   dut.design_top_wrapper.S_pixel_y>=268 && dut.design_top_wrapper.S_pixel_y<324)
                    menu_expected=24'h00A652;
                if(dut.design_top_wrapper.S_img_rgb!==menu_expected)$fatal(1,"post-exit compositor residue");
                pixel_checks=pixel_checks+1;
            end
            @(negedge dut.design_top_wrapper.S_pixel_clk);
        end
        $display("D9_CONTROL_ACCEPTANCE PASS paths=%0d real YX-8 cards, exclusive ownership, SW7-before-key exit, zero CPU/table residue, main KEY0 ON; menu pixels=%0d",cases,pixel_checks);
        $finish;
    end
    initial begin #1500000000;$fatal(1,"menu path timeout");end
endmodule
