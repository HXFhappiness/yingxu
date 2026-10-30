
module design_top_wrapper (
    input  wire                             I_sys_clk                               ,

    input  wire                             I_key_in                                ,

    input  wire                             I_key0_n                                ,
    input  wire                             I_key1_n                                ,
    input  wire                             I_key2_n                                ,

    // V0.4A-B: SD BMP display path (byte stream is in the sys_clk domain).
    input  wire [7:0]                       I_bmp_sd_data                           ,
    input  wire                             I_bmp_sd_valid                          ,
    output wire                             O_bmp_sd_ready                          ,
    input  wire                             I_bmp_start                             ,
    input  wire                             I_sd_fail                              ,
    input  wire [3:0]                       I_img_index                            ,
    input  wire                             I_game_mode                            ,
    input  wire                             I_music_en                             ,
    output wire [27:0]                      O_wav_base                             ,
    output wire                             O_wav_restart                          ,
    output wire [1:0]                       O_wav_sstate                          ,   // G6diag
    output wire [10:0]                      O_wav_occ                             ,   // G6diag
    output wire                             O_wav_wdog                            ,   // G6diag
    output wire [15:0]                      O_wav_pops                            ,   // G6diag
    output wire [15:0]                      O_wav_wdog_cnt                        ,   // G6diag
    output wire [10:0]                      O_wav_rptr                            ,   // G6diag
    output wire [10:0]                      O_wav_wptr                            ,   // G6diag
    output wire [15:0]                      O_wav_lastl                           ,   // G6diag
    output wire [15:0]                      O_wav_outp_cnt                        ,   // G6diag
    output wire [15:0]                      O_wav_byte_cnt                        ,   // G6diag
    output wire [15:0]                      O_wav_rate                            ,   // G6diag
    input  wire [1:0]                       I_game_sel                             ,   // G3: 00鎵撶爾鍧?01渚电暐鑰?10鍗″甫
    input  wire                             I_cart_swap                            ,   // G4: 鍗″甫妯″紡涓嬪垏鎹㈤暅鍍?鈫?閲嶈浇
    input  wire                             I_sd_ready                             ,   // G3: SD 就绪(粘滞)
    output wire                             O_cart_restart                         ,   // G3: 卡带加载触发
    output wire                             O_cart_busy                            ,   // G4: 鍗″甫鍔犺浇涓?璋冭瘯LED)
    output wire                             O_cart_hb                              ,   // G4: CPU 甯у績璺?璋冭瘯LED)
    output wire                             O_cart_seen                            ,   // G4d: cart received stream bytes (debug LED)
    output wire [2:0]                       O_cart_lstate                          ,
    output wire [9:0]                       O_cart_wcnt                            ,
    output wire                             O_cart_en                              ,
    output wire [15:0]                      O_spr_cnt                             ,
    output wire [3:0]                       O_cart_flags                          ,
    output wire [9:0]                       O_cart_pc                             ,
    output wire [15:0]                      O_cart_dwc                            ,
    output wire [23:0]                      O_cart_prog0                          ,
    input  wire                             I_cart_ready                          ,
    input  wire                             I_cart_test                           ,
    output wire [15:0]                      O_cart_retire                         ,
    output wire [23:0]                      O_cart_p18                            ,
    output wire [7:0]                       O_cart_score                          ,
    output  wire [ 3:0]                     O_inv_wave                             ,
    output  wire [ 1:0]                     O_inv_lives                            ,
    input  wire [3:0]                       I_fade_shift                           ,   // fade dark level
    input  wire                             I_bright                               ,   // photo brightness +24
    input  wire                             I_contrast                             ,   // photo contrast x1.5
    input  wire [20:0]                      I_wr_base                              ,   // loader target buffer
    input  wire [20:0]                      I_rd_base                              ,   // display source buffer
    input  wire [7:0]                       I_seg_enable                           ,

    // V0.4A-B diagnostics for the display side.
    output wire                             O_dbg_fb_ready                          ,
    output wire                             O_dbg_fb_underflow                      ,
    output wire                             O_dbg_bmp_done                          ,
    output wire [19:0]                      O_dbg_bmp_words                         ,
    output wire [4:0]                       O_dbg_cstate                            ,
    output wire                             O_dbg_wr_full                           ,
    output wire                             O_dbg_media_ready                       ,
    output wire                             O_dbg_wr2_full                          ,
    output wire                             O_dbg_rd2_empty                         ,
    output wire                             O_dbg_pix_hb                            ,

    // Minimal bring-up: first four bytes of the SD stream, shown as grey bands.
    // P0: the byte probes were never consumed here and are removed.

    input  wire                             I_i2s_BCLK                              ,
    input  wire                             I_i2s_LRCK                              ,
    input  wire                             I_i2s_DOUT                              ,

    output wire                             O_ddc_scl                               ,
    inout  wire                             IO_ddc_sda                              ,

    output wire                             O_tmds_ch0_p                            ,
    output wire                             O_tmds_ch1_p                            ,
    output wire                             O_tmds_ch2_p                            ,
    output wire                             O_tmds_clk_p                            ,
    output wire         [   3: 0]           O_hdmi_debug                            
);

    wire S_pll_lock                                 ;
    wire S_rst                                      ;
    wire                               S_pixel_clk                                ; 
    wire                               S_serial_clk                               ;
    wire                               S_axis_s_user                              ;
    wire                               S_axis_s_valid                             ;
    wire                               S_axis_s_last                              ;
    wire           [  23: 0]           S_axis_s_data                              ;
    wire                               S_axis_s_ready                             ;

    // V0.3B-A framebuffer/timing bridge
    wire           [  10: 0]           S_pixel_x                                  ;
    wire           [   9: 0]           S_pixel_y                                  ;
    wire                               S_pixel_active                             ;
    wire [23:0] S_fb_rgb                               ;
    wire        S_fb_ready                             ;
    wire        S_fb_underflow                         ;
    // V0.3C-A unified media stream
    wire        S_media_clk                            ;
    wire        S_media_valid                          ;
    wire        S_media_ready                          ;
    wire [31:0] S_media_data                           ;
    wire        S_media_frame_start                    ;
    wire        S_media_frame_end                      ;
    wire        S_bmp_done                             ;
    wire [19:0] S_bmp_words                            ;
    wire [4:0]  S_fb_cstate                            ;
    wire        S_fb_wr1_full                          ;
    wire        S_fb_media_ready                       ;

    assign O_dbg_fb_ready     = S_fb_ready;
    assign O_dbg_fb_underflow = S_fb_underflow;
    assign O_dbg_bmp_done     = S_bmp_done;
    assign O_dbg_bmp_words    = S_bmp_words;
    assign O_dbg_cstate       = S_fb_cstate;
    assign O_dbg_wr_full      = S_fb_wr1_full;
    assign O_dbg_media_ready  = S_fb_media_ready;
    assign O_dbg_wr2_full     = S_wr2_full;
    assign O_dbg_rd2_empty    = S_rd2_empty;

    // Pixel-clock heartbeat: if the HDMI PLL is alive this toggles at ~2 Hz.
    reg [24:0] pix_hb_cnt;
    always @(posedge S_pixel_clk or posedge S_rst_pix) begin
        if (S_rst_pix) pix_hb_cnt <= 25'd0;
        else           pix_hb_cnt <= pix_hb_cnt + 25'd1;
    end
    assign O_dbg_pix_hb       = pix_hb_cnt[24];

    wire                               S_audio_valid                              ;
    wire           [  23: 0]           S_audio_left_data                          ;
    wire           [  23: 0]           S_audio_right_data                         ;

    // Audio source mux: I2S input in photo mode, PSG in game mode.
    wire                               A_valid                                     ;
    wire           [  23: 0]           A_left                                      ;
    wire           [  23: 0]           A_right                                     ;

    wire [9:0] S_ch0_tmds_data                            ; 
    wire [9:0] S_ch1_tmds_data                            ; 
    wire [9:0] S_ch2_tmds_data                            ; 
    wire [9:0] S_clk_tmds_data                            ; 

    wire                               S_acr_valid                                ; 
    wire           [  19: 0]           S_acr_cts                                  ; 
    wire           [  19: 0]           S_acr_n                                    ; 

    wire                               S_key_trig                                 ; 
    wire                               S_edid_valid                               ; 
    wire                               S_video_locked                             ;
    reg            [  25: 0]           S_pixel_hs_count                           ;
    reg            [  14: 0]           S_line_hs_count                            ;
    reg            [   4: 0]           S_frame_hs_count                           ;
    wire           [   7: 0]           S_edid_data                                ; 

    pll_hdmi1_4b U_pll(
    .refclk                             (I_sys_clk                           ),
    .reset                              (1'b0                                ),

    .extlock                            (S_pll_lock                          ),

    .clk1_out                           (S_pixel_clk                         ),
    .clk2_out                           (S_serial_clk                        ) 
    );


    assign                              S_rst                       = ~S_pll_lock          ;

    // -------------------------------------------------------------------------
    // Reset synchroniser for the pixel domain.
    //
    // S_rst is an asynchronous PLL-lock-derived signal distributed to dozens of
    // registers across several clock domains. P&R reported repeated "Failed to
    // fix hold" on the HDMI reset fanout (I_rst_dup_*), which intermittently
    // left the TMDS link dead - the build worked or not depending on placement.
    // Asserting asynchronously but releasing synchronously to the pixel clock
    // keeps the reset net short and local to this domain.
    // -------------------------------------------------------------------------
    reg [3:0] S_rst_sync_pix;
    always @(posedge S_pixel_clk or posedge S_rst) begin
        if (S_rst) S_rst_sync_pix <= 4'b1111;
        else       S_rst_sync_pix <= {S_rst_sync_pix[2:0], 1'b0};
    end
    wire S_rst_pix = S_rst_sync_pix[3];

    // G3: ?¨?????????°?¤????????????¨???????????????????¤????????¤§????????????????????????è·??°???????    // è§?é???????????rst_dup ?¤??????????????????????é??é?·é?±???P5 ?????????????????§????¤???????
reg [1:0] S_rst_g, S_rst_v, S_rst_t;
    always @(posedge S_pixel_clk or posedge S_rst) begin
        if (S_rst) begin
            S_rst_g <= 2'b11;  S_rst_v <= 2'b11;  S_rst_t <= 2'b11;
        end
        else begin
            S_rst_g <= {S_rst_g[0], 1'b0};
            S_rst_v <= {S_rst_v[0], 1'b0};
            S_rst_t <= {S_rst_t[0], 1'b0};
        end
    end

    // P0: the SW7 framebuffer/direct-background selector and its CDC are gone
    // with the pattern fallback; the picture source is always the composited
    // sprite-engine output.
    // V0.3B-B-R2: high-speed TMDS debug heartbeat logic removed.

    I2S_receiver u_I2S_receiver(
    .I_clk                              (S_pixel_clk                         ),
    .I_rst                              (S_rst_pix                               ),
  
    .I_i2s_BCLK                         (I_i2s_BCLK                          ),
    .I_i2s_LRCK                         (I_i2s_LRCK                          ),
    .I_i2s_DOUT                         (I_i2s_DOUT                          ),
  
    .O_audio_valid                      (S_audio_valid                       ),
    .O_audio_left_data                  (S_audio_left_data                   ),
    .O_audio_right_data                 (S_audio_right_data                  ) 
    );


    audio_arc_calculate#(
    .ACR_N                              (6144                                ) 
    )u_audio_arc_calculate(
    .I_clk                              (S_pixel_clk                         ),
    .I_rst                              (S_rst_pix                               ),

    .I_audio_valid                      (A_valid                             ),

    .O_acr_valid                        (S_acr_valid                         ),
    .O_acr_cts                          (S_acr_cts                           ),
    .O_acr_n                            (S_acr_n                             ) 
    );


    key_remove_shakes u_key_remove_shakes(
    .I_clk                              (S_pixel_clk                         ),
    .I_rst_n                            (S_pll_lock                          ),
    .I_key_in                           (I_key_in                            ),
    .O_key_trig_out                     (S_key_trig                          )
    );

    // P0: the three key debouncers only fed the media-scene selector, which
    // has been dead since the SD path took over. KEY0/KEY1 are debounced in
    // the 50 MHz domain (hardware_test) and the games take the raw pins.




    // Composited picture: sprite-engine output feeds the HDMI source directly.
    wire [23:0] S_img_rgb;

    video_source_test#(
    .HTOTAL                             (1650),
    .HACTIVE                            (1280),
    .HFP                                (110),
    .HSA                                (40),
    .HBP                                (220),
    .VTOTAL                             (750),
    .VACTIVE                            (720),
    .VFP                                (5),
    .VSA                                (5                                   ),
    .VBP                                (20)
    )U_video_source_test(
    .I_clk                              (S_pixel_clk                         ),
    .I_rst                              (S_rst_pix                               ),

    .O_video_user                       (S_axis_s_user                       ),
    .O_video_valid                      (S_axis_s_valid                      ),
    .O_video_last                       (S_axis_s_last                       ),
    .O_video_data                       (S_axis_s_data                       ),
    .I_video_ready                      (S_axis_s_ready                      ),

    .O_pixel_x                          (S_pixel_x                           ),
    .O_pixel_y                          (S_pixel_y                           ),
    .O_pixel_active                     (S_pixel_active                      ),

    .I_fb_rgb                           (S_img_rgb                           )
    );

    // P0: the V0.3C-B media-scene selector (KEY0/1/2 -> scene) is gone; the
    // SD BMP loader owns the media path and drives no scenes.

    // -------------------------------------------------------------------------
    // V0.3C-B-R1 lightweight multi-scene media source.
    //
    // This is the only block the TF/BMP branch needs to replace later.
    // The framebuffer/HDMI side only sees the media_* contract.
    // -------------------------------------------------------------------------
    // -------------------------------------------------------------------------
    // V0.4A-B : SD BMP media source.
    // Implements the same media_* contract as the test generator, so the
    // framebuffer / HDMI side is untouched. A slow source (SPI SD) is legal:
    // the framebuffer simply stalls mid-frame and swaps when the frame is done.
    // -------------------------------------------------------------------------
    // -------------------------------------------------------------------------
    // V0.4A-B : SD -> SDRAM scratch -> pixel-rate player.
    // The double framebuffer is bypassed for still images: it would need a
    // second full frame of SDRAM bandwidth (RD1+WR1+RD2 > 100 M words/s).
    // Loading uses WR2, playback uses RD2, and only RD2 runs during display.
    // -------------------------------------------------------------------------
    wire [31:0] S_wr2_data                             ;
    wire        S_wr2_en                               ;
    wire [20:0] S_wr2_addr                             ;
    wire [20:0] S_wr2_max                              ;
    wire [8:0]  S_wr2_len                              ;
    wire        S_wr2_load                             ;
    wire        S_wr2_full                             ;
    wire        S_rd2_en                               ;
    wire [20:0] S_rd2_addr                             ;
    wire [20:0] S_rd2_max                              ;
    wire [8:0]  S_rd2_len                              ;
    wire        S_rd2_load                             ;
    wire        S_rd2_empty                            ;
    wire [31:0] S_rd2_data                             ;

    // -------------------------------------------------------------------------
    // Full-frame path: SD -> RGB565 -> SDRAM scratch (WR2), replayed at pixel
    // rate (RD2) straight into the HDMI pipeline. The double framebuffer is
    // bypassed because feeding it from SPI (1.8 s/frame) starves its swap logic.
    // -------------------------------------------------------------------------
    wire        bmp_sd_ready;
    // G6: 音乐播放时把背压权交给播放器（探针一次 restart 连读 5401 扇区，
// 不背压会冲爆 1024 样本 FIFO）
assign O_bmp_sd_ready = I_music_en ? wav_sd_ready : bmp_sd_ready;

    wire [23:0] S_player_rgb;

    yingxu_bmp_loader #(
        .H_ACTIVE                           (1280                                ),
        .V_ACTIVE                           (720                                 )
    ) U_yingxu_bmp_loader (
        .clk                                (I_sys_clk                           ),
        .rst                                (S_rst                               ),

        .start                              (I_bmp_start                         ),
        .i_base                             (I_wr_base                           ),
        .sd_data                            (I_bmp_sd_data                       ),
        .sd_valid                           (I_bmp_sd_valid                      ),
        .sd_ready                           (bmp_sd_ready                        ),

        .wr2_data                           (S_wr2_data                          ),
        .wr2_en                             (S_wr2_en                            ),
        .wr2_full                           (S_wr2_full                          ),
        .wr2_addr                           (S_wr2_addr                          ),
        .wr2_max_addr                       (S_wr2_max                           ),
        .wr2_len                            (S_wr2_len                           ),
        .wr2_load                           (S_wr2_load                          ),

        .words_written                      (S_bmp_words                         ),
        .loaded                             (S_bmp_done                          )
    );

    yingxu_sdram_video_player #(
        .H_ACTIVE                           (1280                                ),
        .V_ACTIVE                           (720                                 ),
        .H_TOTAL                            (1650                                ),
        .V_TOTAL                            (750                                 )
    ) U_yingxu_sdram_video_player (
        .pixel_clk                          (S_pixel_clk                         ),
        .i_base                             (I_rd_base                           ),
        .rst                                (S_rst                               ),

        .pixel_x                            (S_pixel_x                           ),
        .pixel_y                            (S_pixel_y                           ),
        .pixel_active                       (S_pixel_active                      ),
        .loaded                             (S_bmp_done                          ),

        .rd2_data                           (S_rd2_data                          ),
        .rd2_empty                          (S_rd2_empty                         ),
        .rd2_en                             (S_rd2_en                            ),
        .rd2_addr                           (S_rd2_addr                          ),
        .rd2_max_addr                       (S_rd2_max                           ),
        .rd2_len                            (S_rd2_len                           ),
        .rd2_load                           (S_rd2_load                          ),

        .fade_dark                          (I_fade_shift                        ),
        .bright_en                          (I_bright                            ),
        .contrast_en                        (I_contrast                          ),
        .rgb_out                            (S_player_rgb                        ),
        .frame_tick                         (                                    )
    );

    // Display source: the player's pixels, or magenta when the SD bring-up failed.
    // -------------------------------------------------------------------------
    // Image counter indicator: four segments at the bottom-left, the active one
    // highlighted. Equivalent to "image N of 4" without touching the pipelined
    // OSD path (a font lookup here would eat the remaining setup margin).
    // -------------------------------------------------------------------------
    wire        in_bar_y = (S_pixel_y >= 10'd676) && (S_pixel_y < 10'd690);

    wire seg0 = (S_pixel_x >= 11'd24)  && (S_pixel_x < 11'd48);
    wire seg1 = (S_pixel_x >= 11'd52)  && (S_pixel_x < 11'd76);
    wire seg2 = (S_pixel_x >= 11'd80)  && (S_pixel_x < 11'd104);
    wire seg3 = (S_pixel_x >= 11'd108) && (S_pixel_x < 11'd132);
    wire seg4 = (S_pixel_x >= 11'd136) && (S_pixel_x < 11'd160);
    wire seg5 = (S_pixel_x >= 11'd164) && (S_pixel_x < 11'd188);
    wire seg6 = (S_pixel_x >= 11'd192) && (S_pixel_x < 11'd216);
    wire seg7 = (S_pixel_x >= 11'd220) && (S_pixel_x < 11'd244);

    wire [7:0] seg_onehot = {seg7, seg6, seg5, seg4, seg3, seg2, seg1, seg0};
    wire [7:0] hit_mask   = 8'd1 << (I_img_index - 4'd1);

    wire bar_on  = in_bar_y && (|(seg_onehot & I_seg_enable));
    wire bar_hit = in_bar_y && (|(seg_onehot & hit_mask));

    // -------------------------------------------------------------------------
    // Game audio: a tiny PSG replaces the I2S input while in game mode, so the
    // sound rides the normal HDMI audio packets.
    // G3: 涓夋父鎴忔ā寮忚瘧鐮侊紙00 鎵撶爾鍧?/ 01 渚电暐鑰?/ 10 鍗″甫锛?    // -------------------------------------------------------------------------
    wire        psg_valid;
    wire [23:0] psg_l, psg_r;

    wire        sel_cart = I_game_mode & (I_game_sel == 2'd2);
    wire        sel_hw   = I_game_mode & (I_game_sel == 2'd1);
    wire        frame_tick = (S_pixel_x == 11'd0) && (S_pixel_y == 10'd720);

    // G5: hardware state-machine invaders, restored as the "hardware half" of
    // the on-board hardware-vs-cartridge comparison.
    reg         sel_hw_q;
    always @(posedge S_pixel_clk or posedge S_rst_pix) begin
        if (S_rst_pix) sel_hw_q <= 1'b0;
        else           sel_hw_q <= sel_hw;
    end
    wire        hw_restart = sel_hw & ~sel_hw_q;

    wire        hw_spr_we;
    wire [3:0]  hw_spr_slot;
    wire        hw_spr_en;
    wire [10:0] hw_spr_x;
    wire [9:0]  hw_spr_y;
    wire [6:0]  hw_spr_w;
    wire [5:0]  hw_spr_h;
    wire [23:0] hw_spr_c;
    wire        hw_ev_hit, hw_ev_lose, hw_ev_win, hw_lost;
    wire [3:0]  hw_wave;
    wire [1:0]  hw_lives;

    yingxu_invaders #(
        .H_ACTIVE   (1280),
        .V_ACTIVE   (720 )
    ) U_hw_inv (
        .clk        (S_pixel_clk),
        .rst        (S_rst_pix  ),
        .frame_tick (frame_tick ),
        .enable     (sel_hw     ),
        .restart    (hw_restart ),
        .key_left   (~I_key0_n  ),
        .key_right  (~I_key1_n  ),
        .spr_we     (hw_spr_we  ),
        .spr_slot   (hw_spr_slot),
        .spr_en     (hw_spr_en  ),
        .spr_x      (hw_spr_x   ),
        .spr_y      (hw_spr_y   ),
        .spr_w      (hw_spr_w   ),
        .spr_h      (hw_spr_h   ),
        .spr_c      (hw_spr_c   ),
        .wave       (hw_wave    ),
        .lives      (hw_lives   ),
        .o_ev_hit   (hw_ev_hit  ),
        .o_ev_lose  (hw_ev_lose ),
        .o_ev_win   (hw_ev_win  ),
        .lost       (hw_lost    )
    );

    wire        c_ev_hit, c_ev_paddle, c_ev_lose, c_ev_win;   // 鍗″甫瀛愮郴缁熶簨浠?
    wire ev_hit    = sel_hw ? hw_ev_hit  : c_ev_hit;
    wire ev_paddle = sel_hw ? 1'b0       : c_ev_paddle;
    wire ev_lose   = sel_hw ? hw_ev_lose : c_ev_lose;
    wire ev_win    = sel_hw ? hw_ev_win  : c_ev_win;

    yingxu_psg #(.CLK_HZ(73_333_333), .SAMPLE_HZ(48_000)) U_psg (
        .clk         (S_pixel_clk),
        .rst         (S_rst_pix  ),
        .ev_hit      (ev_hit     ),
        .ev_paddle   (ev_paddle  ),
        .ev_lose     (ev_lose    ),
        .ev_win      (ev_win     ),
        .enable      (I_game_mode),
        .audio_valid (psg_valid  ),
        .audio_left  (psg_l      ),
        .audio_right (psg_r      )
    );

    // ---- WAV 音乐播放器 + 饱和混音器（G6）--------------------------------
    wire [23:0] wav_l, wav_r;
    wire        wav_active;
    wire        wav_sd_ready;
    wire [23:0] wav_l_m = wav_active ? wav_l : 24'd0;
    wire [23:0] wav_r_m = wav_active ? wav_r : 24'd0;
    wire signed [24:0] mix_l = $signed(psg_l) + $signed(wav_l_m);
    wire signed [24:0] mix_r = $signed(psg_r) + $signed(wav_r_m);
    wire [23:0] mix_l_sat = (mix_l[24] == mix_l[23]) ? mix_l[23:0] :
                            mix_l[24] ? 24'h800000 : 24'h7FFFFF;
    wire [23:0] mix_r_sat = (mix_r[24] == mix_r[23]) ? mix_r[23:0] :
                            mix_r[24] ? 24'h800000 : 24'h7FFFFF;

    yingxu_wav_player u_wav (
        .sys_clk      (I_sys_clk     ),
        .sys_rst      (S_rst         ),
        .pix_clk      (S_pixel_clk   ),
        .pix_rst      (S_rst_pix     ),
        .music_active (I_music_en    ),
        .wav_base     (O_wav_base    ),
        .wav_restart  (O_wav_restart ),
        .dbg_sstate   (O_wav_sstate   ),
        .dbg_occ      (O_wav_occ      ),
        .dbg_wdog     (O_wav_wdog     ),
        .dbg_pops     (O_wav_pops     ),
        .dbg_wdog_cnt (O_wav_wdog_cnt ),
        .dbg_rptr     (O_wav_rptr     ),
        .dbg_wptr     (O_wav_wptr     ),
        .dbg_lastl    (O_wav_lastl    ),
        .dbg_outp_cnt (O_wav_outp_cnt ),
        .dbg_byte_cnt (O_wav_byte_cnt ),
        .dbg_rate     (O_wav_rate     ),
        .sd_data      (I_bmp_sd_data ),
        .sd_valid     (I_bmp_sd_valid),
        .sd_ready     (wav_sd_ready  ),
        .out_tick     (psg_valid     ),
        .wav_l        (wav_l         ),
        .wav_r        (wav_r         ),
        .wav_active   (wav_active    )
    );

    assign A_valid = I_game_mode ? psg_valid : S_audio_valid;
    assign A_left  = I_game_mode ? mix_l_sat : S_audio_left_data;
    assign A_right = I_game_mode ? mix_r_sat : S_audio_right_data;

    // -------------------------------------------------------------------------
    // Sprite overlay layer (v1). Sits after the replay stage and before HDMI.
    // The table is written once at reset with four coloured rectangles so the
    // compositing path can be verified on the board; the game logic will drive
    // the same port afterwards.
    // -------------------------------------------------------------------------
    wire [23:0] S_sprite_rgb;

    assign S_img_rgb = S_sprite_rgb;

    // Game mode blanks the background: the last photo must not stay behind the
    // playfield.
    wire [23:0] S_base_rgb = I_game_mode ? 24'h000000 :
                             I_sd_fail ? 24'hC000C0 :
                             bar_on    ? (bar_hit ? 24'hFFC000 : 24'h502020) :
                                         S_player_rgb;

    // Photo mode carries no sprites, so the table is wiped whenever the mode
    // leaves the game (otherwise the ball and paddle would stay on screen).
    reg [4:0]  clr_cnt;
    reg        clr_active;
    reg [13:0] clr_hold;      // keep sweeping for a while after a switch
    reg        mode_d;
    reg [1:0]   gsel_d;
    reg [10:0] spr_x; reg [9:0] spr_y; reg [6:0] spr_w; reg [5:0] spr_h;
    reg [23:0] spr_c;

    // Power-on wipe: the sprite table lives in BRAM whose contents are undefined
    // at configuration time (eram_init is off), so every slot must be written with
    // en=0 once after reset. Without this the engine draws 15 garbage rectangles
    // (rainbow streaks) on the very first frames and whenever a slot is untouched.
    reg [17:0] boot_wipe_cnt;
    always @(posedge S_pixel_clk or posedge S_rst_pix) begin
        if (S_rst_pix) boot_wipe_cnt <= 18'd0;
        else if (boot_wipe_cnt != 18'h3FFFF) boot_wipe_cnt <= boot_wipe_cnt + 18'd1;
    end
    wire boot_wipe = (boot_wipe_cnt != 18'h3FFFF);

    always @(posedge S_pixel_clk or posedge S_rst_pix) begin
        if (S_rst_pix) begin
            clr_cnt    <= 5'd0;
            clr_active <= 1'b0;
            clr_hold   <= 14'd0;
            mode_d     <= 1'b0;
            gsel_d     <= 2'd0;
        end
        else begin
            mode_d <= I_game_mode;
            gsel_d <= I_game_sel;
            // One sweep of 16 slots is not always enough (the other game may still
            // push a slot in the same frame), so sweep continuously for ~3000
            // pixel clocks after any mode or game change.
            if ((mode_d && !I_game_mode) || (I_game_mode && (gsel_d != I_game_sel))) begin
                clr_hold   <= 14'd3000;
                clr_cnt    <= 5'd0;
                clr_active <= 1'b1;
            end
            else if (boot_wipe) begin
                clr_cnt    <= (clr_cnt == 5'd15) ? 5'd0 : (clr_cnt + 5'd1);
                clr_active <= 1'b1;
            end
            else if (clr_hold != 14'd0) begin
                clr_hold   <= clr_hold - 14'd1;
                clr_cnt    <= (clr_cnt == 5'd15) ? 5'd0 : (clr_cnt + 5'd1);
                clr_active <= 1'b1;
            end
            else begin
                clr_active <= 1'b0;
            end
        end
    end

    // G4: cartridge software path (see tbl_* mux below)


    // A table wipe always wins, so switching modes or games cannot leave stale
    // sprites behind. G4: ???????????????????????????????????????/??????è???·??????????è???????????
wire        src_we   = sel_hw ? hw_spr_we   : c_spr_we;
    wire [3:0]  src_slot = sel_hw ? hw_spr_slot : c_spr_slot;
    wire        src_en   = sel_hw ? hw_spr_en   : c_spr_en;
    wire [10:0] src_x    = sel_hw ? hw_spr_x    : c_spr_x;
    wire [9:0]  src_y    = sel_hw ? hw_spr_y    : c_spr_y;
    wire [6:0]  src_w    = sel_hw ? hw_spr_w    : c_spr_w;
    wire [5:0]  src_h    = sel_hw ? hw_spr_h    : c_spr_h;
    wire [23:0] src_c    = sel_hw ? hw_spr_c    : c_spr_c;

    wire        tbl_we   = clr_active | ((sel_cart | sel_hw) & src_we);
    wire [3:0]  tbl_slot = clr_active ? clr_cnt[3:0] : src_slot;
    wire        tbl_en   = clr_active ? 1'b0 : src_en;
    wire [10:0] tbl_x    = src_x;
    wire [9:0]  tbl_y    = src_y;
    wire [6:0]  tbl_w    = src_w;
    wire [5:0]  tbl_h    = src_h;
    wire [23:0] tbl_c    = src_c;
    wire [59:0] brick_mask = sel_cart ? c_brick_mask : 60'd0;
    // -------------------------------------------------------------------------
    // Scrolling tile background. Only active in game mode; photo mode feeds a
    // transparent layer so the picture is untouched.
    // -------------------------------------------------------------------------
    wire [9:0] tile_py = (S_pixel_y == 10'd749) ? 10'd0 : (S_pixel_y + 10'd1);
    wire [5:0] scroll_x;
    wire [5:0] scroll_y;
    wire [23:0] tile_rgb;

    reg [5:0] scroll_y_r;
    reg [5:0] scroll_x_r;

    always @(posedge S_pixel_clk or posedge S_rst_pix) begin
        if (S_rst_pix) begin
            scroll_y_r <= 6'd0;
            scroll_x_r <= 6'd0;
        end
        else if (frame_tick && I_game_mode) begin
            scroll_y_r <= scroll_y_r + 6'd2;     // 2 px per frame (~120 px/s)
        end
    end

    assign scroll_x = scroll_x_r;
    assign scroll_y = I_game_mode ? {1'b0, scroll_y_r[4:0]} : 6'd0;

    yingxu_tile_layer #(
        .H_ACTIVE (1280),
        .V_ACTIVE (720 ),
        .COLS     (40  ),
        .ROWS     (24  )
    ) U_tile (
        .clk      (S_pixel_clk),
        .rst      (S_rst_t   ),
        .px       (S_pixel_x  ),
        .py       (tile_py    ),
        .scroll_x (scroll_x   ),
        .scroll_y (scroll_y   ),
        .rgb      (tile_rgb   )
    );
    // -------------------------------------------------------------------------
    // Sprite engine (v2, line-buffered). This is the ONLY compositor in the
    // pixel path: bg_rgb (photo / blank) is overlaid with the sprite table,
    // the brick layer and the scrolling tile. G4 ????¤?: é????????è???????????è??è????????    // ???è?? S_sprite_rgb ???é?±??¨??????????????????é??é??è·?é???±????    // -------------------------------------------------------------------------
    yingxu_sprite_engine #(.NSLOT(16)) U_sprite (
        .clk          (S_pixel_clk   ),
        .rst          (S_rst_pix     ),
        .pixel_x      (S_pixel_x     ),
        .pixel_y      (S_pixel_y     ),
        .pixel_active (S_pixel_active),
        .bg_rgb       (S_base_rgb    ),
        .we           (tbl_we        ),
        .slot         (tbl_slot      ),
        .en           (tbl_en        ),
        .spr_x        (tbl_x         ),
        .spr_y        (tbl_y         ),
        .spr_w        (tbl_w         ),
        .spr_h        (tbl_h         ),
        .spr_color    (tbl_c         ),
        .brick_mask   (brick_mask    ),
        .tile_rgb     (I_game_mode ? tile_rgb : 24'h000000),
        .rgb_out      (S_sprite_rgb  )
    );
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // -------------------------------------------------------------------------
    // G3: ???????????????v2??????YX-8 CPU ??¨????????? + ???è?????sys_clk) + ???????¨????RAM???    // ??????????????????è???·??????????FSMè???§????YX-8??????è????????v2???????????§??????    // U_game / U_invaders / CDC ????·????é?¤???    // -------------------------------------------------------------------------
    wire cart_restart_w;
    wire cart_busy_w, cart_hb_w;

    // 绮剧伒鐩村啓锛堝悓鍩燂紝鏃?CDC锛?
wire        c_spr_we;
    wire [3:0]  c_spr_slot;
    wire        c_spr_en;
    wire [10:0] c_spr_x;
    wire [9:0]  c_spr_y;
    wire [6:0]  c_spr_w;
    wire [5:0]  c_spr_h;
    wire [23:0] c_spr_c;
    wire [59:0] c_brick_mask;
    wire        cart_seen_w;
    wire [2:0]  cart_lstate_w;
    wire [9:0]  cart_wcnt_w;
    wire        cart_en_w;
    wire [15:0] spr_cnt_w;
    wire [3:0]  cart_flags_w;
    wire [9:0]  cart_pc_w;
    wire [15:0] cart_dwc_w;
    wire [23:0] cart_prog0_w;
    wire        cart_ready_w;
    wire [15:0] cart_retire_w;
    wire [23:0] cart_p18_w;
    wire [7:0]  cart_score_w;

    yx8_cart_soc_v2 u_cart (
        .sys_clk        (I_sys_clk     ),
        .pix_clk        (S_pixel_clk   ),
        .pix_rst        (S_rst_pix     ),
        .sys_rst        (S_rst         ),
        .en             (sel_cart      ),
        .sd_ready       (I_sd_ready    ),
        .sd_data        (I_bmp_sd_data ),
        .sd_valid       (I_bmp_sd_valid),
        .key0_n         (I_key0_n      ),
        .key1_n         (I_key1_n      ),
        .pix_frame_tick (frame_tick    ),
        .reload         (I_cart_swap   ),
        .test_mode      (I_cart_test   ),
        .cart_restart   (cart_restart_w),
        .cart_busy      (cart_busy_w   ),
        .cart_hb        (cart_hb_w     ),
        .cart_seen      (cart_seen_w   ),
        .cart_lstate    (cart_lstate_w ),
        .cart_wcnt      (cart_wcnt_w   ),
        .cart_en_dbg    (cart_en_w     ),
        .cart_spr_cnt   (spr_cnt_w     ),
        .cart_flags     (cart_flags_w  ),
        .cart_pc        (cart_pc_w      ),
        .cart_dw_cnt    (cart_dwc_w     ),
        .cart_prog0     (cart_prog0_w   ),
        .cart_ready     (cart_ready_w   ),
        .cart_retire    (cart_retire_w  ),
        .cart_p18       (cart_p18_w     ),
        .spr_we         (c_spr_we      ),
        .spr_slot       (c_spr_slot    ),
        .spr_en         (c_spr_en      ),
        .spr_x          (c_spr_x       ),
        .spr_y          (c_spr_y       ),
        .spr_w          (c_spr_w       ),
        .spr_h          (c_spr_h       ),
        .spr_color      (c_spr_c       ),
        .brick_mask     (c_brick_mask  ),
        .ev_hit         (c_ev_hit      ),
        .ev_paddle      (c_ev_paddle   ),
        .ev_lose        (c_ev_lose     ),
        .ev_win         (c_ev_win      ),
        .cart_score     (cart_score_w   )
    );
    assign O_cart_restart = cart_restart_w;
    assign O_cart_busy    = cart_busy_w;
    assign O_cart_hb      = cart_hb_w;
    assign O_cart_seen    = cart_seen_w;
    assign O_cart_lstate  = cart_lstate_w;
    assign O_cart_wcnt    = cart_wcnt_w;
    assign O_cart_en      = cart_en_w;
    assign O_spr_cnt      = spr_cnt_w;
    assign O_cart_flags   = cart_flags_w;
    assign O_cart_pc      = cart_pc_w;
    assign O_cart_dwc     = cart_dwc_w;
    assign O_cart_prog0   = cart_prog0_w;
    assign O_cart_retire  = cart_retire_w;
    assign O_cart_p18     = cart_p18_w;
    assign O_cart_score   = cart_score_w;
    // U_invaders ?·?è???§??????????è????????v2?????????????????????v_* ?????????é?¤???    // ??????é???±????????????????é?????
assign O_inv_wave  = 4'd0;
    assign O_inv_lives = 2'd0;



    // Framebuffer is left idle: it is not part of the image path any more.
    assign S_media_valid       = 1'b0;
    assign S_media_data        = 32'd0;
    assign S_media_frame_start = 1'b0;
    assign S_media_frame_end   = 1'b0;


    // -------------------------------------------------------------------------
    // V0.3C-A SDRAM double framebuffer sink.
    // -------------------------------------------------------------------------
    yingxu_sdram_framebuffer #(
        .H_TOTAL                            (1650                                ),
        .H_ACTIVE                           (1280                                ),
        .V_TOTAL                            (750                                 ),
        .V_ACTIVE                           (720                                 )
    ) U_yingxu_sdram_framebuffer (
        .sys_clk                            (I_sys_clk                           ),
        .pixel_clk                          (S_pixel_clk                         ),
        .rst                                (S_rst                               ),

        .pixel_x                            (S_pixel_x                           ),
        .pixel_y                            (S_pixel_y                           ),
        .pixel_active                       (S_pixel_active                      ),

        .media_clk                          (S_media_clk                         ),
        .media_valid                        (S_media_valid                       ),
        .media_ready                        (S_media_ready                       ),
        .media_data                         (S_media_data                        ),
        .media_frame_start                  (S_media_frame_start                 ),
        .media_frame_end                    (S_media_frame_end                   ),

        .rgb_out                            (S_fb_rgb                            ),
        .fb_ready                           (S_fb_ready                          ),
        .fb_underflow                       (S_fb_underflow                      ),

        .o_c_state                          (S_fb_cstate                         ),
        .o_wr1_full                         (S_fb_wr1_full                       ),
        .o_media_ready                      (S_fb_media_ready                    ),

        .i_wr2_data                         (S_wr2_data                          ),
        .i_wr2_en                           (S_wr2_en                            ),
        .i_wr2_addr                         (S_wr2_addr                          ),
        .i_wr2_max_addr                     (S_wr2_max                           ),
        .i_wr2_len                          (S_wr2_len                           ),
        .i_wr2_load                         (S_wr2_load                          ),
        .o_wr2_full                         (S_wr2_full                          ),

        .i_rd2_en                           (S_rd2_en                            ),
        .i_rd2_addr                         (S_rd2_addr                          ),
        .i_rd2_max_addr                     (S_rd2_max                           ),
        .i_rd2_len                          (S_rd2_len                           ),
        .i_rd2_load                         (S_rd2_load                          ),
        .o_rd2_data                         (S_rd2_data                          ),
        .o_rd2_empty                        (S_rd2_empty                         )
    );


    hdmi_1_4b_transmitter_core_wrapper#(
    .DEVICE                             ("EG"                                ),

    .HTOTAL                             (1650                                ),
    .HSA                                (40                                  ),
    .HFP                                (110                                 ),
    .HBP                                (220                                 ),
    .HACTIVE                            (1280                                ),
    .VTOTAL                             (750                                 ),
    .VSA                                (5                                   ),
    .VFP                                (5                                   ),
    .VBP                                (20                                  ),
    .VACTIVE                            (720                                 ),

    .VIDEO_VIC                          (69                                  ),

    .VIDEO_TPG                          ("Disable"),
    .VIDEO_FORMAT                       ("RGB"                               ),

    .AUDIO_SAMPLE_RATE                  ("48K"                               ),
        
    .IIC_SCL_DIV                        (125                                 ) 
    )u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk                        (S_pixel_clk                         ),
    .I_rst                              (S_rst_pix                               ),

    .I_edid_read_trig                   (S_key_trig                          ),
    .O_edid_read_valid                  (S_edid_valid                        ),
    .O_edid_read_data                   (S_edid_data                         ),

    .I_axis_s_user                      (S_axis_s_user                       ),
    .I_axis_s_valid                     (S_axis_s_valid                      ),
    .I_axis_s_last                      (S_axis_s_last                       ),
    .I_axis_s_data                      (S_axis_s_data                       ),
    .O_axis_s_ready                     (S_axis_s_ready                      ),

    .I_audio_valid                      (A_valid                             ),
    .I_audio_left_data                  (A_left                               ),
    .I_audio_right_data                 (A_right                             ),

    .I_acr_valid                        (S_acr_valid                         ),
    .I_acr_cts                          (S_acr_cts                           ),
    .I_acr_n                            (S_acr_n                             ),

    .O_video_locked                     (S_video_locked                      ),

    .O_ddc_scl                          (O_ddc_scl                           ),
    .IO_ddc_sda                         (IO_ddc_sda                          ),

    .O_ch0_tmds_data                    (S_ch0_tmds_data                     ),
    .O_ch1_tmds_data                    (S_ch1_tmds_data                     ),
    .O_ch2_tmds_data                    (S_ch2_tmds_data                     ),
    .O_clk_tmds_data                    (S_clk_tmds_data                     ) 
    );



    // -------------------------------------------------------------------------
    // V0.3B-B-R2 lightweight debug outputs.
    // No free-running debug counters are retained in the pixel/TMDS domains.
    // -------------------------------------------------------------------------
    assign O_hdmi_debug[0] = S_fb_ready;
    assign O_hdmi_debug[1] = S_fb_underflow;
    assign O_hdmi_debug[2] = S_pll_lock;
    assign O_hdmi_debug[3] = S_video_locked;

    hdmi_phy_wrapper  #(
    .DEVICE                             ("EG"                                ) //"EF2","EF3","EF4","SF1","EG","PH1A","PH1P","DR1"
    )u_hdmi2phy_wrapper(
    .I_pixel_clk                        (S_pixel_clk                         ),
    .I_serial_clk                       (S_serial_clk                        ),
    .I_rst                              (S_rst                               ),

    .I_tmds_channel_0                   (S_ch0_tmds_data                     ),
    .I_tmds_channel_1                   (S_ch1_tmds_data                     ),
    .I_tmds_channel_2                   (S_ch2_tmds_data                     ),
    .I_tmds_channel_clk                 (S_clk_tmds_data                     ),

    .O_tmds_ch0_p                       (O_tmds_ch0_p                        ),
    .O_tmds_ch1_p                       (O_tmds_ch1_p                        ),
    .O_tmds_ch2_p                       (O_tmds_ch2_p                        ),
    .O_tmds_clk_p                       (O_tmds_clk_p                        ) 
    );




endmodule