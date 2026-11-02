`timescale 1ns/1ps

bind yingxu_sdram_control_4port d3_sdram_memory model(
    .clk(CLK),.read(Read),.write(Write),.oe(oe),.addr(mADDR),
    .in_req(IN_REQ),.out_valid(OUT_VALID),.mask(mj_owner?mj_mask:4'd0),.data(mDATAIN),.dq(DQ));
module tb_d5_menu;
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0,key0=1,key1=1;reg [7:0] sw=8'hff;
    hardware_test #(.SIM_FAST_BOOT(1)) dut(
        .clk(clk),.rst_n(rst_n),.sw(sw),.key_0(key0),.key_1(key1),
        .sd_miso(1'b1),.uart_rx(1'b1),.I2S_DI(1'b0),.I2S_RCLK(1'b0),.I2S_BCLK(1'b0),
        .ir(1'b1),.eth_rxc(1'b0),.eth_rxd(4'd0),.eth_rxdv(1'b0),
        .camera_vsync(1'b0),.camera_href(1'b0),.camera_pclk(1'b0),.camera_data(8'd0));
    integer writes=0,i,clears=0;reg [4:0] rows=0;
    always @(posedge dut.design_top_wrapper.S_pixel_clk)
        if(dut.design_top_wrapper.tbl_we && dut.design_top_wrapper.tbl_en &&
           dut.design_top_wrapper.tbl_slot==15)begin
            if(!dut.menu_ui)$fatal(1,"menu write outside menu");
            if(dut.design_top_wrapper.tbl_x!=930 || dut.design_top_wrapper.tbl_w!=12 ||
               dut.design_top_wrapper.tbl_h!=56 || dut.design_top_wrapper.tbl_c!=24'h00a651)
                $fatal(1,"bar geometry/color changed");
            case(dut.design_top_wrapper.tbl_y)
                268:rows[0]=1;355:rows[1]=1;442:rows[2]=1;529:rows[3]=1;616:rows[4]=1;
                default:$fatal(1,"bad bar y");
            endcase
            writes=writes+1;
        end
    always @(posedge dut.design_top_wrapper.S_pixel_clk)
        if(dut.design_top_wrapper.tbl_we && !dut.design_top_wrapper.tbl_en &&
           dut.design_top_wrapper.tbl_slot==15 && !dut.design_top_wrapper.clr_active)clears=clears+1;
    task press(input integer which);
        begin
            @(negedge clk);dut.key_lock=0;
            if(which)key1=0;else key0=0;
            repeat(4)@(negedge clk);key0=1;key1=1;
            repeat(12)@(negedge clk);
        end
    endtask
    task back_to_menu;
        begin
            @(negedge clk);key0=0;
            // Accelerate only the elapsed-time counter, exercise terminal edge.
            dut.menu_hold_cnt=27'd99_999_999;
            repeat(5)@(negedge clk);key0=1;
            wait(!dut.video_owned);
            repeat(15)@(negedge clk);
            if(!dut.menu_ui || dut.img_idx!=0 || dut.menu_sel!=0)$fatal(1,"hold return");
        end
    endtask
    initial begin
        #200;rst_n=1;repeat(20)@(negedge clk);
        if(!dut.menu_ui || dut.menu_sel!=0 || dut.lba_rom[0]!=76032 ||
           dut.lba_rom[1]!=32672 || dut.lba_rom[8]!=70560)$fatal(1,"boot/menu image table");
        dut.sw_boot_cnt=27'd24_999_998;
        wait(dut.sw_real_valid);
        wait(!dut.design_top_wrapper.S_rst_pix);
        wait(!dut.design_top_wrapper.boot_wipe && !dut.design_top_wrapper.clr_active);
        repeat(20)@(negedge clk);
        if(writes==0 || !rows[0])$fatal(1,"bar not restored after boot wipe");
        for(i=1;i<=5;i=i+1)begin
            press(1);
            if(dut.menu_sel!=(i%5))$fatal(1,"five-row wrap");
        end
        if(rows!=5'b11111)$fatal(1,"not all coordinates reached: %b",rows);
        press(0);
        if(dut.menu_ui || dut.img_idx!=1 || dut.game_mode || !dut.menu_override || clears==0)$fatal(1,"photo confirm");
        back_to_menu();
        press(1);press(0);press(0);
        if(dut.cart_active || !dut.game_mode || dut.game_sel2!=0 || dut.menu_ui)$fatal(1,"game confirm ctx=%b sel=%d pat=%h override=%b game=%b cart=%b vs=%b",dut.menu_ui,dut.menu_sel,dut.menu_pattern,dut.menu_override,dut.game_mode,dut.cart_active,dut.video_requested);
        back_to_menu();
        press(1);press(1);press(0);
        if(!dut.video_requested || dut.menu_ui)$fatal(1,"video confirm");
        back_to_menu();
        press(1);press(1);press(1);press(0);
        if(!dut.music_on_w || dut.menu_ui)$fatal(1,"music confirm");
        back_to_menu();
        repeat(4)press(1);press(0);
        if(!dut.menu_ui || dut.menu_sel!=4)$fatal(1,"about placeholder");
        // DIP change must escape even while the key lock is active.
        wait(dut.sw_real_valid);
        @(negedge clk);sw=8'h6f;repeat(1000016)@(negedge clk);
        if(dut.menu_override || !dut.music_on_w)$fatal(1,"physical DIP escape");
        back_to_menu();
        press(1);press(1);press(0);
        force dut.video_failed=1'b1;
        repeat(5)@(negedge clk);
        if(!dut.menu_ui || dut.img_idx!=0)$fatal(1,"video fault return");
        release dut.video_failed;
        $display("D5_MENUCHK: PASS boot LBA, five rows/wrap, wipe repair, photo/hardware-breakout/video/music, about, hold return, DIP escape, video failure");
        $finish;
    end
    initial begin #200000000;$fatal(1,"menu timeout");end
endmodule

