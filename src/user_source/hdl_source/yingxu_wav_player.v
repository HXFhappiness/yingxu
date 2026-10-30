// =============================================================================
// yingxu_wav_player.v — SD 卡 WAV(YXMA) 音乐播放器（映序）
//
// 数据流:
//   SD 探针字节流(sys_clk) → YXMA 头解析 → 16bit 立体声打包 → 异步 FIFO
//   → pix_clk 域按 PSG 的 48kHz valid 节拍弹出（按文件 rate 分数消费）
//   → 24bit 左右声道给混音器（饱和相加）
//
// SD 分块读取（不改探针）:
//   探针每次 restart 连续读 5401 扇区(2,765,312 B)后流停止。本模块消费到
//   块边界就发一拍 wav_restart，并把 wav_base 推进到下一块
//   (MUSIC_BASE + chunk*2,765,312)，顶层 mux 到探针 start_sector。
//   音乐槽 0 基址 = 2,000,000（板子视角 LBA，与 music2sd.py 一致）。
//   music_active 撤销/恢复（卡带加载抢占）→ SW4 重拨 = 从头重放。
//
// YXMA 头（32B，music2sd.py 生成）:
//   [0:4]='YXMA' [4]=ver [5]=channels [6:8]=16 [8:12]=rate [12:16]=frames
//   [16:20]=pcm_bytes。PCM 从 offset 32 起，s16le 交错；mono 时样本复制到 L/R。
//
// 已知取舍:
//   - 暂停/恢复不冲 FIFO：恢复瞬间会先放出暂停前缓冲的 ~0.5s 音频再续新数据
//   - 16bit → 24bit 增益 ×64（-12dBFS）；音量阶梯 ×128→×64→×32（改 6'd0 位宽）
// =============================================================================
`timescale 1ns / 1ps

module yingxu_wav_player #(
    parameter [27:0] MUSIC_BASE  = 28'd2_000_000,   // 音乐槽 0（板子 LBA）
    parameter [27:0] CHUNK_BYTES = 28'd2_765_312    // 5401 扇区 × 512
)(
    input  wire        sys_clk,        // 50 MHz，SD 字节流侧
    input  wire        sys_rst,
    input  wire        pix_clk,        // 73.33 MHz，音频输出侧
    input  wire        pix_rst,

    input  wire        music_active,   // SW4 && game_mode && !cart_busy（顶层算好）
    output reg  [27:0] wav_base,       // 当前块基址 → 顶层探针 start_sector mux
    output reg         wav_restart,    // 单拍 → 顶层探针 restart

    input  wire [7:0]  sd_data,        // 探针字节流（广播，多消费者各自取用）
    input  wire        sd_valid,
    output wire        sd_ready,       // 低 = 背压暂停探针

    input  wire        out_tick,       // 48kHz 节拍（接 PSG audio_valid）
    output reg  [23:0] wav_l,          // 24bit，混音器饱和相加
    output reg  [23:0] wav_r,
    output reg         wav_active,      // 正在播放（混音器选择/静音用）
    // G6diag: 板上诊断观测（不改行为）
    output wire [1:0]  dbg_sstate,      // FSM 状态
    output wire [10:0] dbg_occ,         // FIFO 占用（sys 视角）
    output wire        dbg_wdog,        // 断流看门狗触发脉冲
    output wire        dbg_bytev,       // 字节握手活动
    output wire [15:0] dbg_pops,        // 弹出样本计数
    output wire [15:0] dbg_wdog_cnt,    // 看门狗触发次数
    output wire [10:0] dbg_rptr,        // 读指针
    output wire [10:0] dbg_wptr,        // 写指针
    output wire [15:0] dbg_lastl,       // 最近写入的 L 样本
    output wire [15:0] dbg_outp_cnt,    // out_tick 计数（测 PSG 节拍）
    output wire [15:0] dbg_byte_cnt,    // 字节握手计数（测 SD 吞吐）
    output wire [15:0] dbg_rate         // YXMA 头解析出的 rate
);

    localparam [15:0] OUT_HZ = 16'd48000;
    // G6: 块推进用扇区数（=CHUNK_BYTES/512），与探针 SECTOR_COUNT 一致。
    // 曾把字节数加到扇区地址上：2,000,000+2,765,312 → 跳到卡上 2.4GB 垃圾区，
    // 表现为第一块(~15.7s)正常、之后全噪音。
    localparam [27:0] CHUNK_SECTORS = CHUNK_BYTES >> 9;

    // ---- 异步 FIFO: 1024 × 32bit（一行 = 一个立体声样本 L/R） ----------------
    wire [9:0]  waddr, raddr;
    wire [31:0] wdata;
    wire        wena;
    wire [31:0] rdata;

    ram_dual_port_simple #(.data_width(32), .data_num(1024)) u_fifo (
        .douta (          ),
        .doutb (rdata     ),
        .dina  (wdata     ),
        .addra (waddr     ),
        .addrb (raddr     ),
        .wea   (wena      ),
        .clka  (sys_clk   ),
        .clkb  (pix_clk   )
    );

    reg  [10:0] wptr;                   // 写指针（sys）
    reg  [10:0] wgray;                  // 写指针格雷码（sys → pix 判空用）
    reg  [10:0] wgray_p1, wgray_p2;     // 2FF 同步（pix）
    reg [10:0] rptr;                   // 读指针（pix）
    reg [15:0] pops;                   // 弹出计数（pix，诊断用）
    reg [15:0] outp_cnt;               // out_tick 计数（pix）
    reg [15:0] byte_cnt;               // 字节握手计数（sys）
    reg  [10:0] rgray;                  // 读指针格雷码（pix）
    reg  [10:0] rgray_s1, rgray_s2;     // 格雷码 2FF 同步（sys）

    wire [10:0] rgray_nxt = (rptr >> 1) ^ rptr;
    wire [10:0] wgray_nxt = (wptr >> 1) ^ wptr;

    always @(posedge pix_clk) begin
        if (pix_rst) rgray <= 11'd0;
        else         rgray <= rgray_nxt;
    end
    always @(posedge sys_clk) begin
        if (sys_rst) wgray <= 11'd0;
        else         wgray <= wgray_nxt;
    end
    // 反格雷（组合前缀异或）
    wire [10:0] wdec;
    assign wdec[10] = wgray_p2[10];
    assign wdec[9]  = wdec[10] ^ wgray_p2[9];
    assign wdec[8]  = wdec[9]  ^ wgray_p2[8];
    assign wdec[7]  = wdec[8]  ^ wgray_p2[7];
    assign wdec[6]  = wdec[7]  ^ wgray_p2[6];
    assign wdec[5]  = wdec[6]  ^ wgray_p2[5];
    assign wdec[4]  = wdec[5]  ^ wgray_p2[4];
    assign wdec[3]  = wdec[4]  ^ wgray_p2[3];
    assign wdec[2]  = wdec[3]  ^ wgray_p2[2];
    assign wdec[1]  = wdec[2]  ^ wgray_p2[1];
    assign wdec[0]  = wdec[1]  ^ wgray_p2[0];

    always @(posedge pix_clk) begin
        if (pix_rst) begin
            wgray_p1 <= 11'd0; wgray_p2 <= 11'd0;
        end
        else begin
            wgray_p1 <= wgray;
            wgray_p2 <= wgray_p1;
        end
    end
    // 反格雷（组合前缀异或），寄存器只做同步对齐
    wire [10:0] rdec;
    assign rdec[10] = rgray_s2[10];
    assign rdec[9]  = rdec[10] ^ rgray_s2[9];
    assign rdec[8]  = rdec[9]  ^ rgray_s2[8];
    assign rdec[7]  = rdec[8]  ^ rgray_s2[7];
    assign rdec[6]  = rdec[7]  ^ rgray_s2[6];
    assign rdec[5]  = rdec[6]  ^ rgray_s2[5];
    assign rdec[4]  = rdec[5]  ^ rgray_s2[4];
    assign rdec[3]  = rdec[4]  ^ rgray_s2[3];
    assign rdec[2]  = rdec[3]  ^ rgray_s2[2];
    assign rdec[1]  = rdec[2]  ^ rgray_s2[1];
    assign rdec[0]  = rdec[1]  ^ rgray_s2[0];

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            rgray_s1 <= 11'd0; rgray_s2 <= 11'd0;
        end
        else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    wire [10:0] occ = wptr - rdec;      // 占用（sys 视角，偏保守）
    assign sd_ready = music_active && (sstate != 2'd2) && (occ < 11'd768);
    // G6: 仅握手拍消费一个字节（valid 在等 ready 时保持高，不能每拍都算）
    wire byte_v = sd_valid && sd_ready;
    assign dbg_sstate = sstate;
    assign dbg_occ    = occ;
    assign dbg_wdog   = wdog_fire;
    always @(posedge sys_clk) begin
        if (sys_rst)         byte_cnt <= 16'd0;
        else if (byte_v)     byte_cnt <= byte_cnt + 16'd1;
    end
    assign dbg_bytev  = byte_v;
    assign dbg_wdog_cnt = wdog_cnt;
    assign dbg_rptr     = rptr;
    assign dbg_wptr     = wptr;
    assign dbg_lastl    = lastl_r;
    assign dbg_pops     = pops;
    assign dbg_outp_cnt = outp_cnt;
    assign dbg_byte_cnt = byte_cnt;
    assign dbg_rate     = rate;

    // ---- sys_clk 域: SD 消费 + YXMA 解析 + 打包 + 分块 -----------------------
    localparam [1:0] S_HDR = 2'd0, S_PLAY = 2'd1, S_DONE = 2'd2;

    reg  [1:0]  sstate;
    reg  [5:0]  hdr_cnt;
    reg  [7:0]  hdr [0:31];
    reg  [15:0] rate;
    reg  [31:0] pcm_left;
    reg  [1:0]  ch;                     // 1=mono 2=stereo
    reg  [21:0] chunk_byte;
    reg  [2:0]  chunk_idx;
    reg  [7:0]  b0, b1, b2, b3;
    reg  [7:0]  hw0, hw1, hw2, hw3;   // 'YXMA' 滑动窗口
    reg  [1:0]  bcnt;
    reg  [27:0] base_acc;
    reg  [23:0] stall;                  // G6diag: 加宽（阈值 ~333ms）
    reg        wdog_fire;               // 看门狗触发观测
    reg [15:0] wdog_cnt;                // 看门狗触发次数
    reg [15:0] lastl_r;                 // 最近写入的 L 样本
    localparam [23:0] WDOG_LIMIT = 24'd16_666_666;   // 333ms @50MHz
    reg        act_d;                   // music_active 上升沿检测（sys）

    wire hdr_magic_ok = (hdr[0] == 8'h59) && (hdr[1] == 8'h58) &&
                        (hdr[2] == 8'h4D) && (hdr[3] == 8'h41);   // 'YXMA'
    wire chunk_end = byte_v && (sstate == S_PLAY) && music_active &&
                     (chunk_byte == CHUNK_BYTES[21:0] - 22'd1);
    wire song_end  = byte_v && (sstate == S_PLAY) && music_active &&
                     (pcm_left == 32'd1);

    assign waddr = wptr[9:0];
    assign wena  = fifo_wr_en_v;
    assign wdata = fifo_wr_d;      // G6: 原漏接 → dina 浮空 → 读出全 z（仿真实锤）

    reg  fifo_wr_en_v;
    reg  [31:0] fifo_wr_d;

    // 打包：stereo 第 4 字节 / mono 第 2 字节到达时落一行
    always @(*) begin
        fifo_wr_en_v = 1'b0;
        fifo_wr_d    = 32'd0;
        if ((sstate == S_PLAY) && byte_v && music_active) begin
            if (ch == 2'd2) begin
                if (bcnt == 2'd3) begin
                    // B0=L低 B1=L高 B2=R低 B3=R高(本拍) → {L[15:0], R[15:0]}
                    fifo_wr_en_v = 1'b1;
                    fifo_wr_d    = {b1, b0, sd_data, b2};
                end
            end
            else begin
                if (bcnt == 2'd1) begin
                    // B0=样本低 B1=样本高(本拍) → 复制到 L/R
                    fifo_wr_en_v = 1'b1;
                    fifo_wr_d    = {b0, sd_data, b0, sd_data};
                end
            end
        end
    end

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            wptr <= 11'd0;
            lastl_r <= 16'd0;
        end
        else if (wena) begin
            wptr <= wptr + 11'd1;
            lastl_r <= fifo_wr_d[31:16];     // L 样本快照
        end
    end

    // 主 FSM（sys）
    always @(posedge sys_clk) begin
        if (sys_rst) begin
            sstate <= S_HDR;  hdr_cnt <= 6'd0;  rate <= 16'd48000;
            pcm_left <= 32'd0; ch <= 2'd2;  chunk_byte <= 22'd0;
            chunk_idx <= 3'd0; bcnt <= 2'd0; base_acc <= MUSIC_BASE;
            stall <= 24'd0; wav_restart <= 1'b0; wav_base <= MUSIC_BASE;
            wdog_fire <= 1'b0; wdog_cnt <= 16'd0;
            wav_active <= 1'b0; act_d <= 1'b0;
            b0 <= 8'd0; b1 <= 8'd0; b2 <= 8'd0; b3 <= 8'd0;
            hw0 <= 8'd0; hw1 <= 8'd0; hw2 <= 8'd0; hw3 <= 8'd0;
        end
        else begin
            wav_restart <= 1'b0;
            act_d       <= music_active;

            if (!music_active) begin
                stall <= 24'd0;                 // 暂停：保持现场
            end
            else begin
                case (sstate)
                S_HDR: if (byte_v) begin
                    // 4 字节滑窗搜 'YXMA'（对循环重启/残留字节都稳）
                    hw0 <= hw1; hw1 <= hw2; hw2 <= hw3; hw3 <= sd_data;
                    chunk_byte <= chunk_byte + 22'd1;
                    if (hdr_cnt == 6'd0) begin
                        if (hw1 == 8'h59 && hw2 == 8'h58 && hw3 == 8'h4D && sd_data == 8'h41) begin
                            hdr[0]   <= 8'h59; hdr[1] <= 8'h58;
                            hdr[2]   <= 8'h4D; hdr[3] <= 8'h41;
                            hdr_cnt  <= 6'd4;
                        end
                    end
                    else begin
                        hdr[hdr_cnt[4:0]] <= sd_data;
                        hdr_cnt <= hdr_cnt + 6'd1;
                        if (hdr_cnt == 6'd31) begin
                            if ((hdr[5] > 8'd2) || (hdr[5] == 8'd0)) begin
                                hdr_cnt <= 6'd0;      // 字段非法 → 重新找头
                            end
                            else begin
                                ch       <= (hdr[5] == 8'd1) ? 2'd1 : 2'd2;
                                rate     <= {hdr[9], hdr[8]};
                                pcm_left <= {hdr[19], hdr[18], hdr[17], hdr[16]};
                                bcnt     <= 2'd0;
                                sstate   <= S_PLAY;
                            end
                        end
                    end
                end
                S_PLAY: if (byte_v) begin
                    case (bcnt)
                    2'd0: b0 <= sd_data;
                    2'd1: b1 <= sd_data;
                    2'd2: b2 <= sd_data;
                    default: b3 <= sd_data;
                    endcase
                    bcnt <= (ch == 2'd1) ? 2'd0 : (bcnt + 2'd1);
                    chunk_byte <= chunk_byte + 22'd1;
                    if (pcm_left != 32'd0) pcm_left <= pcm_left - 32'd1;
                end
                default: ;
                endcase

                // 块边界（先于 song_end 判断，二者互斥：块尾≠歌尾时才推进）
                if (chunk_end && !song_end) begin
                    chunk_byte <= 22'd0;
                    chunk_idx  <= chunk_idx + 3'd1;
                    base_acc   <= base_acc + CHUNK_SECTORS;
                    wav_base   <= base_acc + CHUNK_SECTORS;
                    wav_restart<= 1'b1;
                    stall      <= 24'd0;
                    bcnt       <= 2'd0;
                end

                // 歌曲播完 → 从头循环（BGM 无限播放；S_DONE 只留给非法头）
                if (song_end) begin
                    sstate     <= S_HDR;
                    hdr_cnt    <= 6'd0;
                    chunk_byte <= 22'd0;
                    chunk_idx  <= 3'd0;
                    base_acc   <= MUSIC_BASE;
                    wav_base   <= MUSIC_BASE;
                    wav_restart<= 1'b1;
                    pcm_left   <= 32'd0;
                    bcnt       <= 2'd0;
                    stall      <= 24'd0;
                end

                // G6diag: 断流看门狗重做。旧版 1.31ms(!sd_valid) 阈值与真实节奏
                // 不匹配：SD 取一个扇区本身 ~0.7-1ms，valid 占空比极低 → 每个扇区
                // 间隙都误触发（g27 LED3 高频闪实锤）。真断流 = FIFO 空且久无字节。
                if ((sstate != S_DONE) && !sd_valid && (occ == 11'd0)) begin
                    if (stall == WDOG_LIMIT) begin
                        wav_base   <= base_acc;
                        wav_restart<= 1'b1;
                        stall      <= 24'd0;
                        wdog_fire  <= 1'b1;
                        wdog_cnt   <= wdog_cnt + 16'd1;
                    end
                    else stall <= stall + 24'd1;
                end
                else begin
                    stall <= 24'd0;
                    wdog_fire <= 1'b0;
                end
            end

            // SW4 重新打开（上升沿）→ 从头重放
            if (music_active && !act_d) begin
                sstate     <= S_HDR;
                hdr_cnt    <= 6'd0;
                chunk_byte <= 22'd0;
                chunk_idx  <= 3'd0;
                base_acc   <= MUSIC_BASE;
                wav_base   <= MUSIC_BASE;
                wav_restart<= 1'b1;
                pcm_left   <= 32'd0;
                bcnt       <= 2'd0;
                wav_active <= 1'b1;
                stall      <= 24'd0;
            end
            else if (music_active && (sstate != S_DONE)) begin
                wav_active <= 1'b1;
            end
        end
    end

    // ---- pix_clk 域: 48kHz 节拍 + 按 rate 分数消费 + 输出 --------------------
    // G6: 必须是 32 位！16 位时 (consume_acc + rate_pix) 会静默回绕：
    // rate=44100 时和 >65535 被截断 → 实测只有 4559 次弹出/秒（约 1/9.7 速度）。
    // rate=48000 时 acc 恒 0 恰好不溢出，所以 48k 测试音永远测不出这个 bug。
    reg  [31:0] consume_acc;
    reg  [15:0] rate_pix;
    reg         rate_tick;

    always @(posedge pix_clk) begin
        if (pix_rst) begin
            consume_acc <= 32'd0; rate_pix <= 16'd48000; rate_tick <= 1'b0;
            outp_cnt <= 16'd0;
        end
        else begin
            rate_tick <= 1'b0;
            if (out_tick) begin
                outp_cnt <= outp_cnt + 16'd1;
                if (consume_acc + rate_pix >= OUT_HZ) begin
                    consume_acc <= consume_acc + rate_pix - OUT_HZ;
                    rate_tick   <= 1'b1;
                end
                else consume_acc <= consume_acc + rate_pix;
            end
            // 唯一驱动；健全性钳制：越界（含 0/0xFFFF 垃圾）一律按 48k，
            // 否则 rate_tick 永不触发 → FIFO 有数据却永远弹不出来（实测症状）
            rate_pix <= ((rate >= 16'd8000) && (rate <= 16'd48000)) ? rate : 16'd48000;
        end
    end

    // FIFO 读口（pix，模板的寄存读）
    assign raddr = rptr[9:0];

    wire       pop = rate_tick && wav_active && (rptr != wdec);

    // wptr 跨域给读口判空（多比特计数器，容许 1 拍滞后：空判保守偏安全）
    reg [10:0] wptr_p1, wptr_p2;
    always @(posedge pix_clk) begin
        if (pix_rst) begin
            wptr_p1 <= 11'd0; wptr_p2 <= 11'd0;
        end
        else begin
            wptr_p1 <= wptr;
            wptr_p2 <= wptr_p1;
        end
    end

    always @(posedge pix_clk) begin
        if (pix_rst) begin
            rptr <= 11'd0;
            pops <= 16'd0;
            wav_l <= 24'd0; wav_r <= 24'd0;
        end
        else begin
            if (pop) begin
                rptr <= rptr + 11'd1;
                pops <= pops + 16'd1;
                    // G6: 16bit→24bit 左移 6 位（×64，-12dBFS，宿舍音量）
                    // 1+16+6=23 位，必须双写符号位补满 24 位，否则负样本丢符号
                wav_l <= {{2{rdata[31]}}, rdata[31:16], 6'd0};
                wav_r <= {{2{rdata[15]}}, rdata[15:0],  6'd0};
            end
            else if (rate_tick) begin
                // 弹出节拍但没弹出（FIFO 空/未激活）→ 该拍输出静音。
                // 注意必须挂 rate_tick 而不是 out_tick：rate_tick 晚 out_tick 一拍，
                // 挂 out_tick 会在每拍先清零再被 pop 覆盖 → 混音器锁到 1 拍宽的 0
                wav_l <= 24'd0;
                wav_r <= 24'd0;
            end
            // 其余周期：wav_l/r 保持上一拍的值（不清零）
        end
    end

endmodule
