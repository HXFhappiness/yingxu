// yx_a_vq_sender.v — 板 A：YXV2 码流 → 分片 UDP 发送（**帧锁存**开环节流）
//
// ============================ 为什么是开环 ============================
// 板 B 只收不发：IO_b.adc 只约束了 RGMII RX 侧（eth_rxc/rxd/rxdv/mdc/mdio），
// 没有 TX 引脚，板 B 也没有 125MHz TX 时钟源。所以：
//   · 没有回传/信用通道，A 侧拿不到 B 的真实反压；
//   · 流控只能**开环**——A 必须自己保证不超发。
//
// 而 B 侧的安全边界很窄：
//   · 字节 FIFO 只有 8192 B（yx_b_eth_rx 的 FIFO_AW=13）；
//   · 厂商 RX 核的 payload_valid 无 ready，FIFO 满时只能丢字节，该包在描述符里
//     标 err=1 后**整包丢弃**；UDP 无重传 → 丢一个包就是码流断裂。
//
// ==================== 为什么必须是"帧锁存"而不是"全局限速" ====================
// ★ 2026-11-27 实测（p6_e2e）否定了全局限速方案，这是本模块改成帧锁存的原因。
//
// 最初版本用常数速率（1 字节 / BYTE_DIV 个 clk125），依据是 P5 §5F 的
// "B 实测 6.81 MB/s"。但那个数**不是 B 的能力常数**，而是 VQ-1024 那一条流
// 自己的源码率（114,917 B ÷ 16.87 ms）。B 的消费是**帧锁存**的：每个帧周期
// 只消费一帧的负载字节，消费完就等下一帧。
//
// 后果（vp_720_5f.yxv2，帧长分布 KEY 115,205 / DELTA 8,395 / 7,915 /
// KEY 115,205 / DELTA 18,481）：
//   · 常数 6.25 MB/s（BYTE_DIV=20）→ t≈2.5M 起 drop 0→85，room 8192→39；
//   · 常数 2.98 MB/s（BYTE_DIV=42，已降到源码率以下）→ t≈5.5M 起仍然 drop，
//     因为 **DELTA 帧期间 B 只要 8 KB，而 A 还在按 2.98 MB/s 灌 41 KB**。
//   两轮共同结论：**8 KB FIFO 吸收不了帧内的供需失配**，任何常数速率都会溢出。
//   （两轮的解码质量本身都是好的：FRAME errs=0，所以不是解码问题。）
//
// ⇒ 正确做法：A 也按帧发——把**每一帧自己的字节数**均匀摊到**一个帧周期**里。
//   KEY 帧期间 A 供 5.24 MB/s（B 需 8.3，B 是瓶颈，FIFO 排空）；
//   DELTA 帧期间 A 供 0.38 MB/s（B 秒吃，FIFO 排空）。
//   两侧供需**逐帧对齐**，FIFO 只承受帧内抖动。
//
// ==================== 帧长怎么算（YXV2 格式，权威定义见 tools/sim/gen_golden.py）===
//   文件头 20 B：[0:3]="YXV2" [7:8]=W(LE) [9:10]=H(LE) [12:13]=帧数(LE)
//                [14:15]=码本项数 cbn(LE)
//   码本：cbn × 32 B
//   每帧 5 B 头：kind(0=KEY 1=DELTA) + changed[23:0](LE) + 1B
//     KEY  ：帧长 = 5 + NB×2                     （NB=(W/4)×(H/4)）
//     DELTA：帧长 = 5 + MB + changed×2           （MB=ceil(NB/8)）
//   本模块在收到 5B 帧头后立刻算出帧体字节数（帧长−5），按 T_FRAME_CYC 摊开发。
//
// ==================== 节流常数与依据（不是魔法数字）====================
// ★ 2026-11-27 第二次修正：**KEY 帧起步有死窗，KEY 必须用比 DELTA 更长的周期。**
//
//   帧锁存方案（KEY/DELTA 统一 22ms，5.24 MB/s）在 p6_e2e 实测到 KEY3 起步
//   丢包（drop=8）。POLLETH 缺口曲线（out/sim/p6_e2e_run5.log）：
//     · 序幕+KEY0：B 消费 0.0412~0.0530 B/clk100，缺口 ≤1,483 —— 无死窗；
//     · DELTA1/2：B 逐拍跟踪 A（0~0.0081），缺口 56~1,455 —— 无死窗；
//     · KEY3 起点（7.5→8.25M clk100）：**前 2.5ms B 只消费 347 字节**，之后
//       以 0.027→0.069 追喝。A 仍按 5.24 MB/s 推 → 缺口 2.5ms 内涨 10.7k，
//       超过 FIFO 有效余量 → 丢 8 包。
//   死窗成因：KEY 帧要写 57,600 个索引字，ixwr 的 SDRAM 写带宽被渲染/扫描
//   读占用 → 写 FIFO 满 → ixdec 的 skid 满 → stream_ready=0。KEY0 没有死窗
//   是因为当时还没有渲染争用（第一帧），不代表稳态。
//   死窗之后 B 能以 6.9 MB/s 追喝 —— **能力够，起步死窗才是约束**。
//
//   取值（按帧类型分周期）：
//     死窗实测 ≈2.5ms（B 消费≈0），取 2 倍安全系数 = 5ms。
//     死窗内 A 的累积 ≤ FIFO 有效余量（8192 − A 侧分片 FIFO ~2048 ≈ 6.1KB）
//       ⇒ A 的 KEY 速率 ≤ 6.1KB / 5ms ≈ 1.22 MB/s，取 **1.2 MB/s**。
//     T_KEY_CYC   = 115,200 × 125e6 / 1.2e6 = 12.0M clk125 = 96 ms
//                   （KEY0 无死窗实测可跑 5.24 MB/s，但产品会循环播放，重启后
//                     首个 KEY 同样有争用，故统一取慢值——宁慢勿超。）
//     T_DELTA_CYC = 2.75M clk125 = 22 ms（DELTA 体 7.9~18.5KB → 0.36~0.84
//                   MB/s；DELTA 边界实测无死窗，缺口 ≤1,455，维持不变）
//     PRO_CYC     = 1.0M clk125 = 8 ms（码本 32,768 B → 4.1 MB/s；序幕边界
//                   实测无死窗，缺口 ≤1,483）
//   ⇒ 端到端 KEY 帧有效 13 fps、DELTA 帧正常 —— 这是**有意的保守**。
//     要跑 60fps 无损，B 侧需要更大的入口 FIFO（8KB → ≥64KB）或 A→B 流控
//     反馈；在现有 8KB FIFO + 无回传的前提下，开环无损只有这一条慢路。
//
//   ★ 约束：每个 period 必须 ≥ 该窗的 win_total（KEY 115,200 / DELTA 18,476 /
//     PRO 32,768），否则 Bresenham 的 acc 每拍净增 (win_total − period) 会无界
//     溢出（实测教训：unit test 曾把 period 缩到 27,500 触发此路）。
//
// ============================ 分片 ============================
// UDP payload 上限 1472 B（1500 MTU − 20 IP − 8 UDP）。B 侧厂商核按大包处理
// （其已知缺陷是 payload < 18 B 时在 RX_DATA→RX_DRP_DATA 分支空转 64K 拍），
// 故本模块只发大包：分片填满 FRAG_LEN，每帧末尾的残余分片在帧边界强制发出
// （不跨帧粘连）。本测试流各帧末残余 389/1035/555/389/817 B，均 ≥ 18。
//
// 目的地址必须与板 B 的默认过滤条件完全一致（否则厂商核整包丢弃）：
//   dst_mac = 00:0a:35:02:00:01 / dst_ip = 192.168.0.100 / dst_port = 5000
//
// ============================ 时钟域 ============================
// 单 125M 域（GMII TX 时钟）。码流源（板上 SD 扇区读 / 仿真文件）经
// src_valid/src_data/src_ready 握手跨入本域——板上需自带异步 FIFO 或
// 源本身在 125M 域（仿真 TB 直接产生）。
//
// ★ 接口语义：src_data 必须在 src_valid && src_ready 的**同一拍**给出该字节
//   （FWFT / 组合读出）。这与 eth_udp_tx_gmii 的 payload 接口一致，也避免了
//   "寄存一拍导致整体错位"的经典陷阱（tb_a_sender 初版就踩过：59 59 58 56…）。
module yx_a_vq_sender #(
    parameter [47:0] DST_MAC  = 48'h00_0a_35_02_00_01,
    parameter [31:0] DST_IP   = 32'hc0_a8_00_64,
    parameter [15:0] DST_PORT = 16'd5000,
    parameter [47:0] SRC_MAC  = 48'h00_0a_35_02_00_02,
    parameter [31:0] SRC_IP   = 32'hc0_a8_00_65,
    parameter [15:0] SRC_PORT = 16'd5001,
    // ---- 帧锁存节流（依据见文件头）----
    parameter integer T_KEY_CYC   = 12000000,  // KEY 帧体摊在这么多 clk125 内（96ms）
    parameter integer T_DELTA_CYC =  2750000,  // DELTA 帧体摊在这么多 clk125 内（22ms）
    parameter integer PRO_CYC     =  1000000,  // 码本摊在这么多 clk125 内（8ms）
    // ---- 分片 payload 上限 ----
    parameter [15:0]  FRAG_LEN = 16'd1472,
    // ---- 源空闲多少拍后把残余分片发出（流被截断时的兜底）----
    parameter integer FLUSH_IDLE = 4096
)(
    input  wire        clk125,
    input  wire        rst_p,           // 高有效（与 eth_udp_tx_gmii 一致）

    input  wire        src_valid,
    input  wire [7:0]  src_data,
    output wire        src_ready,

    output wire        gmii_tx_clk,
    output wire [7:0]  gmii_txd,
    output wire        gmii_txen,

    output reg  [31:0] tx_byte_cnt,
    output reg  [15:0] tx_pkt_cnt,
    output reg  [15:0] tx_short_cnt,
    output reg  [15:0] tx_frame_cnt
);

    // =========================================================================
    // 0) 声明
    // =========================================================================
    localparam [2:0] PS_FH0  = 3'd0,   // 收 20B 文件头（直通发出，不收节流）
                     PS_PRO  = 3'd1,   // 码本：摊在 PRO_CYC 内
                     PS_FRH  = 3'd2,   // 收 5B 帧头（直通发出）
                     PS_BODY = 3'd3,   // 帧体：摊在 T_FRAME_CYC 内
                     PS_DONE = 3'd4;

    reg  [2:0]  ps;
    reg  [4:0]  hcnt;            // 文件头已收字节数
    reg  [2:0]  fcnt;            // 帧头已收字节数

    // 文件头字段
    reg  [7:0]  w_lo, w_hi, h_lo, h_hi, nf_lo, nf_hi, cb_lo, cb_hi;
    // 帧头字段
    reg  [7:0]  k_b, ch0, ch1, ch2b;

    reg  [31:0] win_sent;        // 本窗口已发（帧体/码本）字节
    reg  [31:0] win_total;
    reg  [31:0] period;
    reg  [15:0] nf_left;
    reg         flush_req;

    reg  [16:0] nb2;             // NB×2
    reg  [13:0] mb;              // ceil(NB/8)

    wire [31:0] nb32 = ({16'd0, w_hi, w_lo} >> 2) * ({16'd0, h_hi, h_lo} >> 2);

    // =========================================================================
    // 1) Bresenham 速率发生器
    // =========================================================================
    reg  [31:0] acc;
    reg         pace_tick;
    wire        paced = (ps == PS_PRO) || (ps == PS_BODY);

    always @(posedge clk125 or posedge rst_p) begin
        if (rst_p) begin
            acc       <= 32'd0;
            pace_tick <= 1'b0;
        end else if (paced && !flush_req) begin
            if (acc >= period) begin
                acc       <= acc - period;
                pace_tick <= 1'b1;
            end else begin
                acc       <= acc + win_total;
                pace_tick <= 1'b0;
            end
        end else begin
            // ★ flush 等待期必须**冻结**（不丢拍）：窗口把 win_total 字节摊在
            //   period 拍里，是按拍数定的预算。若冻结期继续走 acc，每拍都会
            //   消费一个 tick 而没有对应的 push，窗口收尾时 win_last 永远凑不齐
            //   → 死锁（p6_e2e 实测过同类问题：tx_en_pulse 丢在包间隔里）。
            //   acc 保持不动，flush 结束后从断点续跑，字节数一个不少。
            pace_tick <= 1'b0;
        end
    end

    // =========================================================================
    // 2) 分片 FIFO（先声明，供 push 条件使用）
    // =========================================================================
    reg  [7:0]  frag_mem [0:2047];
    reg  [10:0] frag_wp;
    reg  [10:0] frag_rp;
    reg  [11:0] frag_cnt;
    wire        frag_empty = (frag_cnt == 12'd0);
    wire        frag_full  = (frag_cnt >= FRAG_LEN);
    wire        frag_room  = (frag_cnt < 12'd2048);
    wire        frag_pop;

    reg  [15:0] idle_cnt;
    wire        src_idle_flush = (idle_cnt >= FLUSH_IDLE);

    always @(posedge clk125 or posedge rst_p) begin
        if (rst_p)                     idle_cnt <= 16'd0;
        else if (src_valid)            idle_cnt <= 16'd0;
        else if (idle_cnt != 16'hffff) idle_cnt <= idle_cnt + 16'd1;
    end

    // =========================================================================
    // 3) 字节通过：直通（表头 20B/5B）或 节流（码本/帧体）
    //    ★ 全部 push 都被 flush_req 门控：窗口末的残余分片正在等 S_IDLE 锁存，
    //      若放后续字节（下一窗口的表头/帧体）进 FIFO，残余包会混入他人字节
    //      （最坏 R+5 > 1472 超 MTU）。门控期间节流器同步冻结（见下），字节数
    //      不会丢，只是整窗顺延——"宁慢勿超"。
    // =========================================================================
    wire pass_thru = !flush_req && ((ps == PS_FH0) || (ps == PS_FRH));
    wire win_go    = paced && pace_tick && (win_sent < win_total);
    wire push_byte = src_valid && frag_room && (pass_thru || win_go);
    assign src_ready = frag_room && (pass_thru || win_go);

    wire win_last = push_byte && paced && ((win_sent + 32'd1) >= win_total);

    // flush 置位条件（窗口收尾 / 流截断兜底），供单驱动点使用
    wire flush_set = win_last || (paced && src_idle_flush && !src_valid);

    // =========================================================================
    // 4) 解析状态机
    // =========================================================================
    // 帧体字节数 = 帧长 − 5
    wire [16:0] body_key = nb2;                                    // KEY: NB×2
    wire [16:0] body_del = {3'b000, mb} + {ch2b, ch1, ch0, 1'b0};  // DELTA: MB + ch×2
    wire [16:0] body_len = (k_b == 8'd0) ? body_key : body_del;

    always @(posedge clk125 or posedge rst_p) begin
        if (rst_p) begin
            ps        <= PS_FH0;
            hcnt      <= 5'd0;
            fcnt      <= 3'd0;
            win_sent  <= 32'd0;
            win_total <= 32'd0;
            period    <= PRO_CYC;
            nf_left   <= 16'd0;
            flush_req <= 1'b0;
            nb2       <= 17'd0;
            mb        <= 14'd0;
            w_lo<=0; w_hi<=0; h_lo<=0; h_hi<=0;
            nf_lo<=0; nf_hi<=0; cb_lo<=0; cb_hi<=0;
            k_b<=0; ch0<=0; ch1<=0; ch2b<=0;
        end else begin
            // ---- 收表头字节（同时直通发出）----
            if (push_byte && (ps == PS_FH0)) begin
                case (hcnt)
                5'd7 : w_lo  <= src_data;
                5'd8 : w_hi  <= src_data;
                5'd9 : h_lo  <= src_data;
                5'd10: h_hi  <= src_data;
                5'd12: nf_lo <= src_data;
                5'd13: nf_hi <= src_data;
                5'd14: cb_lo <= src_data;
                5'd15: cb_hi <= src_data;
                default: ;
                endcase
                hcnt <= hcnt + 5'd1;
            end
            if (push_byte && (ps == PS_FRH)) begin
                case (fcnt)
                3'd0: k_b  <= src_data;
                3'd1: ch0  <= src_data;
                3'd2: ch1  <= src_data;
                3'd3: ch2b <= src_data;
                default: ;
                endcase
                fcnt <= fcnt + 3'd1;
            end

            // ---- 窗口计数 ----
            if (push_byte && paced) win_sent <= win_sent + 32'd1;

            // ---- 状态迁移 ----
            case (ps)
            PS_FH0: if (push_byte && (hcnt == 5'd19)) begin
                nb2       <= {nb32[15:0], 1'b0};
                mb        <= (nb32[15:0] + 16'd7) >> 3;
                nf_left   <= {nf_hi, nf_lo};
                win_total <= {16'd0, cb_hi, cb_lo} << 5;   // cbn×32
                period    <= PRO_CYC;
                win_sent  <= 32'd0;
                acc       <= 32'd0;
                hcnt      <= 5'd0;
                ps        <= PS_PRO;
            end

            PS_PRO: if (win_last) begin
                win_sent  <= 32'd0;
                acc       <= 32'd0;
                fcnt      <= 3'd0;
                ps        <= PS_FRH;
            end

            PS_FRH: if (push_byte && (fcnt == 3'd4)) begin
                win_total <= {15'd0, body_len};
                // ★ 按帧类型选周期：KEY（重载 + 起步死窗）用长周期，DELTA 用短周期
                period    <= (k_b == 8'd0) ? T_KEY_CYC : T_DELTA_CYC;
                win_sent  <= 32'd0;
                acc       <= 32'd0;
                fcnt      <= 3'd0;
                ps        <= PS_BODY;
            end

            PS_BODY: if (win_last) begin
                win_sent  <= 32'd0;
                acc       <= 32'd0;
                nf_left   <= nf_left - 16'd1;
                fcnt      <= 3'd0;
                if (nf_left == 16'd1) ps <= PS_DONE;
                else                  ps <= PS_FRH;
            end

            default: ;   // PS_DONE
            endcase

            // 兜底：流被截断时不要在窗口里死等
            if (paced && src_idle_flush && !src_valid) begin
                ps <= PS_DONE;
            end

            // flush_req：**置优先于清**（单驱动点，见下方 flush_set）。
            // ★ 清除不能等到 PS_DONE：若某窗口字节数恰为 1472 整倍数（残余 0），
            //   flush_req 会一路挂进下一帧，S_IDLE 一见 FIFO 非空就把刚到的几个
            //   字节当"残余"打成小包，破坏分片节奏。规则：S_IDLE 见到即消费——
            //   非空时 FSM 同拍已按旧 frag_cnt 锁存残余发出（旧值，不混入新字节）；
            //   空则无事可冲，直接放开。
            if (flush_set)         flush_req <= 1'b1;
            else if (st == S_IDLE) flush_req <= 1'b0;
        end
    end

    // =========================================================================
    // 5) 分片 FIFO 读写（单 always，指针+计数单驱动）
    // =========================================================================
    always @(posedge clk125 or posedge rst_p) begin
        if (rst_p) begin
            frag_wp  <= 11'd0;
            frag_rp  <= 11'd0;
            frag_cnt <= 12'd0;
        end else begin
            case ({push_byte, frag_pop})
            2'b10: begin
                frag_mem[frag_wp] <= src_data;
                frag_wp  <= frag_wp + 11'd1;
                frag_cnt <= frag_cnt + 12'd1;
            end
            2'b01: begin
                frag_rp  <= frag_rp + 11'd1;
                frag_cnt <= frag_cnt - 12'd1;
            end
            2'b11: begin
                frag_mem[frag_wp] <= src_data;
                frag_wp  <= frag_wp + 11'd1;
                frag_rp  <= frag_rp + 11'd1;
            end
            default: ;
            endcase
        end
    end

    // =========================================================================
    // 6) 分片级发送 FSM
    //    ★ tx_done 之后必须等包间隔结束才能发下一包：
    //      eth_udp_tx_gmii 只在 curr_state==IDLE 时接受 tx_en_pulse（其 :462），
    //      而 tx_done 在 TX_CRC/cnt_crc==3 就置位，之后核还要走 **64 拍包间隔**
    //      才回 IDLE。若 tx_done 后立刻 pulse，脉冲落在间隔里被**丢弃**，
    //      FSM 就永远卡在 S_FEED 等 payload_req（p6_e2e 实测：序幕 23 包发完后
    //      死锁，fcnt=2048、st=2、preq=0）。旧版每包间隔 2.9 万拍没暴露；
    //      FIFO 满后包背靠背就必然暴露。
    //      ⇒ 加 S_GAP：tx_done 后等 70 拍（≥ 64 + 余量）再回 S_IDLE。
    // =========================================================================
    localparam [2:0] S_IDLE  = 3'd0,   // 等一个可发的分片
                     S_START = 3'd1,   // 置 tx_en_pulse（data_length 已稳定）
                     S_FEED  = 3'd2,   // 按 payload_req 逐字节喂
                     S_WAIT  = 3'd3,   // 等 tx_done
                     S_GAP   = 3'd4;   // 包间隔：等核回 IDLE（≥64 拍）

    reg  [2:0]  st;
    reg  [7:0]  gap_cnt;
    reg         tx_en_pulse;
    reg  [15:0] frag_bytes;
    reg  [15:0] frag_rd;
    wire        tx_done;
    wire        payload_req;

    wire feed_go  = (st == S_FEED) && (frag_rd < frag_bytes);
    assign frag_pop = payload_req && feed_go && !frag_empty;
    wire [7:0] frag_head = frag_mem[frag_rp];

    always @(posedge clk125 or posedge rst_p) begin
        if (rst_p) begin
            st          <= S_IDLE;
            gap_cnt     <= 8'd0;
            tx_en_pulse <= 1'b0;
            frag_bytes  <= 16'd0;
            frag_rd     <= 16'd0;
        end else begin
            tx_en_pulse <= 1'b0;
            case (st)
            S_IDLE: begin
                if (frag_full || (flush_req && !frag_empty) ||
                    (src_idle_flush && !frag_empty)) begin
                    // ★ 必须 {4'b0, frag_cnt}：frag_cnt 是 12 位，越界位选在
                    //   iverilog 下返回 X 且不告警 → FSM 永久挂死。
                    frag_bytes <= frag_full ? FRAG_LEN : {4'b0, frag_cnt};
                    frag_rd    <= 16'd0;
                    st         <= S_START;
                end
            end
            S_START: begin
                tx_en_pulse <= 1'b1;
                st          <= S_FEED;
            end
            S_FEED: begin
                if (frag_pop) begin
                    frag_rd <= frag_rd + 16'd1;
                    if (frag_rd + 16'd1 >= frag_bytes) st <= S_WAIT;
                end
            end
            S_WAIT: if (tx_done) begin
                gap_cnt <= 8'd0;
                st      <= S_GAP;
            end
            S_GAP: begin
                gap_cnt <= gap_cnt + 8'd1;
                if (gap_cnt >= 8'd70) st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 7) 厂商发送核
    // =========================================================================
    eth_udp_tx_gmii u_tx (
        .clk125m        (clk125),
        .reset_p        (rst_p),
        .tx_en_pulse    (tx_en_pulse),
        .tx_done        (tx_done),
        .dst_mac        (DST_MAC),
        .src_mac        (SRC_MAC),
        .dst_ip         (DST_IP),
        .src_ip         (SRC_IP),
        .dst_port       (DST_PORT),
        .src_port       (SRC_PORT),
        .data_length    (frag_bytes),
        .payload_req_o  (payload_req),
        .payload_dat_i  (frag_head),
        .gmii_tx_clk    (gmii_tx_clk),
        .gmii_txen      (gmii_txen),
        .gmii_txd       (gmii_txd)
    );

    // =========================================================================
    // 8) 观测计数
    // =========================================================================
    always @(posedge clk125 or posedge rst_p) begin
        if (rst_p) begin
            tx_byte_cnt  <= 32'd0;
            tx_pkt_cnt   <= 16'd0;
            tx_short_cnt <= 16'd0;
            tx_frame_cnt <= 16'd0;
        end else begin
            if (push_byte) tx_byte_cnt <= tx_byte_cnt + 32'd1;
            if (tx_done) begin
                tx_pkt_cnt <= tx_pkt_cnt + 16'd1;
                if (frag_bytes != FRAG_LEN) tx_short_cnt <= tx_short_cnt + 16'd1;
            end
            if ((ps == PS_BODY) && win_last) tx_frame_cnt <= tx_frame_cnt + 16'd1;
        end
    end

endmodule
