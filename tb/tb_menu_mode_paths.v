`timescale 1ns/1ps

// Actual board top. Vendor/media primitives are modeled; menu RTL is not replaced.
bind yingxu_sdram_control_4port d3_sdram_memory model(
    .clk(CLK),.read(Read),.write(Write),.oe(oe),.addr(mADDR),
    .in_req(IN_REQ),.out_valid(OUT_VALID),.mask(mj_owner?mj_mask:4'd0),.data(mDATAIN),.dq(DQ));

module tb_menu_mode_paths;
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0,key0=1,key1=1;reg [7:0] sw=8'hff;
    hardware_test #(.SIM_FAST_BOOT(1)) dut(
        .clk(clk),.rst_n(rst_n),.sw(sw),.key_0(key0),.key_1(key1),
        .sd_miso(1'b1),.uart_rx(1'b1),.I2S_DI(1'b0),.I2S_RCLK(1'b0),.I2S_BCLK(1'b0),
        .ir(1'b1),.eth_rxc(1'b0),.eth_rxd(4'd0),.eth_rxdv(1'b0),
        .camera_vsync(1'b0),.camera_href(1'b0),.camera_pclk(1'b0),.camera_data(8'd0));
    integer selection,with_glitch,k,cases=0,events=0,video_requests=0,base_events;
    reg protect_override=0;
    always @(negedge clk)if(rst_n)begin
        if(dut.menu_real_change)begin
            events=events+1;
            if(protect_override)$fatal(1,"unexpected physical-DIP exit sel=%0d glitch=%0d raw=%h pattern=%h previous=%h",
                dut.menu_sel,with_glitch,sw,dut.menu_pattern,dut.sw_real_q);
        end
        if(protect_override && !dut.menu_override)$fatal(1,"menu_override lost while entering/returning from mode");
    end
    always @(posedge clk)if(rst_n && dut.video_sd_start)begin
        video_requests=video_requests+1;
        if(dut.video_first_count==0 && dut.video_sd_lba!=3000000)$fatal(1,"bad first video LBA");
    end
    task reset_menu;
        begin
            protect_override=0;
            @(negedge clk);rst_n=0;key0=1;key1=1;sw=8'hff;
            repeat(8)@(negedge clk);rst_n=1;
            wait(dut.sw_real_valid && dut.sd_dbg_init_done && !dut.sd_dbg_busy &&
                 dut.design_top_wrapper.video_mem_ready);
            repeat(12)@(negedge clk);
            protect_override=1;
            if(!dut.menu_ui || dut.menu_sel!=0 || dut.menu_pattern!=8'hff)$fatal(1,"boot menu");
        end
    endtask
    task next_selection;
        begin
            @(negedge clk);dut.key_lock=0;key1=0;
            repeat(4)@(negedge clk);key1=1;
            repeat(12)@(negedge clk);
        end
    endtask
    task confirm_selection(input integer glitch);
        begin
            @(negedge clk);dut.key_lock=0;key0=0;
            // The virtual DIP changes at the next posedge. One cycle later,
            // inject a one-cycle physical SW0 spike, then restore the real pins.
            @(negedge clk);if(glitch)sw=8'hfe;
            @(negedge clk);sw=8'hff;
            repeat(2)@(negedge clk);key0=1;
            repeat(128)@(negedge clk);
        end
    endtask
    task hold_return;
        begin
            @(negedge clk);key0=0;
            // Only elapsed time is accelerated. Keep the terminal comparisons
            // and the key-lock behavior in the real menu process.
            dut.menu_hold_cnt=27'd99_999_998;
            @(negedge clk);if(dut.menu_ui)$fatal(1,"return before 2-second terminal");
            @(negedge clk);if(dut.menu_ui)$fatal(1,"return one edge too early");
            @(negedge clk);if(!dut.menu_ui)$fatal(1,"2-second hold did not return");
            repeat(4)@(negedge clk);
            if(!dut.menu_ui || dut.img_idx!=0 || dut.menu_sel!=0 ||
               dut.menu_pattern!=8'hff || !dut.menu_override)$fatal(1,"held key confirmed again");
            key0=1;
            wait(!dut.video_owned);
            repeat(128)@(negedge clk);
            if(!dut.menu_ui || dut.game_mode || dut.music_on_w || dut.cart_active ||
               dut.video_requested || dut.video_owned || dut.video_failed)$fatal(1,"return left a mode active");
        end
    endtask
    initial begin
        for(with_glitch=0;with_glitch<=1;with_glitch=with_glitch+1)
            for(selection=0;selection<4;selection=selection+1)begin
                reset_menu();base_events=events;video_requests=0;
                repeat(selection)next_selection();
                if(dut.menu_sel!=selection)$fatal(1,"selection advance");
                confirm_selection(with_glitch);
                if(dut.menu_ui || !dut.menu_override)$fatal(1,"confirm failed");
                case(selection)
                    0:if(dut.img_idx!=1 || dut.menu_pattern!=8'hff || dut.game_mode ||
                         dut.video_requested || dut.music_on_w)$fatal(1,"photo path");
                    1:if(dut.menu_pattern!=8'h1f || !dut.game_mode || !dut.cart_active ||
                         dut.music_on_w || dut.video_requested)$fatal(1,"cart path");
                    2:if(dut.menu_pattern!=8'h77 || !dut.video_requested || !dut.video_owned ||
                         dut.game_mode || video_requests==0)$fatal(1,"video acquisition path");
                    3:if(dut.menu_pattern!=8'h6f || !dut.game_mode || !dut.music_on_w ||
                         dut.cart_active || dut.video_requested)$fatal(1,"music path");
                endcase
                // Stay beyond the real 20 ms detector interval: a mistaken
                // comparison against sw_eff must also fail after settling.
                repeat(1000016)@(negedge clk);
                case(selection)
                    0:if(dut.img_idx!=1 || dut.game_mode || dut.menu_ui)$fatal(1,"photo did not persist");
                    1:if(!dut.cart_active || !dut.game_mode)$fatal(1,"cart did not persist");
                    2:if(!dut.video_requested || !dut.video_owned || dut.video_failed)$fatal(1,"video did not persist");
                    3:if(!dut.music_on_w || dut.cart_active)$fatal(1,"music did not persist");
                endcase
                hold_return();
                if(events!=base_events)$fatal(1,"mode transition produced physical change event");
                cases=cases+1;
                $display("MENU_PATHCHK: PASS sel=%0d glitch=%0d confirm, effective mode, hold boundary, return, override retained",selection,with_glitch);
            end
        reset_menu();
        // All eight physical pins can spike without being a deliberate DIP move.
        for(k=0;k<8;k=k+1)begin
            @(negedge clk);sw=8'hff^(8'b1<<k);
            @(negedge clk);sw=8'hff;
            repeat(16)@(negedge clk);
        end
        base_events=events;
        // A nearly stable change followed by bounce must not accumulate time.
        @(negedge clk);sw=8'h6f;
        repeat(999998)@(negedge clk);
        if(!dut.menu_override)$fatal(1,"DIP escaped before stable interval");
        sw=8'hff;repeat(8)@(negedge clk);
        if(!dut.menu_override || events!=base_events)$fatal(1,"bounce not cancelled");
        protect_override=0;sw=8'h6f;
        repeat(1000016)@(negedge clk);
        if(dut.menu_override || !dut.music_on_w || events!=base_events+1)$fatal(1,"stable maintenance DIP not accepted exactly once");
        // A further DIP move in direct mode is a new baseline on return,
        // even when it happened less than 20 ms before the hold terminal.
        sw=8'h5f;repeat(16)@(negedge clk);
        hold_return();protect_override=1;
        wait(dut.sw_real_valid);
        repeat(256)@(negedge clk);
        if(!dut.menu_override || !dut.menu_ui)$fatal(1,"non-FF physical DIP cleared returned menu");
        $display("MENU_RACECHK: PASS cases=%0d stable raw pins plus switch-time spikes, all 8 single-cycle pin spikes rejected, bounce resets 20ms window, deliberate DIP escape retained",cases);
        $finish;
    end
    initial begin #1000000000;$fatal(1,"menu path timeout");end
endmodule

