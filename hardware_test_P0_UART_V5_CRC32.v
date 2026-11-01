`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// ?????? : ??? YingXu
// ?????? : hardware_test.v
// ?????? : hardware_test
// ???     : V0.4A-B BMP Header Probe + P0 UART
// ?????? : ?????? board_test ???????????????????????//            HDMI + SDRAM framebuffer + ??? + SW7 ????????????
//            TF/SD ?????Sector Reader??0.3 ?????????????//------------------------------------------------------------------------------
//
// ????????????????????//   - Ethernet / RGMII loopback + Ethernet PLL
//   - OV5640 / TFT ???
//   - U_aux_pll
//   - RTC / UART ?????//   - ?????Audio loopback
//   - IR / Beep / 7-seg / ??LED ???
//   - GPIO ??????
//
// design_top_wrapper ?????HDMI PLL??DRAM controller??????????// media source??SD/Overlay ???????????//------------------------------------------------------------------------------

module hardware_test #(
    parameter integer IMG_COUNT = 9,
    parameter integer SIM_FAST_BOOT = 0,
    parameter integer VIDEO_ACQUIRE_LIMIT = 250_000_000
)(
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire                             uart_rx,
    output wire                             uart_tx,

    // V0.4A-A??C201 ??? TF / MicroSD SPI ?????
    input  wire                             sd_miso,
    output wire                             sd_mosi,
    output wire                             sd_sclk,
    output wire                             sd_cs_n,

    input  wire                             I2S_DI,
    input  wire                             I2S_RCLK,
    input  wire                             I2S_BCLK,
    output wire                             I2S_DO,
    output wire                             I2S_MCLK,

    input  wire                             key_0,
    input  wire                             key_1,

    input  wire                             ir,

    output wire         [3:0]               led,
    output wire                             beep,

    input  wire         [7:0]               sw,

    output wire         [35:0]              gpio_40pin,

    output wire                             i2c_sclk,
    inout  wire                             i2c_sdat,

    input  wire                             eth_rxc,
    input  wire         [3:0]               eth_rxd,
    input  wire                             eth_rxdv,
    output wire                             eth_gtxc,
    output wire         [3:0]               eth_txd,
    output wire                             eth_txen,
    output wire                             eth_rst_n,
    inout  wire                             eth_mdc,
    inout  wire                             eth_mdio,

    output wire                             camera_sclk,
    inout  wire                             camera_sdat,
    input  wire                             camera_vsync,
    input  wire                             camera_href,
    input  wire                             camera_pclk,
    output wire                             camera_xclk,
    input  wire         [7:0]               camera_data,

    output wire         [15:0]              tft_rgb,
    output wire                             tft_hs,
    output wire                             tft_vs,
    output wire                             tft_clk,
    output wire                             tft_de,
    output wire                             tft_bl,

    output wire                             O_tmds_ch0_p,
    output wire                             O_tmds_ch1_p,
    output wire                             O_tmds_ch2_p,
    output wire                             O_tmds_clk_p,

    output wire                             seg7_sclk,
    output wire                             seg7_rclk,
    output wire                             seg7_dio
);

    // One bit per image: which indicator segments are valid.
    localparam [7:0] SEG_MASK = (IMG_COUNT >= 8) ? 8'hFF : (8'hFF >> (8 - IMG_COUNT));

    // D5: menu interaction layer (docs/D5_MENU_TASK.md). menu_override=1
    // replaces the DIP decode with menu_pattern (virtual switches). Boot
    // enters the menu; key1 cycles the selection, key0 confirms; a real DIP
    // change or a 2 s key0 hold in a mode returns to the menu.
    reg        menu_override;
    reg [7:0]  menu_pattern;
    reg [2:0]  menu_sel;
    reg [7:0]  sw_real_q;
    reg        sw_real_valid;
    wire [7:0] sw_eff = menu_override ? menu_pattern : sw;
    localparam [7:0] MENU_PAT_PHOTO = 8'hFF;   // SW7 OFF: photo / menu
    localparam [7:0] MENU_PAT_GAME  = 8'h1F;   // SW7/SW5/SW6 active-low: invaders cart
    localparam [7:0] MENU_PAT_VIDEO = 8'h77;   // SW7 ON + SW3 ON: video
    localparam [7:0] MENU_PAT_MUSIC = 8'h6F;   // SW7 ON + SW4 ON: music

    // SW7 selects the mode. The DIP switch reads inverted on this board, so
    // switch OFF (pin high) selects the game and ON selects the photo browser.
    wire switch_game_mode = ~sw_eff[7];
    reg video_photo_mode;
    wire game_mode = switch_game_mode && !video_requested && !video_owned && !video_photo_mode;
    reg [1:0] video_sw3;
    always @(posedge clk or negedge rst_n)begin if(!rst_n)video_sw3<=2'b11;else video_sw3<={video_sw3[0],sw_eff[3]};end
    // 77 is the demo entry; E7 remains a diagnostic compatibility entry.
    wire video_requested=!video_sw3[1] && sw5_s[1] && sw6_sync[1] &&
        ((switch_game_mode && !music_sw4) || (!switch_game_mode && music_sw4));
    wire video_handoff=video_requested && !video_failed && !video_owned;
    reg [1:0] video_quiesced;
    reg [3:0] video_base_q;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin video_quiesced<=0;video_photo_mode<=0;video_base_q<=0;end
        else begin
            video_quiesced<=video_handoff ? {video_quiesced[0],1'b1}:2'b00;
            video_base_q<={sw_eff[7],sw4_s[1],sw5_s[1],sw6_sync[1]};
            if(video_requested || video_base_q!={sw_eff[7],sw4_s[1],sw5_s[1],sw6_sync[1]})video_photo_mode<=0;
            if((video_owned && !video_requested)||(!video_failed_q && video_failed))video_photo_mode<=1;
        end
    end
    wire video_run_request=video_requested && (video_owned || video_failed || video_quiesced[1]);
    wire video_owned,video_failed,video_sd_start,video_sd_reset,video_sd_done;
    wire [27:0] video_sd_lba;wire [15:0] video_sd_sectors,video_sd_occupancy;
    wire [31:0] video_decoded,video_displayed,video_dropped,video_samples;wire [23:0] video_status;
    // D4c retained first-request evidence. Preserve raw SPI RSP until 4 bytes
    // actually arrive; D4xxxxxxxx then identifies the captured container magic.
    reg video_first_seen;reg [27:0] video_first_lba;reg [15:0] video_first_sectors;
    reg [31:0] video_first_bytes;reg [2:0] video_first_count;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin video_first_seen<=0;video_first_lba<=0;video_first_sectors<=0;video_first_bytes<=0;video_first_count<=0;end
        else if(!video_requested && !video_owned && !video_failed)begin
            video_first_seen<=0;video_first_count<=0;video_first_bytes<=0;
        end else begin
            if(video_sd_start && !video_first_seen)begin video_first_seen<=1;video_first_lba<=video_sd_lba;video_first_sectors<=video_sd_sectors;end
            if(video_first_seen && video_owned && video_first_count<4 && sd_bmp_sd_valid && sd_bmp_sd_ready)begin
                video_first_bytes<={video_first_bytes[23:0],sd_bmp_sd_data};video_first_count<=video_first_count+1'b1;
            end
        end
    end
    wire [15:0] video_diagnosis,video_detail;wire [10:0] video_fail_count;wire [9:0] video_fail_index;wire [31:0] video_fail_word;
    // D4e: expose the retained fault even while ownership cannot be released.
    wire video_diag_valid=video_failed || (|video_diagnosis[7:0]);
    reg video_owned_q,video_failed_q;reg video_photo_reload;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin video_owned_q<=0;video_failed_q<=0;video_photo_reload<=0;end
        else begin video_owned_q<=video_owned;video_failed_q<=video_failed;
            video_photo_reload<=((video_owned_q&&!video_owned)||(!video_failed_q&&video_failed));end
    end


    // G4b: DIP reads 0 when physically ON (same as SW7). Direct select:
    //   SW5 ON  -> cartridge (YX-8)
    //   SW5 OFF -> SW6 picks Invaders(ON)/Breakout(OFF)
    reg  [1:0] sw5_s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sw5_s <= 2'b00;
        else        sw5_s <= {sw5_s[0], sw_eff[5]};
    end
    reg  [1:0] sw4_s;
always @(posedge clk) begin
    if (!rst_n) sw4_s <= 2'b00;
    else        sw4_s <= {sw4_s[0], sw_eff[4]};
end
wire music_sw4 = ~sw4_s[1];                      // SW4 ON = 音乐
reg  [1:0] sw6_sync;   // G6: moved up (game_sel2/music_on_w both use it)
wire music_on_w = music_sw4 & game_mode;
// G6: 音乐使能统一用这一根：SW4 ON + 游戏模式 + SW5/SW6 均 OFF（纯音乐，不抢 SD）
wire [1:0] game_sel2 = ~sw5_s[1]   ? 2'd2 :
                           ~sw6_sync[1] ? 2'd1 : 2'd0;
    wire       cart_active = game_mode && (game_sel2 == 2'd2);
wire [27:0] wav_base_w;
wire        wav_restart_w;
wire [1:0]  wav_dbg_sstate_w;   // G6diag
wire [10:0] wav_dbg_occ_w;      // G6diag
wire        wav_dbg_wdog_w;     // G6diag
wire [15:0] wav_dbg_pops_w;     // G6diag
wire [15:0] wav_dbg_wcnt_w;     // G6diag
wire [10:0] wav_dbg_rptr_w;     // G6diag
wire [10:0] wav_dbg_wptr_w;     // G6diag
wire [15:0] wav_dbg_lastl_w;    // G6diag
wire [15:0] wav_dbg_outp_w;     // G6diag
wire [15:0] wav_dbg_byte_w;     // G6diag
wire [15:0] wav_dbg_rate_w;     // G6diag

    wire       cart_busy_w, cart_hb_w, cart_seen_w;
    wire [2:0] cart_lstate_w;
    wire [9:0] cart_wcnt_w;
    wire       cart_en_w;
    wire [15:0] spr_cnt_w;
    wire [3:0]  cart_flags_w;
    wire [9:0]  cart_pc_w;
    wire [15:0] cart_dwc_w;
    wire [23:0] cart_prog0_w;
    wire        cart_ready_w;
    wire [15:0] cart_retire_w;
    wire [23:0] cart_p18_w;
    wire [7:0]  cart_score_w;

    // G4: cartridge image lives at a FIXED high LBA, immune to photo-file churn.
    localparam [27:0] CART_LBA_A = 28'd1_000_000;   // SW6 OFF -> slot 1 (content set by write_cart)
    localparam [27:0] CART_LBA_B = 28'd1_001_000;   // SW6 ON  -> slot 2 (content set by write_cart)
    wire cart_restart_w;

    // Constant mask of valid indicator segments (one bit per image).
    // -------------------------------------------------------------------------
    // V0.3D-B active chain only.
    //
    // Keep the proven V0.3C-B-R1 control mapping:
    //   key_0 -> KEY0
    //   key_1 -> KEY1
    //   rst_n -> physical KEY2
    //   sw[7] -> framebuffer/direct-background selector
    // -------------------------------------------------------------------------
    // V0.4A-B: SD byte stream feeding the framebuffer display path.
    wire [7:0] sd_bmp_sd_data;
    wire       sd_bmp_sd_valid;
    wire       sd_bmp_sd_ready;
    wire       sd_bmp_start_pulse;

    wire        diag_fb_ready;
    wire        diag_fb_underflow;
    wire        diag_bmp_done;
    wire [19:0] diag_bmp_words;
    wire [4:0]  diag_cstate;
    wire        diag_wr_full;
    wire        diag_media_ready;
    wire        diag_wr2_full;
    wire        diag_rd2_empty;
    wire        pix_hb;

    // SD bring-up supervision state (declared before the wrapper so the
    // I_sd_fail port connection is legal).
    reg        sd_seen;
    reg        sd_fail;
    reg [30:0] sd_wait_cnt;     // 40 s threshold needs 31 bits
    reg [27:0] sd_retry_cnt;    // 5 s retry
    reg [26:0] sd_por_cnt;      // ~2 s quiet power-on delay for the card
    reg [ 3:0] sd_retry_pulse;


    // Segment pattern: image index normally, chaser while a picture loads.
    wire [7:0] seg_mask_final;

    // In Invaders the strip shows the wave (left 4) and remaining lives (right 3).
    wire [3:0] inv_wave;
    wire [1:0] inv_lives;
    wire [3:0] wave_nib = (inv_wave >= 4'd4) ? 4'b1111 :
                          (inv_wave == 4'd3) ? 4'b0111 :
                          (inv_wave == 4'd2) ? 4'b0011 :
                          (inv_wave == 4'd1) ? 4'b0001 : 4'b0000;
    wire [2:0] lives_nib = (inv_lives == 2'd3) ? 3'b111 :
                           (inv_lives == 2'd2) ? 3'b011 :
                           (inv_lives == 2'd1) ? 3'b001 : 3'b000;
    wire [7:0] invader_mask = {1'b0, lives_nib, wave_nib};

    design_top_wrapper #(.VIDEO_ACQUIRE_LIMIT(VIDEO_ACQUIRE_LIMIT)) design_top_wrapper (
        .I_video_pending(video_handoff),.I_video_mode(video_run_request),.I_video_sd_init(sd_dbg_init_done),.I_video_sd_busy(sd_dbg_busy),.I_video_sd_done(video_sd_done),
        .O_video_diagnosis(video_diagnosis),.O_video_detail(video_detail),.O_video_fail_count(video_fail_count),.O_video_fail_index(video_fail_index),.O_video_fail_word(video_fail_word),
        .O_video_owned(video_owned),.O_video_failed(video_failed),.O_video_sd_start(video_sd_start),.O_video_sd_reset(video_sd_reset),
        .O_video_sd_lba(video_sd_lba),.O_video_sd_sectors(video_sd_sectors),.O_video_decoded(video_decoded),.O_video_displayed(video_displayed),
        .O_video_dropped(video_dropped),.O_video_samples(video_samples),.O_video_sd_occupancy(video_sd_occupancy),.O_video_status(video_status),
        .I_wr_base(21'h100000),.I_rd_base(21'h100000),
        .I_sys_clk      (clk),

        .I_key_in       (1'b0),

        .I_key0_n       (key_0),
        .I_key1_n       (key_1),
        .I_key2_n       (rst_n),

        .I_bmp_sd_data  (sd_bmp_sd_data),
        .I_bmp_sd_valid (sd_bmp_sd_valid),
        .O_bmp_sd_ready (sd_bmp_sd_ready),
        .I_bmp_start    (video_handoff || video_owned ? 1'b0 : (sd_bmp_start_pulse | video_photo_reload)),
        .I_sd_fail      (sd_fail),
        .I_img_index    (img_index),
        .I_game_mode    (game_mode),
        .I_music_en     (music_on_w & ~cart_busy_w),
        .I_menu_ctx     (menu_ui),
        .I_menu_sel     (menu_sel),
        .O_wav_base     (wav_base_w),
        .O_wav_restart  (wav_restart_w),
        .O_wav_sstate   (wav_dbg_sstate_w),
        .O_wav_occ      (wav_dbg_occ_w),
        .O_wav_wdog     (wav_dbg_wdog_w),
        .O_wav_pops     (wav_dbg_pops_w),
        .O_wav_wdog_cnt (wav_dbg_wcnt_w),
        .O_wav_rptr     (wav_dbg_rptr_w),
        .O_wav_wptr     (wav_dbg_wptr_w),
        .O_wav_lastl    (wav_dbg_lastl_w),
        .O_wav_outp_cnt (wav_dbg_outp_w),
        .O_wav_byte_cnt (wav_dbg_byte_w),
        .O_wav_rate     (wav_dbg_rate_w),
        .I_game_sel     (game_sel2),
        .I_cart_swap    (cart_swap),
        .I_sd_ready     (sd_seen),
        .O_cart_restart (cart_restart_w),
        .O_cart_busy    (cart_busy_w),
        .O_cart_hb      (cart_hb_w),
        .O_cart_seen    (cart_seen_w),
        .O_cart_lstate  (cart_lstate_w),
        .O_cart_wcnt    (cart_wcnt_w),
        .O_cart_en      (cart_en_w),
        .O_spr_cnt      (spr_cnt_w),
        .O_cart_flags   (cart_flags_w),
        .O_cart_pc      (cart_pc_w),
        .O_cart_dwc     (cart_dwc_w),
        .O_cart_prog0   (cart_prog0_w),
        .I_cart_ready   (cart_ready_w),
        .I_cart_test    (~sw[0]),
        .O_cart_retire  (cart_retire_w),
        .O_cart_p18     (cart_p18_w),
        .O_cart_score   (cart_score_w),
        .I_fade_shift   (fade_shift_r),
        .O_inv_wave     (inv_wave),
        .O_inv_lives    (inv_lives),
        // The DIP switches read inverted on this board: physically OFF = pin high.
        .I_bright       (~sw[0]),
        .I_contrast     (~sw[1]),
        .I_seg_enable   (video_owned ? 8'd0:seg_mask_final),

        .O_dbg_fb_ready     (diag_fb_ready),
        .O_dbg_fb_underflow (diag_fb_underflow),
        .O_dbg_bmp_done     (diag_bmp_done),
        .O_dbg_bmp_words    (diag_bmp_words),
        .O_dbg_cstate       (diag_cstate),
        .O_dbg_wr_full      (diag_wr_full),
        .O_dbg_media_ready  (diag_media_ready),
        .O_dbg_wr2_full     (diag_wr2_full),
        .O_dbg_rd2_empty    (diag_rd2_empty),
        .O_dbg_pix_hb       (pix_hb),

        .I_i2s_BCLK     (1'b0),
        .I_i2s_LRCK     (1'b0),
        .I_i2s_DOUT     (1'b0),

        .O_tmds_ch0_p   (O_tmds_ch0_p),
        .O_tmds_ch1_p   (O_tmds_ch1_p),
        .O_tmds_ch2_p   (O_tmds_ch2_p),
        .O_tmds_clk_p   (O_tmds_clk_p)
    );

    // Constant mask of valid indicator segments (one bit per image).
    // -------------------------------------------------------------------------
    // V0.4A-A R1 Integration?????SD ??????????????    //
    // ?????    //   1) SW6 ?????0??    //   2) ??????????KEY2(rst_n) ??SD ?????????????????????
    //   3) LED0 ?????? SW6 ??0 ??? 1??    //   4) ?????? BMP ??? LBA 32672 ?????Sector??? 512 Byte????????? 54 Byte Header??    //
    // ChipWatcher ?????? sd_dbg_* ?????    // -------------------------------------------------------------------------
    wire        sd_dbg_init_done;
    wire        sd_dbg_busy;
    wire        sd_dbg_done_latched;
    wire        sd_dbg_error_latched;
    wire [21:0] sd_dbg_accept_count;
    wire [7:0]  sd_dbg_byte_510;
    wire [7:0]  sd_dbg_byte_511;
    wire [7:0]  sd_dbg_byte_512;
    wire [7:0]  sd_dbg_byte_513;
    wire [7:0]  sd_dbg_stream_data;
    wire        sd_dbg_stream_valid;
    wire [31:0] sd_dbg_stream_offset;
    wire [27:0] sd_dbg_stream_sector;
    wire [8:0]  sd_dbg_stream_sector_byte;
    wire        sd_dbg_bmp_header_valid;
    wire        sd_dbg_bmp_header_done_latched;
    wire        sd_dbg_bmp_format_ok;
    wire [31:0] sd_dbg_bmp_width;
    wire [31:0] sd_dbg_bmp_height;
    wire [15:0] sd_dbg_bmp_bpp;
    wire [31:0] sd_dbg_bmp_pixel_offset;

    // Low-level SPI/init state debug taps. Keep them top-level and marked so
    // ChipWatcher can select them without relying on hidden internal paths.
    wire        sd_dbg_spi_clk;
    wire [5:0]  sd_dbg_spi_div_value;
    wire [5:0]  sd_dbg_spi_div_counter;
    wire [2:0]  sd_dbg_ctrl_state;
    wire [1:0]  sd_dbg_select_num;
    wire        sd_dbg_spi_start;
    wire        sd_dbg_spi_next;
    wire        sd_dbg_spi_done;
    wire [3:0]  sd_dbg_init_state;
    wire [39:0] sd_dbg_init_response;
    wire        sd_dbg_spi_driver_state;
    wire [3:0]  sd_dbg_spi_driver_count;
    wire [2:0] sd_dbg_read_state;
    wire [7:0] sd_dbg_read_spi_rec_data;
    wire       sd_dbg_read_addr_done_seen;
    wire       sd_dbg_read_data_done_seen;

    // V0.4A-B: start the BMP streamer once SD initialization completes, so the
    // first frame begins as soon as the card is ready.
    reg bmp_start_seen;
    reg bmp_start_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bmp_start_seen <= 1'b0;
            bmp_start_d    <= 1'b0;
        end
        else begin
            bmp_start_seen <= sd_dbg_init_done;
            bmp_start_d    <= bmp_start_seen;
        end
    end
    // ------------------------------------------------------------------
    // Image table + KEY0/KEY1 switching.
    // LBAs are fixed by the FAT layout on the card; do not reorder files.
    // ------------------------------------------------------------------
    // ------------------------------------------------------------------
    // Image table. Keep in sync with tools\prep_images.ps1 output.
    // ------------------------------------------------------------------
    reg [27:0] lba_rom [0:8];

    initial begin
        lba_rom[0] = 28'd76032;   // D5 menu background
        lba_rom[1] = 28'd32672;   // img1_ramen.bmp
        lba_rom[2] = 28'd38080;   // img2_sushi.bmp
        lba_rom[3] = 28'd43488;   // img3_cake.bmp
        lba_rom[4] = 28'd48896;   // img4_bars.bmp
        lba_rom[5] = 28'd54304;   // img5.bmp
        lba_rom[6] = 28'd59744;   // img6.bmp
        lba_rom[7] = 28'd65152;   // img7.bmp
        lba_rom[8] = 28'd70560;   // img8.bmp
    end

    // D5: 2 s key0 hold returns from every mode, including video.
    reg [26:0] menu_hold_cnt;
    wire       menu_hold_2s = (menu_hold_cnt == 27'd100_000_000);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) menu_hold_cnt <= 27'd0;
        else if (!key_0 && !menu_ui) begin
            if (menu_hold_cnt == 27'd100_000_000) menu_hold_cnt <= 27'd0;
            else menu_hold_cnt <= menu_hold_cnt + 27'd1;
        end else menu_hold_cnt <= 27'd0;
    end
    wire menu_ui = menu_override && (menu_pattern == MENU_PAT_PHOTO) && (img_idx == 4'd0);
    wire menu_real_change = menu_override && sw_real_valid && (sw_real_q != sw);

    // ------------------------------------------------------------------
    // Key handling: edge detect + short lockout (the validated baseline).
    // ------------------------------------------------------------------
    reg [27:0] img_lba;
    reg [3:0]  img_idx;
    reg        img_restart;
    reg [3:0]  load_idx;        // index whose data is being loaded / on screen
    reg        tr_busy;          // high while a fade/load transition is running
    reg [3:0]  img_index;
    reg        key0_p, key1_p;
    reg [23:0] key_lock;        // 330 ms lockout: one press = one step

    // Auto carousel: one image every 5 s in photo mode. Any key press resets
    // the timer, so manual browsing never fights the automatic advance.
    localparam [27:0] CAROUSEL_MAX = 28'd250_000_000;   // 5 s at 50 MHz
    reg [27:0] carousel_cnt;
        reg        sw6_p;


    // G4d: SW6 picks the cartridge image while SW5 selects cart mode.
    // Declared here (after sw6_sync) so no use-before-declaration ambiguity.
    wire [27:0] cart_lba_sel = ~sw6_sync[1] ? 28'd1_000_000 : 28'd1_001_000;
    reg         sw6_sel_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sw6_sel_q <= 1'b0;
        else        sw6_sel_q <= ~sw6_sync[1];
    end
    wire cart_swap = cart_active & (sw6_sel_q ^ (~sw6_sync[1]));

    // Only a real request may re-arm the loader. An earlier version also started
    // it on a completion edge, producing a spurious loader reset (black flash)
    // with no new read behind it. init_done is sticky until an SD subsystem
    // reset; reader_done is the per-read completion, not initialization.
    // The loader is started by the transition FSM after the fade-out, not
    // directly by the key press.
    assign sd_bmp_start_pulse = load_start;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            menu_override <= 1'b1;
            menu_pattern <= MENU_PAT_PHOTO;
            menu_sel <= 3'd0;
            sw_real_q <= 8'hFF;sw_real_valid <= 1'b0;
            img_idx     <= 4'd0;
            img_restart <= 1'b0;
            key0_p      <= 1'b1;
            key1_p      <= 1'b1;
            key_lock    <= 24'd0;
            carousel_cnt<= 28'd0;
            sw6_sync    <= 2'b00;
            sw6_p       <= 1'b0;
        end
        else begin
            key0_p      <= key_0;
            key1_p      <= key_1;
            sw_real_q <= sw;sw_real_valid <= 1'b1;
            sw6_sync    <= {sw6_sync[0], sw_eff[6]};
            sw6_p       <= sw6_sync[1];
            img_restart <= 1'b0;

            if (key_lock != 24'd0)
                key_lock <= key_lock - 24'd1;

            // SW6: reload the current image (must also re-arm the loader).
            if (menu_real_change) begin
                menu_override <= 1'b0; img_idx <= 4'd0;
            end
            else if ((menu_override && !menu_ui && menu_hold_2s) ||
                     (menu_override && !video_failed_q && video_failed) ||
                     (!menu_override && menu_hold_2s)) begin
                menu_override <= 1'b1; menu_pattern <= MENU_PAT_PHOTO;
                menu_sel <= 3'd0; img_idx <= 4'd0; img_restart <= 1'b1;
                key_lock <= 24'hFFFFFF;
            end
            else if (!game_mode && !video_requested && !video_owned && !menu_ui && key_lock == 24'd0 && (sw6_sync[1] ^ sw6_p)) begin
                key_lock    <= 24'hFFFFFF;
                img_restart <= 1'b1;
            end
            else if (!game_mode && !video_requested && !video_owned && !menu_ui && key_lock == 24'd0 && key1_p && !key_1) begin
                key_lock    <= 24'hFFFFFF;
                img_idx     <= (img_idx == IMG_COUNT - 1) ? 4'd0 : (img_idx + 4'd1);
                img_restart <= 1'b1;
            end
            else if (!game_mode && !video_requested && !video_owned && !menu_ui && key_lock == 24'd0 && key0_p && !key_0) begin
                key_lock    <= 24'hFFFFFF;
                img_idx     <= (img_idx == 4'd0) ? (IMG_COUNT - 1) : (img_idx - 4'd1);
                img_restart <= 1'b1;
            end
            // Auto carousel: advance when the timer expires and nothing else is
            // holding the loader.
            else if (!game_mode && !video_requested && !video_owned && !menu_ui && key_lock == 24'd0 && !sd_dbg_busy &&
                     carousel_cnt == CAROUSEL_MAX) begin
                key_lock    <= 24'hFFFFFF;
                img_idx     <= (img_idx == IMG_COUNT - 1) ? 4'd0 : (img_idx + 4'd1);
                img_restart <= 1'b1;
            end
            // D5 menu: key1 cycles the selection, key0 confirms. The photo
            // browse/carousel branches above are gated off while menu_ui is set.
            else if (menu_override && menu_ui &&
                     key_lock == 24'd0 && key1_p && !key_1) begin
                key_lock <= 24'hFFFFFF;
                menu_sel <= (menu_sel == 3'd4) ? 3'd0 : menu_sel + 3'd1;
            end
            else if (menu_override && menu_ui &&
                     key_lock == 24'd0 && key0_p && !key_0) begin
                key_lock <= 24'hFFFFFF;
                case (menu_sel)
                    3'd1: menu_pattern <= MENU_PAT_GAME;
                    3'd2: menu_pattern <= MENU_PAT_VIDEO;
                    3'd3: menu_pattern <= MENU_PAT_MUSIC;
                    3'd0: begin img_idx <= 4'd1; img_restart <= 1'b1; end
                    default: ;                       // 关于: v2
                endcase
            end

            // The timer only runs while idle in photo mode; every key press (which
            // sets key_lock) or a load in progress clears it.
            if (!game_mode && !video_requested && !video_owned && !menu_ui && key_lock == 24'd0 && !sd_dbg_busy)
                carousel_cnt <= carousel_cnt + 28'd1;
            else
                carousel_cnt <= 28'd0;
        end
    end
    always @(*) begin
        img_lba   = lba_rom[load_idx];
        img_index = load_idx + 4'd1;
    end

    // ------------------------------------------------------------------
    // Loader stall watchdog.
    //
    // A single failed read used to leave the stream reader permanently busy:
    // every later key press was then ignored because the start condition
    // requires ~busy. If a read stays busy for 20 s, force the SD subsystem
    // through a reset so the next key press can start a fresh load.
    reg [29:0] busy_cnt;
    reg [ 3:0] busy_kill;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_cnt  <= 30'd0;
            busy_kill <= 4'd0;
        end
        else if (busy_kill != 4'd0) begin
            busy_kill <= busy_kill - 4'd1;
        end
        else if (sd_dbg_busy) begin
            if (busy_cnt == 30'd1_000_000_000) begin
                busy_cnt  <= 30'd0;
                busy_kill <= 4'd8;
            end
            else
                busy_cnt <= busy_cnt + 30'd1;
        end
        else begin
            busy_cnt <= 30'd0;
        end
    end
    // -------------------------------------------------------------------------
    // Fade transition around every image load.
    //
    // The old behaviour cut to black for the ~4 s the load takes. Now the picture
    // fades out (shift 0..8), the load runs while the screen is dark, and the new
    // picture fades back in. Ten steps are enough to read as a fade and cost only
    // a shift mux in the player.
    // -------------------------------------------------------------------------
    localparam [1:0] TR_IDLE = 2'd0, TR_OUT = 2'd1, TR_LOAD = 2'd2, TR_IN = 2'd3;

    reg [1:0]  tr_state;
    reg [3:0]  fade_shift_r;
    reg [19:0] tr_ms;          // 1 ms tick at 50 MHz
    reg [5:0]  tr_div;         // 40 ms step divider
    reg [12:0] tr_wait;        // up to 8 s
    reg        tr_busy_seen;
    reg        load_start;     // to the stream reader

    wire tr_step = (tr_ms == 20'd49_999) && (tr_div == 6'd24);   // 25 ms per fade step

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || video_requested || video_owned) begin
            // D5boot: reset to 15 so img_idx(0) != load_idx triggers the first
            // load at power-on. Menu mode gates the carousel, so nothing else
            // would ever start the initial menu background load.
            load_idx     <= 4'd15;
            tr_state     <= TR_IDLE;
            fade_shift_r <= 4'd0;
            tr_ms        <= 20'd0;
            tr_div       <= 6'd0;
            tr_wait      <= 13'd0;
            tr_busy_seen <= 1'b0;
            load_start   <= 1'b0;
            tr_busy      <= 1'b0;
        end
        else begin
            load_start <= 1'b0;

            // 1 ms tick, then a 40 ms step tick
            if (tr_ms == 20'd49_999) begin
                tr_ms  <= 20'd0;
                tr_div <= (tr_div == 6'd24) ? 6'd0 : (tr_div + 6'd1);
            end
            else begin
                tr_ms <= tr_ms + 20'd1;
            end

            tr_busy <= (tr_state != TR_IDLE);

            case (tr_state)
                TR_IDLE: begin
                    fade_shift_r <= 4'd0;
                    // Also catches a key press that arrived mid-transition: the
                    // key handler already moved img_idx, so index inequality is the
                    // complete trigger (img_restart must NOT be driven here 鈥� it is
                    // owned by the key-handler block; HDL-8007 otherwise).
                    // Gated by photo mode: in cart mode the carousel must never
                    // auto-trigger and the BMP loader would swallow the cart stream.
                    if (!game_mode && (img_idx != load_idx)) begin
                        load_idx <= img_idx;
                        tr_state <= TR_OUT;
                    end
                end
                // fade to black, one step every 40 ms
                TR_OUT: begin
                    if (tr_step) begin
                        if (fade_shift_r == 4'd15) begin
                            load_start   <= 1'b1;
                            tr_state     <= TR_LOAD;
                            tr_wait      <= 13'd0;
                            tr_busy_seen <= 1'b0;
                        end
                        else
                            fade_shift_r <= fade_shift_r + 4'd1;
                    end
                end
                // wait for the load: busy must rise then fall, 8 s cap
                TR_LOAD: begin
                    if (sd_dbg_busy) tr_busy_seen <= 1'b1;
                    if (tr_step) tr_wait <= tr_wait + 13'd1;
                    if ((tr_busy_seen && !sd_dbg_busy) || tr_wait == 13'd200)
                        tr_state <= TR_IN;
                end
                // fade back in
                TR_IN: begin
                    if (tr_step) begin
                        if (fade_shift_r == 4'd0)
                            tr_state <= TR_IDLE;
                        else
                            fade_shift_r <= fade_shift_r - 4'd1;
                    end
                end
                default: tr_state <= TR_IDLE;
            endcase
        end
    end
    // While a picture is loading the screen is black, so the segment strip doubles
    // as a progress indicator: one segment runs left and right. When idle it goes
    // back to showing which image is on screen.
    reg [3:0] chase_pos;
    reg       chase_dir;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chase_pos <= 4'd0;
            chase_dir <= 1'b1;
        end
        else if (sd_dbg_busy) begin
            if (frame_pulse_seg) begin
                if (chase_dir) begin
                    if (chase_pos >= IMG_COUNT - 1) begin chase_dir <= 1'b0; chase_pos <= chase_pos - 4'd1; end
                    else chase_pos <= chase_pos + 4'd1;
                end
                else begin
                    if (chase_pos == 4'd0) begin chase_dir <= 1'b1; chase_pos <= 4'd1; end
                    else chase_pos <= chase_pos - 4'd1;
                end
            end
        end
        else begin
            chase_pos <= 4'd0;
            chase_dir <= 1'b1;
        end
    end

    // ~8 Hz chaser tick
    reg [23:0] chase_div;
    reg        frame_pulse_seg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chase_div       <= 24'd0;
            frame_pulse_seg <= 1'b0;
        end
        else if (chase_div == 24'd12_500_000) begin   // 250 ms per step
            chase_div       <= 24'd0;
            frame_pulse_seg <= 1'b1;
        end
        else begin
            chase_div       <= chase_div + 24'd1;
            frame_pulse_seg <= 1'b0;
        end
    end
    // Parameter overlay: when the brightness/contrast switches change, the
    // segment strip shows the level for 3 s instead of the image counter.
    reg [4:0]  sw_d;
    reg [26:0] info_timer;
    wire       sw_changed = (sw_d != ~sw[1:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_d       <= 5'd0;
            info_timer <= 27'd0;
        end
        else begin
            sw_d <= ~sw[1:0];
            if (sw_changed)
                info_timer <= 27'd120_000_000;   // 2.4 s at 50 MHz
            else if (info_timer != 27'd0)
                info_timer <= info_timer - 27'd1;
        end
    end

    // bar = (1 << (bright+1)) - 1, i.e. one segment per brightness step
    // two segments: bit 0 = brightness on, bit 1 = contrast on
    wire [7:0] bright_bar = {6'b000000, ~sw[1], ~sw[0]};
    assign seg_mask_final = (info_timer != 27'd0) ? bright_bar :
                                   sd_dbg_busy ? (8'h01 << chase_pos) :
                                   (game_mode && game_sel2 == 2'd1) ? invader_mask :
                                   SEG_MASK;

    // SD bring-up supervision.
    //
    // sd_stream_reader_core sets init_done once after power-on init and
    // preserves it across reads. Probe DNE is a separate per-read done latch,
    // cleared on reader_start. Both watchdogs below therefore:
    //   * are permanently disabled once a successful init has been seen
    //     (sd_seen is sticky),
    //   * never run while the SD core is busy,
    //   * only retry / warn before the first success.
    // ------------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_seen     <= 1'b0;
            sd_fail     <= 1'b0;
            sd_wait_cnt <= 31'd0;
        end
        else begin
            if (sd_dbg_init_done)
                sd_seen <= 1'b1;

            if (sd_seen) begin
                sd_wait_cnt <= 31'd0;
                sd_fail     <= 1'b0;
            end
            else if (sd_wait_cnt == 31'd2_000_000_000) begin
                sd_fail     <= 1'b1;           // 15 s and never came up
            end
            else begin
                sd_wait_cnt <= sd_wait_cnt + 31'd1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_retry_cnt   <= 28'd0;
            sd_retry_pulse <= 4'd0;
        end
        else if (sd_seen) begin
            sd_retry_cnt   <= 28'd0;
            sd_retry_pulse <= 4'd0;
        end
        else if (sd_retry_pulse != 4'd0) begin
            sd_retry_pulse <= sd_retry_pulse - 4'd1;
        end
        else if (sd_retry_cnt == 28'd250_000_000) begin
            sd_retry_cnt   <= 28'd0;
            sd_retry_pulse <= 4'd8;            // 15 s idle-or-stuck -> restart init
        end
        else begin
            sd_retry_cnt <= sd_retry_cnt + 28'd1;
        end
    end
    // The card needs >1 ms after VDD is stable before the first clock, and the
    // FPGA comes out of configuration much sooner than that. Holding the SD
    // subsystem in reset for ~335 ms costs nothing and removes a whole class of
    // "card never answers CMD0" failures.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                       sd_por_cnt <= 27'd0;
        else if (sd_por_cnt != (SIM_FAST_BOOT ? 27'd1000:27'd100_000_000)) sd_por_cnt <= sd_por_cnt + 27'd1;
    end

    // ------------------------------------------------------------------
    // Pre-init flush.
    //
    // A card interrupted in the middle of a data block keeps driving MISO low
    // and ignores CMD0 until it has clocked the rest of the block out. The
    // vendor init sends only one dummy byte, which is far too short (a block is
    // 4096 clocks). Holding CS high and clocking 8192 times before init puts
    // the card back in idle, which is the recovery sequence from the SD spec.
    // Runs on every retry as well.
    // ------------------------------------------------------------------
    wire por_done = (sd_por_cnt == (SIM_FAST_BOOT ? 27'd1000:27'd100_000_000));

    localparam [7:0]  FLUSH_HALF  = 8'd125;      // ~400 kHz at 50 MHz
    localparam [15:0] FLUSH_CLKS  = 16'd65536;   // 160 ms of clocks, enough to force any state out

    reg [ 7:0] flush_half;
    reg [15:0] flush_clks;
    reg        flush_clk;
    reg        flush_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_half   <= 8'd0;
            flush_clks   <= 16'd0;
            flush_clk    <= 1'b0;
            flush_active <= 1'b1;
        end
        // Stay silent until the card has settled after FPGA configuration.
        // The flush must run AFTER this delay: firing it during power-up
        // (the original behaviour) achieved nothing, and the 2 s that
        // followed had no clocks at all.
        else if (!por_done) begin
            flush_half   <= 8'd0;
            flush_clks   <= 16'd0;
            flush_clk    <= 1'b0;
            flush_active <= 1'b1;
        end
        else if (sd_retry_pulse != 4'd0) begin
            flush_half   <= 8'd0;
            flush_clks   <= 16'd0;
            flush_active <= 1'b1;                 // re-flush on every retry
        end
        else if (flush_active) begin
            if (flush_half == FLUSH_HALF - 8'd1) begin
                flush_half <= 8'd0;
                flush_clk  <= ~flush_clk;
                if (flush_clk) begin
                    if (flush_clks == (SIM_FAST_BOOT ? 16'd63:FLUSH_CLKS - 16'd1))
                        flush_active <= 1'b0;
                    else
                        flush_clks <= flush_clks + 16'd1;
                end
            end
            else begin
                flush_half <= flush_half + 8'd1;
            end
        end
    end


    wire sd_rst = video_sd_reset | ~rst_n | !por_done | flush_active | (sd_retry_pulse != 4'd0) |
                  (busy_kill != 4'd0);

    // While the flush runs the card must see CS high and a clean clock, so the
    // pad drivers are taken over from the SD subsystem for those ~40 ms.
    wire sd_mosi_p, sd_sclk_p, sd_cs_n_p;

    assign sd_mosi = flush_active ? 1'b1      : sd_mosi_p;
    assign sd_sclk = flush_active ? flush_clk : sd_sclk_p;
    assign sd_cs_n = flush_active ? 1'b1      : sd_cs_n_p;

    // Constant mask of valid indicator segments (one bit per image).
    yingxu_sd_integration_probe #(.CLOCK_FREQ(50_000_000), .DYNAMIC_COUNT(1), .SECTOR_COUNT(16'd5401)) U_SD_INTEGRATION (
        .clk                       (clk),
        .rst                       (sd_rst),
        .legacy_inhibit(video_handoff),.dynamic_enable(video_owned),.dynamic_count(video_sd_sectors),.transaction_done(video_sd_done),
        .trigger_sw                (1'b0),   // SW6 is handled in the top now
        .start_sector              (video_owned ? video_sd_lba : cart_busy_w ? cart_lba_sel :
                             music_on_w ? wav_base_w : img_lba),
        .restart                   (video_owned ? video_sd_start : (video_requested && !video_failed) ? 1'b0 : (load_start | video_photo_reload | cart_restart_w | cart_swap | wav_restart_w)),
        .out_stream_data           (sd_bmp_sd_data),
        .out_stream_valid          (sd_bmp_sd_valid),
        .out_stream_ready          (sd_bmp_sd_ready),
        .sd_miso                   (sd_miso),
        .sd_mosi                   (sd_mosi_p),
        .sd_sclk                   (sd_sclk_p),
        .sd_cs_n                   (sd_cs_n_p),
        .dbg_init_done             (sd_dbg_init_done),
        .dbg_busy                  (sd_dbg_busy),
        .dbg_done_latched          (sd_dbg_done_latched),
        .dbg_error_latched         (sd_dbg_error_latched),
        .dbg_accept_count          (sd_dbg_accept_count),
        .dbg_byte_510              (sd_dbg_byte_510),
        .dbg_byte_511              (sd_dbg_byte_511),
        .dbg_byte_512              (sd_dbg_byte_512),
        .dbg_byte_513              (sd_dbg_byte_513),
        .dbg_stream_data           (sd_dbg_stream_data),
        .dbg_stream_valid          (sd_dbg_stream_valid),
        .dbg_stream_offset         (sd_dbg_stream_offset),
        .dbg_stream_sector         (sd_dbg_stream_sector),
        .dbg_stream_sector_byte    (sd_dbg_stream_sector_byte),
        .dbg_bmp_header_valid      (sd_dbg_bmp_header_valid),
        .dbg_bmp_header_done_latched(sd_dbg_bmp_header_done_latched),
        .dbg_bmp_format_ok         (sd_dbg_bmp_format_ok),
        .dbg_bmp_width             (sd_dbg_bmp_width),
        .dbg_bmp_height            (sd_dbg_bmp_height),
        .dbg_bmp_bpp               (sd_dbg_bmp_bpp),
        .dbg_bmp_pixel_offset      (sd_dbg_bmp_pixel_offset),
        .dbg_spi_clk               (sd_dbg_spi_clk),
        .dbg_spi_div_value         (sd_dbg_spi_div_value),
        .dbg_spi_div_counter       (sd_dbg_spi_div_counter),
        .dbg_ctrl_state            (sd_dbg_ctrl_state),
        .dbg_select_num            (sd_dbg_select_num),
        .dbg_spi_start             (sd_dbg_spi_start),
        .dbg_spi_next              (sd_dbg_spi_next),
        .dbg_spi_done              (sd_dbg_spi_done),
        .dbg_init_state            (sd_dbg_init_state),
        .dbg_init_response          (sd_dbg_init_response),
        .dbg_spi_driver_state      (sd_dbg_spi_driver_state),
        .dbg_spi_driver_count      (sd_dbg_spi_driver_count),
        .dbg_read_state            (sd_dbg_read_state),
        .dbg_read_spi_rec_data     (sd_dbg_read_spi_rec_data),
        .dbg_addr_done_seen        (sd_dbg_read_addr_done_seen),
        .dbg_data_done_seen        (sd_dbg_read_data_done_seen)
    );

    // Constant mask of valid indicator segments (one bit per image).
    // -------------------------------------------------------------------------
    // Safe inactive states for removed board-test subsystems.
    // The ports remain only so the existing IO.adc can stay unchanged.
    // -------------------------------------------------------------------------
    // P0 (2026-10-25): the UART status-line telemetry and CRC-32 probe were
    // disabled here long ago (uart_tx tied high), but the whole machine kept
    // living in the source. It is deleted now; sd_dbg_init_done / sd_dbg_busy
    // remain in use by the watchdogs and the photo-carousel timer.
    // Cart path observability counters (reported via telemetry MISE/SCE fields):
    //   MISE = cart_restart_w pulse count (0 => cart never armed the read)
    //   SCE  = cart_busy_w rising edges   (1 => cart module alive, en=1, not loaded)
    reg [15:0] cart_rst_cnt;
    reg [15:0] gate_cnt;
    reg        busy_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cart_rst_cnt <= 16'd0;
            gate_cnt     <= 16'd0;
            busy_d       <= 1'b0;
        end
        else begin
            busy_d <= cart_busy_w;
            if (cart_restart_w)          cart_rst_cnt <= cart_rst_cnt + 16'd1;
            if (cart_busy_w & ~busy_d)   gate_cnt     <= gate_cnt     + 16'd1;
        end
    end

    // TEMP DIAGNOSTIC TELEMETRY (2026-10-26 SD bring-up): REMOVED 2026-10-26 鈥�
    // SD init + full multi-sector read verified on board (build6/7, seeds 29/36).
    // RE-ADDED 2026-10-26: cart-mode loader stall diagnosis. Remove after G4 closes.
// G6diag: music mode -> telemetry carries wav internals instead of cart debug
wire [9:0]  t_pc  = (video_requested || video_owned || video_failed) ? (video_displayed[9:0]-10'd1) : music_on_w ? wav_dbg_rptr_w[9:0] : cart_pc_w;
wire [15:0] t_dwc = (video_requested || video_owned || video_failed) ? video_dropped[15:0] : music_on_w ? wav_dbg_pops_w    : cart_dwc_w;
wire [23:0] t_p0  = (video_requested || video_owned || video_failed) ? video_status : music_on_w ? {wav_dbg_sstate_w, wav_dbg_occ_w, wav_dbg_wptr_w}
                                : cart_prog0_w;
wire [15:0] t_rc  = (video_requested || video_owned || video_failed) ? video_displayed[15:0] : music_on_w ? wav_dbg_wcnt_w    : cart_retire_w;
wire [23:0] t_p18 = (video_requested || video_owned || video_failed) ? (video_diag_valid ? video_fail_word[23:0]:video_samples[23:0]) : music_on_w ? {8'd0, wav_dbg_lastl_w} : cart_p18_w;
wire [15:0] t_mise = (video_requested || video_owned || video_failed) ? (video_diag_valid ? video_diagnosis:video_decoded[15:0]) : music_on_w ? wav_dbg_outp_w : cart_rst_cnt;
wire [15:0] t_sce  = (video_requested || video_owned || video_failed) ? video_sd_occupancy : music_on_w ? wav_dbg_byte_w : gate_cnt;
wire [15:0] t_sprc = (video_requested || video_owned || video_failed) ? (video_diag_valid ? video_detail:16'd48000) : music_on_w ? wav_dbg_rate_w : spr_cnt_w;

    yx8_uart_telem U_TELEM (
        .i_clk   (clk),
        .i_rst_n (rst_n),
        .i_seen  (sd_seen),
        .i_busy  (sd_dbg_busy),
        .i_err   ((video_requested || video_owned || video_failed) ? video_failed:sd_dbg_error_latched),
        .i_dne   (sd_dbg_done_latched),
        .i_por   (por_done),
        .i_flu   (flush_active),
        .i_kil   (busy_kill),
        .i_ret   (sd_retry_pulse),
        .i_wft   (sd_fail),
        .i_gm    (game_mode),
        .i_ca    (cart_active),
        .i_sw    (sw),
        .i_ls    ((video_requested || video_owned || video_failed) ? {sd_rst,video_sd_reset,sd_dbg_init_done}:cart_lstate_w),
        .i_wc    ((video_requested || video_owned || video_failed) ? (video_diag_valid ? video_fail_index:video_first_sectors[9:0]):menu_ui ? {6'd0,menu_override,menu_sel}:cart_wcnt_w),
        .i_cbu   (cart_busy_w),
        .i_sprc  (t_sprc),
        .i_cfl   ((video_requested || video_owned || video_failed) ? {video_owned,sd_dbg_init_done,sd_dbg_busy,video_handoff}:cart_flags_w),
        .i_pc    (t_pc),
        .i_dwc   (t_dwc),
        .i_p0    (t_p0),
        .i_rc    (t_rc),
        .i_p18   (t_p18),
        .i_ctrl  (sd_dbg_ctrl_state),
        .i_init  (sd_dbg_init_state),
        .i_rsp   (video_first_count==4 ? {8'hD4,video_first_bytes}:sd_dbg_init_response),
        .i_rd    (sd_dbg_read_state),
        .i_rdt   (video_diag_valid ? video_fail_word[31:24]:sd_dbg_read_spi_rec_data),
        .i_div   (sd_dbg_spi_div_value),
        .i_spik  (sd_dbg_spi_clk),
        .i_cnt   (sd_dbg_spi_driver_count),
        .i_sel   (sd_dbg_select_num),
        .i_ads   (sd_dbg_read_addr_done_seen),
        .i_dds   (sd_dbg_read_data_done_seen),
        .i_csn   (sd_cs_n_p),
        .i_mos   (sd_mosi_p),
        .i_sck   (sd_sclk_p),
        .i_miso  (sd_miso),
        .i_acc   (video_diag_valid ? video_fail_count:sd_dbg_accept_count[10:0]),
        .i_mise  (t_mise),
        .i_sce   (t_sce),
        .i_off   (video_first_seen ? {4'hD,video_first_lba}:sd_dbg_stream_offset),
        .i_vld   (sd_dbg_stream_valid),
        .i_w2f   (diag_wr2_full),
        .i_r2e   (diag_rd2_empty),
        .i_hb    (pix_hb),
        .i_sst_p (sd_dbg_spi_start),
        .i_snx_p (sd_dbg_spi_next),
        .i_sdn_p (sd_dbg_spi_done),
        .o_tx    (uart_tx)
    );

    assign I2S_DO   = 1'b0;
    assign I2S_MCLK = 1'b0;

    // Board LEDs are active-low. V0.4A-A integration status:
    //   LED0: SD init_done
    //   LED1: reader busy
    //   LED2: 512 Byte BMP-header-sector transaction done (latched)
    //   LED3: integration error (latched; normally off)
    // DIAG: SDRAM scratch-port health, lit = the condition is TRUE.
    //   LED0 = SD init_done
    //   LED1 = WR2 write FIFO FULL   (bad: loader writes are backing up)
    //   LED2 = RD2 read FIFO EMPTY   (no playback data available)
    //   LED3 = frame fully written to SDRAM (460800 words counted)
    // G4: ????? LED1/LED3 ??????/CPU ????????????
    // LEDs are active-low on this board, so ~value makes "bit set = lit"
    // G6diag: music-mode LEDs = {watchdog, S_PLAY, fifo_has_data, music_active}
    assign led[3:0] = cart_active ? ~cart_score_w[3:0] :
                      music_on_w   ? ~{wav_dbg_wdog_w, (wav_dbg_sstate_w == 2'd1),
                                       (wav_dbg_occ_w != 11'd0), music_on_w} :
                                     {cart_hb_w, diag_rd2_empty, diag_wr2_full, ~sd_seen};
    assign beep   = 1'b0;

    assign gpio_40pin = 36'd0;

    assign i2c_sclk = 1'b1;
    assign i2c_sdat = 1'bz;

    // Hold Ethernet PHY in reset.
    assign eth_gtxc  = 1'b0;
    assign eth_txd   = 4'd0;
    assign eth_txen  = 1'b0;
    assign eth_rst_n = 1'b0;
    assign eth_mdc   = 1'bz;
    assign eth_mdio  = 1'bz;

    assign camera_sclk = 1'b1;
    assign camera_sdat = 1'bz;
    assign camera_xclk = 1'b0;

    assign tft_rgb = 16'd0;
    assign tft_hs  = 1'b0;
    assign tft_vs  = 1'b0;
    assign tft_clk = 1'b0;
    assign tft_de  = 1'b0;
    assign tft_bl  = 1'b0;

    assign seg7_sclk = 1'b0;
    assign seg7_rclk = 1'b0;
    assign seg7_dio  = 1'b0;

endmodule

`default_nettype wire
