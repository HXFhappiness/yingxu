// yx_a_vq_sender.v — 板 A：YXV2 码流 → 分片 UDP 发送（开环节流）
//
// ============================ 为什么是开环 ============================
// 板 B 只收不发：IO_b.adc 只约束了 RGMII RX 侧（eth_rxc/rxd/rxdv/mdc/mdio），
// 没有 TX 引脚，板 B 也没有 125MHz TX 时钟源。所以：
//   · 没有回传/信用通道，A 侧拿不到 B 的真实反压；
//   · 流控只能**开环**——A 必须自己保证不超发。
//
// 而 B 侧的安全边界很窄：
//   · 字节 FIFO 只有 8192 B（yx_b_eth_rx 的 FIFO_AW=13），而一帧真实 VQ-1024 码流
//     是 114,917 B → **整帧突发必然溢出**；
//   · 厂商 RX 核的 payload_valid 无 ready，FIFO 满时只能丢字节，该包在描述符里
//     标 err=1 后**整包丢弃**；UDP 无重传 → 丢一个包就是码流断裂；
//   · 因此必须把一帧字节按帧周期**摊平**发送，且速率不得超过 B 的消费能力。
//
// ==================== B 端消费能力（实测依据，不是猜的）====================
// ★ 2026-11-27 修正：下面这段原始的"6.81 MB/s = B 能力"**推理是错的**，
//   端到端实测（p6_e2e，BYTE_DIV=20）以 drop=85 证实。保留原文并在后面
//   写清错在哪，避免后人再踩。
//
// ---- 原推理（P5 §5F / commit 144e2e5）----
//   真实 VQ-1024 流 `xinji_720p24.yxv2`：114,917 B/帧
//   B 侧稳态帧周期（帧 4→帧 5 实测）：1,687,455 clk100 = 16.87 ms
//   ⇒ 114,917 B / 1,687,455 clk100 = 1 字节 / 14.68 clk100 = 6.81 MB/s
//
// ---- 错在哪（p6_e2e 实测修正）----
//   6.81 MB/s 是**那一条码流自己的源码率**（它的每帧字节 ÷ 帧周期），
//   不是可以外推到别的码流的"B 能力常数"。B 的消费是**帧锁存**的：
//   每个帧周期只消费一帧的负载字节，消费完就等下一帧（实测 t=2.50M 之后
//   1.5M 拍内几乎不再消费：bytes 155,198 → 155,244）。
//   而 8 KB 字节 FIFO 只容忍约 8 KB 的超前量（FIFO_AW=13），所以
//     **A 的速率一旦快于"本源流的源码率"，超前量就单调累积 → 必然溢出。**
//
//   实测（vp_720_5f.yxv2，59,597.8 B/帧）：
//     · 源码率 = 59,597.8 B ÷ 1,687,455 clk100 = 3.532 MB/s（按 P5 帧周期）
//                （若按本轮实测帧间隔 1,395,301 clk100 则 4.271 MB/s）
//     · BYTE_DIV=20 ⇒ 6.25 MB/s = 源码率的 177% → t≈2.5M 起 drop 持续增长
//       （drop=5→85，room 8192→39），而同期 FSM/解码全绿（FRAME errs=0），
//       说明**不是解码错，纯粹是发送超发**。
//
// ---- 本模块的取值规则（不是魔法数字，按此式推导）----
//     BYTE_DIV = clk125_Hz / (源码率 × 安全系数)
//     源码率  = 每帧源字节 ÷ 帧周期      ← 由码流自己决定，不是常数
//     安全系数取 0.85（"宁可比目标慢，不可超发"：B 侧丢一个包就整段码流
//       断裂且无重传，FIFO 满时厂商核整包丢弃）
//   对本测试流：3.532 MB/s × 0.85 = 3.00 MB/s
//              125e6 / 3.00e6 = 41.6 → **BYTE_DIV = 42**（实发 2.976 MB/s，
//              为保守源码率的 84%，为实测帧间隔口径源码率的 70%）
//   ⇒ 端到端比实时慢（vp_720_5f 约 42 fps 等效），这是**有意的保守**。
//   要跑满帧率，只能让 A 按帧节拍发（解析 YXV2 帧头、每帧字节摊到帧周期内），
//   而不是靠调小 BYTE_DIV——后者在开环下必然溢出。
//
// ============================ 分片 ============================
// UDP payload 上限 1472 B（1500 MTU − 20 IP − 8 UDP）。B 侧厂商核按大包处理
// （其已知缺陷是 payload < 18 B 时在 RX_DATA→RX_DRP_DATA 分支空转 64K 拍，
//   见 yx_b_eth_rx.v 头注释），故本模块只发大包：除**流末尾的最后一片**外，
//   其余分片都填满 FRAG_LEN。
//
// 目的地址必须与板 B 的默认过滤条件完全一致（否则厂商核整包丢弃）：
//   dst_mac = 00:0a:35:02:00:01
//   dst_ip  = 192.168.0.100
//   dst_port= 5000
//
// ============================ 时钟域 ============================
// 单 125M 域（GMII TX 时钟）。码流源（板上 SD 扇区读 / 仿真文件）经
// src_valid/src_data/src_ready 握手跨入本域——板上需自带异步 FIFO 或
// 源本身在 125M 域（仿真 TB 直接产生）。
module yx_a_vq_sender #(
    // ---- 目的地址（必须与板 B 默认过滤一致）----
    parameter [47:0] DST_MAC  = 48'h00_0a_35_02_00_01,   // 板 B LOCAL_MAC
    parameter [31:0] DST_IP   = 32'hc0_a8_00_64,         // 192.168.0.100 = 板 B LOCAL_IP
    parameter [15:0] DST_PORT = 16'd5000,                // 板 B LOCAL_PORT
    // ---- 源地址（板 A 自己）----
    parameter [47:0] SRC_MAC  = 48'h00_0a_35_02_00_02,
    parameter [31:0] SRC_IP   = 32'hc0_a8_00_65,         // 192.168.0.101
    parameter [15:0] SRC_PORT = 16'd5001,
    // ---- 开环节流：1 字节 / BYTE_DIV 个 clk125（依据见文件头"取值规则"）----
    // ★ 必须按"本源流的源码率"推导，不能照搬别的码流的 MB/s：
    //   BYTE_DIV = clk125_Hz / (源码率 × 0.85)，源码率 = 每帧字节 ÷ 帧周期。
    //   默认 42 对应 vp_720_5f（59,597.8 B/帧 ÷ 16.87 ms = 3.532 MB/s）× 0.85。
    parameter integer BYTE_DIV = 42,
    // ---- 分片 payload 上限（1 片 1472 B，最后一片可短）----
    parameter [15:0]  FRAG_LEN = 16'd1472,
    // ---- 源空闲多少拍后把残余分片发出（流末尾）----
    parameter integer FLUSH_IDLE = 4096
)(
    input  wire        clk125,
    input  wire        rst_p,           // 高有效（与 eth_udp_tx_gmii 一致）

    // ---- 码流字节源（.yxv2 原样字节流）----
    input  wire        src_valid,
    input  wire [7:0]  src_data,
    output wire        src_ready,       // 受节流器约束：每 BYTE_DIV 拍最多收 1 字节

    // ---- GMII TX（板上再接 gmii_to_rgmii）----
    output wire        gmii_tx_clk,
    output wire [7:0]  gmii_txd,
    output wire        gmii_txen,

    // ---- 观测 ----
    output reg  [31:0] tx_byte_cnt,     // 已发出的 payload 字节总数
    output reg  [15:0] tx_pkt_cnt,      // 已发出的报文数
    output reg  [15:0] tx_short_cnt     // 未填满的分片数（正常只应出现在流末尾）
);

    // =========================================================================
    // 1) 发送节流器：1 字节 / BYTE_DIV clk125
    // =========================================================================
    reg  [15:0] pace_cnt;
    reg         pace_tick;              // 1 拍脉冲：本拍允许取 1 个源字节
    always @(posedge clk125 or posedge rst_p) begin
        if (rst_p) begin
            pace_cnt  <= 16'd0;
            pace_tick <= 1'b0;
        end else begin
            if (pace_cnt >= BYTE_DIV - 1) begin
                pace_cnt  <= 16'd0;
                pace_tick <= 1'b1;
            end else begin
                pace_cnt  <= pace_cnt + 16'd1;
                pace_tick <= 1'b0;
            end
        end
    end

    // =========================================================================
    // 2) 分片缓冲：2 KB FIFO（够放一个 1472B 分片）
    //    ★ 指针与计数只在本块内驱动（单驱动，避免多 always 赋值）
    // =========================================================================
    reg  [7:0]  frag_mem [0:2047];
    reg  [10:0] frag_wp;
    reg  [10:0] frag_rp;
    reg  [11:0] frag_cnt;

    wire frag_empty = (frag_cnt == 12'd0);
    wire frag_full  = (frag_cnt >= FRAG_LEN);
    wire frag_room  = (frag_cnt < 12'd2048);

    // 源收：节流器放行 + FIFO 有位 + 源有数据
    wire src_take = pace_tick && frag_room && src_valid;
    assign src_ready = pace_tick && frag_room;

    // 分片弹出（由 FSM 组合给出）
    wire frag_pop;

    always @(posedge clk125 or posedge rst_p) begin
        if (rst_p) begin
            frag_wp  <= 11'd0;
            frag_rp  <= 11'd0;
            frag_cnt <= 12'd0;
        end else begin
            case ({src_take, frag_pop})
            2'b10: begin                       // 只写
                frag_mem[frag_wp] <= src_data;
                frag_wp  <= frag_wp + 11'd1;
                frag_cnt <= frag_cnt + 12'd1;
            end
            2'b01: begin                       // 只读
                frag_rp  <= frag_rp + 11'd1;
                frag_cnt <= frag_cnt - 12'd1;
            end
            2'b11: begin                       // 同拍读写：计数不变
                frag_mem[frag_wp] <= src_data;
                frag_wp  <= frag_wp + 11'd1;
                frag_rp  <= frag_rp + 11'd1;
            end
            default: ;                          // 空
            endcase
        end
    end

    // 源空闲计时：把流末尾的残余分片发出去
    reg  [15:0] idle_cnt;
    always @(posedge clk125 or posedge rst_p) begin
        if (rst_p)                     idle_cnt <= 16'd0;
        else if (src_valid)            idle_cnt <= 16'd0;
        else if (idle_cnt != 16'hffff) idle_cnt <= idle_cnt + 16'd1;
    end
    wire src_idle_flush = (idle_cnt >= FLUSH_IDLE);

    // =========================================================================
    // 3) 分片级发送 FSM
    // =========================================================================
    localparam S_IDLE = 2'd0,       // 等一个可发的分片
               S_START= 2'd1,       // 置 tx_en_pulse（data_length 已稳定）
               S_FEED = 2'd2,       // 按 payload_req 逐字节喂
               S_WAIT = 2'd3;       // 等 tx_done

    reg  [1:0]  st;
    reg         tx_en_pulse;
    reg  [15:0] frag_bytes;             // 本分片长度（送 data_length）
    reg  [15:0] frag_rd;                // 本分片已喂字节数
    wire        tx_done;
    wire        payload_req;

    // 喂字节条件：在 S_FEED 且本分片还没喂完且 FIFO 非空且厂商要字节
    wire feed_go  = (st == S_FEED) && (frag_rd < frag_bytes);
    assign frag_pop = payload_req && feed_go && !frag_empty;
    wire [7:0] frag_head = frag_mem[frag_rp];

    always @(posedge clk125 or posedge rst_p) begin
        if (rst_p) begin
            st          <= S_IDLE;
            tx_en_pulse <= 1'b0;
            frag_bytes  <= 16'd0;
            frag_rd     <= 16'd0;
        end else begin
            tx_en_pulse <= 1'b0;
            case (st)
            S_IDLE: begin
                // 满片优先；否则源空闲后把残余发出（流末尾）
                if (frag_full || (src_idle_flush && !frag_empty)) begin
                    // ★ 必须 {4'b0, frag_cnt} 而不是 frag_cnt[15:0]：frag_cnt 是
                    //   12 位，越界位选在 iverilog 下返回 **X 且不告警** → 进入
                    //   S_FEED 后 (frag_rd < X) 恒假，FSM 永久挂死（实测现象：
                    //   流末尾残留分片永远发不出，整个仿真空转到看门狗）。
                    frag_bytes <= frag_full ? FRAG_LEN : {4'b0, frag_cnt};
                    frag_rd    <= 16'd0;
                    st         <= S_START;
                end
            end
            S_START: begin
                // data_length 已在上一拍锁存为 frag_bytes，本拍发起
                tx_en_pulse <= 1'b1;
                st          <= S_FEED;
            end
            S_FEED: begin
                // payload_req 为高时厂商在**本拍**采样 payload_dat_i（FWFT 语义：
                // 参考 eth_udp_loopback_rgmii.v 的 .re/.dout 接法）
                if (frag_pop) begin
                    frag_rd <= frag_rd + 16'd1;
                    if (frag_rd + 16'd1 >= frag_bytes) st <= S_WAIT;
                end
            end
            S_WAIT: if (tx_done) st <= S_IDLE;
            default: st <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 4) 厂商发送核
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
    // 5) 观测计数
    // =========================================================================
    always @(posedge clk125 or posedge rst_p) begin
        if (rst_p) begin
            tx_byte_cnt  <= 32'd0;
            tx_pkt_cnt   <= 16'd0;
            tx_short_cnt <= 16'd0;
        end else begin
            if (frag_pop)      tx_byte_cnt  <= tx_byte_cnt + 32'd1;
            if (tx_done) begin
                tx_pkt_cnt <= tx_pkt_cnt + 16'd1;
                if (frag_bytes != FRAG_LEN) tx_short_cnt <= tx_short_cnt + 16'd1;
            end
        end
    end

endmodule