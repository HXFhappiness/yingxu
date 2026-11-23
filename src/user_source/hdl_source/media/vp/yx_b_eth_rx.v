// yx_b_eth_rx.v — 板 B 以太网 UDP 入口（GMII/RGMII → YXV2 字节流）
//
// 数据流：
//   PHY(GMII 125M) → eth_udp_rx_gmii（厂商：Eth/IP/UDP 头校验 + CRC32 校验）
//     → payload_valid/dat（125M 域，1 字节/拍，**无背压**）
//     → 字节异步 FIFO（125M→100M，正文见 yx_b_afifo）
//     → 包描述符 FIFO（{err,len}，包级提交）
//     → 100M 域字节流（stream_valid/data/ready，直连 hdr_parse）
//
// ★ 为什么需要这一层（P4 设计要点）：
//   1) 时钟域不同：PHY 125M，板 B 全部视频逻辑 100M（Sdram_PLL clk0）；
//   2) 厂商 RX 核的 payload_valid 没有 ready，必须无条件接收——不能直接挂到
//      带反压的 hdr_parse 上；
//   3) 厂商 CRC 在整帧收完后才判定（PKT_CHECK 拍给 pkt_error），此前 payload
//      已流出。本层用"包级提交"保证坏包字节不会进入解码链：
//      坏包 → 描述符 err=1 → 100M 侧整段丢弃（只弹不转发）；
//   4) vendor FIFO 满（无流控）时本层被迫少写字节 → 该包在描述符里标 err=1
//      并计入 drop 计数（UDP 无重传；整段码流需由发送端重发，hdr_parse 的
//      magic/参数校验会拦截错位流）。
//
// ★ 与 A 板的差异（勿混）：
//   · 复位极性：本模块对上层暴露 rst_n（低有效）；内部转成厂商要求的
//     reset_p（高有效，异步）；
//   · 100M 控制域与本模块同域（A 板是单 125M 域 + 厂商 eth_data_buf 单时钟）。
//
// ★ 板上约束（P5）：eth_udp_rx_gmii 内部用 BUFG_0 直连 PHY 时钟；RGMII 模式
//   走 rgmii_to_gmii（IDDR）。两者在 td 工程中都是厂商原语，本文件不改厂商件。
//
// 已知限制：
//   · UDP 载荷 < 18 字节时厂商 RX 核（RX_DATA→RX_DRP_DATA 分支）会空转 64K 拍
//     （rx_data_length < 18 的既有缺陷）——本协议只用大包，TB 亦不发小包；
//   · 无 802.3x PAUSE 流控、无 IP 分片重组：发送端须按本层 room 节流
//     （全链路 TB 就是这么做的），或由上层协议做整段重传。

module yx_b_eth_rx #(
    parameter USE_RGMII = 0,        // 0=GMII 直连；1=RGMII（rgmii_to_gmii）
    parameter FIFO_AW   = 13,       // 字节 FIFO 深度 2^13 = 8KB
    parameter DESC_AW   = 3         // 包描述符 FIFO 深度 8
)(
    // ---- 100M 逻辑域（与 yingxu_vq_board_top 同域）----
    input  wire        clk100,
    input  wire        rst_n,           // 低有效；内部转厂商 reset_p

    // ---- 静态配置（厂商核在 IDLE 拍锁存；静态值无 CDC 风险）----
    input  wire [47:0] local_mac,
    input  wire [31:0] local_ip,
    input  wire [15:0] local_port,

    // ---- GMII（125M，PHY 直连；USE_RGMII=0 时有效）----
    input  wire        gmii_rx_clk,
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rxdv,

    // ---- RGMII（USE_RGMII=1 时有效；仿真恒 0）----
    input  wire        rgmii_rx_clk,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rxdv,

    // ---- 字节流出口（100M 域，直连 hdr_parse in_*）----
    output wire        stream_valid,
    output wire [7:0]  stream_data,
    input  wire        stream_ready,

    // ---- 遥测 ----
    output wire [15:0] pkt_ok_cnt,      // 100M 域：好包计数（描述符按序处理）
    output wire [15:0] pkt_drop_cnt,    // 100M 域：坏包/丢字节计数
    output wire [31:0] byte_cnt,        // 100M 域：已转发字节
    output wire [15:0] fifo_room,       // 125M 域：字节 FIFO 空余（发送端节流用）
    output wire        rx_clk125        // 厂商 BUFG 输出（观测）
);

    localparam DEPTH = (1 << FIFO_AW);

    // =====================================================================
    // 1) 物理层接入：GMII / RGMII 选择
    // =====================================================================
    wire        gmii_clk_i;
    wire [7:0]  gmii_rxd_i;
    wire        gmii_rxdv_i;
    wire        gmii_rxer_i;

    generate if (USE_RGMII) begin : RGM
        rgmii_to_gmii u_r2g (
            .reset        (~rst_n),
            .rgmii_rx_clk (rgmii_rx_clk),
            .rgmii_rxd    (rgmii_rxd),
            .rgmii_rxdv   (rgmii_rxdv),
            .gmii_rx_clk  (gmii_clk_i),
            .gmii_rxdv    (gmii_rxdv_i),
            .gmii_rxd     (gmii_rxd_i),
            .gmii_rxer    (gmii_rxer_i)
        );
    end else begin : GMI
        assign gmii_clk_i  = gmii_rx_clk;
        assign gmii_rxd_i  = gmii_rxd;
        assign gmii_rxdv_i = gmii_rxdv;
        assign gmii_rxer_i = 1'b0;
    end endgenerate

    // =====================================================================
    // 2) 厂商 UDP RX 核（125M 域）
    // =====================================================================
    wire        clk125;
    wire        pv;                 // payload valid（无背压）
    wire [7:0]  pdat;
    wire [15:0] rx_len;             // IP 总长 - 28（= UDP 载荷长度）
    wire        op_done;            // 整帧收完（1 拍）
    wire        pkt_err;            // 与 op_done 同拍有效
    wire [31:0] crc_dbg;

    wire        rst_p = ~rst_n;
    wire        data_ovf;           // RX_DATA 期间 FIFO 满（厂商核据此置 pkt_error）

    eth_udp_rx_gmii u_mac (
        .reset_p            (rst_p),
        .local_mac          (local_mac),
        .local_ip           (local_ip),
        .local_port         (local_port),
        .clk125m_o          (clk125),
        .exter_mac          (),
        .exter_ip           (),
        .exter_port         (),
        .rx_data_length     (rx_len),
        .data_overflow_i    (data_ovf),
        .payload_valid_o    (pv),
        .payload_dat_o      (pdat),
        .one_pkt_done       (op_done),
        .pkt_error          (pkt_err),
        .debug_crc_check    (crc_dbg),
        .gmii_rx_clk        (gmii_clk_i),
        .gmii_rxdv          (gmii_rxdv_i),
        .gmii_rxd           (gmii_rxd_i)
    );
    assign rx_clk125 = clk125;

    // =====================================================================
    // 3) 域复位（异步置位 / 同步释放）
    // =====================================================================
    reg [1:0] rsw = 2'b11, rsr = 2'b11;  // 125M / 100M
    always @(posedge clk125 or negedge rst_n)
        if (!rst_n) rsw <= 2'b11;
        else        rsw <= {rsw[0], 1'b0};
    always @(posedge clk100 or negedge rst_n)
        if (!rst_n) rsr <= 2'b11;
        else        rsr <= {rsr[0], 1'b0};
    wire wr_rst = rsw[1];
    wire rd_rst = rsr[1];

    // =====================================================================
    // 4) 写侧（125M）：包边界跟踪 + 字节入 FIFO + 包级提交
    // =====================================================================
    wire [FIFO_AW:0] byte_occ;
    wire        byte_full;
    wire        byte_wr;
    wire        desc_full;

    reg         pv_q = 1'b0;
    reg         in_pkt = 1'b0;
    reg         bad_pkt = 1'b0;
    reg         skip_pkt = 1'b0;    // 包首判定不可收（空间/描述符不足）→ 整包不入 FIFO
    reg  [15:0] wcnt = 16'd0;       // 本包已见 payload 字节数
    reg  [15:0] wwritten = 16'd0;   // 本包实际写入 FIFO 的字节数
    wire        pkt_start = pv & ~pv_q;

    // ★ 包首准入（P4 健壮性）：字节 FIFO 能整包容纳 **且** 描述符 FIFO 有空位。
    //   只做逐字节满判断不够：小包（如 18B 载荷）每个只占很少字节空间，可能
    //   在 8KB 里积压几百个包 → 描述符 FIFO（8 深）溢写。整包准入从根上消除。
    //   不可收 → 该包一个字节都不写、不产生描述符（读侧无需跳过），计入 drop。
    wire [16:0] need17  = {1'b0, rx_len} + 17'd16;
    wire        start_ok = !desc_full && ({1'b0, fifo_room} >= need17);

    // FIFO 写：准入通过才写；中途满则跳过该字节（bad_pkt 置位 → 整包标 err）
    assign byte_wr = pv & (in_pkt | pkt_start) & !byte_full & !skip_pkt;

    // 让厂商核在 RX_DATA 期间感知溢出（其内部置 pkt_error）
    assign data_ovf = pv & byte_full;

    reg         desc_wr = 1'b0;
    reg  [15:0] desc_din = 16'd0;

    always @(posedge clk125 or posedge wr_rst) begin
        if (wr_rst) begin
            pv_q     <= 1'b0;
            in_pkt   <= 1'b0;
            bad_pkt  <= 1'b0;
            skip_pkt <= 1'b0;
            wcnt     <= 16'd0;
            wwritten <= 16'd0;
            desc_wr  <= 1'b0;
            desc_din <= 16'd0;
        end else begin
            pv_q    <= pv;
            desc_wr <= 1'b0;

            if (pv) begin
                if (pkt_start) begin
                    in_pkt   <= 1'b1;
                    skip_pkt <= ~start_ok;
                    wcnt     <= 16'd1;
                    wwritten <= byte_wr ? 16'd1 : 16'd0;
                    bad_pkt  <= ~byte_wr;
                end else begin
                    wcnt <= wcnt + 16'd1;
                    if (byte_wr) wwritten <= wwritten + 16'd1;
                    else         bad_pkt  <= 1'b1;
                end
            end

            // 包收尾：pkt_error 在 op_done 同拍有效；wcnt 应与 rx_len 相等。
            // 准入被拒的包（skip_pkt）未写任何字节 → 不发描述符（读侧无须跳过）。
            if (op_done) begin
                in_pkt   <= 1'b0;
                skip_pkt <= 1'b0;
                if (!skip_pkt) begin
                    desc_din <= {(pkt_err | bad_pkt | (wcnt != rx_len)), wwritten[14:0]};
                    desc_wr  <= 1'b1;
                end
            end
        end
    end

    // 包级计数（125M 域 → 100M 域 toggle 同步）
    reg ok_tog = 1'b0, drop_tog = 1'b0;
    always @(posedge clk125 or posedge wr_rst) begin
        if (wr_rst) begin
            ok_tog   <= 1'b0;
            drop_tog <= 1'b0;
        end else if (op_done) begin
            if (pkt_err | bad_pkt | (wcnt != rx_len)) drop_tog <= ~drop_tog;
            else                                      ok_tog   <= ~ok_tog;
        end
    end

    // =====================================================================
    // 5) 字节异步 FIFO + 描述符异步 FIFO
    // =====================================================================
    wire [7:0] byte_d;
    wire       byte_v;
    wire       byte_pop;

    yx_b_afifo #(.WIDTH(8), .AW(FIFO_AW)) u_bfifo (
        .wr_rst   (wr_rst),
        .wr_clk   (clk125),
        .wr_en    (byte_wr),
        .wr_data  (pdat),
        .wr_full  (byte_full),
        .wr_occ   (byte_occ),
        .rd_rst   (rd_rst),
        .rd_clk   (clk100),
        .rd_en    (byte_pop),
        .rd_data  (byte_d),
        .rd_valid (byte_v),
        .rd_empty ()
    );
    assign fifo_room = DEPTH[15:0] - {{(16-FIFO_AW-1){1'b0}}, byte_occ};

    wire [15:0] desc_d;
    wire        desc_v;
    wire        desc_pop;

    yx_b_afifo #(.WIDTH(16), .AW(DESC_AW)) u_dfifo (
        .wr_rst   (wr_rst),
        .wr_clk   (clk125),
        .wr_en    (desc_wr),
        .wr_data  (desc_din),
        .wr_full  (desc_full),
        .wr_occ   (),
        .rd_rst   (rd_rst),
        .rd_clk   (clk100),
        .rd_en    (desc_pop),
        .rd_data  (desc_d),
        .rd_valid (desc_v),
        .rd_empty ()
    );

    // =====================================================================
    // 6) 读侧（100M）：按描述符转发 / 丢弃
    //    desc = {err, len[14:0]}；err=1 → 弹掉 len 字节不转发。
    // =====================================================================
    localparam S_IDLE = 2'd0, S_SEND = 2'd1, S_DROP = 2'd2;
    reg  [1:0]  st;
    reg  [14:0] rem;
    reg  [31:0] byte_cnt_r;

    assign desc_pop = (st == S_IDLE) && desc_v;

    assign stream_valid = (st == S_SEND) && byte_v && (rem != 15'd0);
    assign stream_data  = byte_d;

    // 弹字节：发送态在握手成功时弹；丢弃态无条件弹
    assign byte_pop = (st == S_SEND) ? (byte_v && stream_ready && (rem != 15'd0)) :
                      (st == S_DROP) ? (byte_v && (rem != 15'd0)) : 1'b0;

    always @(posedge clk100 or posedge rd_rst) begin
        if (rd_rst) begin
            st         <= S_IDLE;
            rem        <= 15'd0;
            byte_cnt_r <= 32'd0;
        end else begin
            case (st)
            S_IDLE: if (desc_v) begin
                if (desc_d[14:0] == 15'd0)
                    st <= S_IDLE;                       // 空包（整包丢弃）
                else begin
                    rem <= desc_d[14:0];
                    st  <= desc_d[15] ? S_DROP : S_SEND;
                end
            end
            S_SEND: if (byte_pop) begin
                rem        <= rem - 15'd1;
                byte_cnt_r <= byte_cnt_r + 32'd1;
                if (rem == 15'd1) st <= S_IDLE;
            end
            S_DROP: if (byte_pop) begin
                rem <= rem - 15'd1;
                if (rem == 15'd1) st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    assign byte_cnt = byte_cnt_r;

    // 包计数同步（toggle → 2FF → 边沿）
    reg [2:0] ok_s = 3'd0, dp_s = 3'd0;
    reg [15:0] ok_cnt_r = 16'd0, dp_cnt_r = 16'd0;
    wire ok_ev = ok_s[2] ^ ok_s[1];
    wire dp_ev = dp_s[2] ^ dp_s[1];

    always @(posedge clk100 or posedge rd_rst) begin
        if (rd_rst) begin
            ok_s    <= 3'd0;
            dp_s    <= 3'd0;
            ok_cnt_r <= 16'd0;
            dp_cnt_r <= 16'd0;
        end else begin
            ok_s <= {ok_s[1:0], ok_tog};
            dp_s <= {dp_s[1:0], drop_tog};
            if (ok_ev) ok_cnt_r <= ok_cnt_r + 16'd1;
            if (dp_ev) dp_cnt_r <= dp_cnt_r + 16'd1;
        end
    end

    assign pkt_ok_cnt   = ok_cnt_r;
    assign pkt_drop_cnt = dp_cnt_r;

endmodule


// =========================================================================
// yx_b_afifo — 双时钟异步 FIFO（格雷码指针 + 2FF 同步 + 读侧预取）
//
// 契约：
//   · 写侧 wr_en 在 !wr_full 时写入；wr_occ 为保守占用（读指针同步滞后，
//     只会偏大 → full 提前，安全方向）；
//   · 读侧是"保持型"接口：rd_valid=1 时 rd_data 有效且保持，rd_en 消费该字节；
//     内部预取使稳态可达 1 字节/拍（无取数气泡）；
//   · 存储为简单双口（写 125M / 读 100M），读口单一地址 + 寄存输出
//     → TD 推断为真双时钟 BRAM（P5-P1；旧版双读地址导致退化为分布式 RAM）。
// =========================================================================
module yx_b_afifo #(
    parameter WIDTH = 8,
    parameter AW    = 13
)(
    input  wire             wr_rst,
    input  wire             wr_clk,
    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    output wire             wr_full,
    output wire [AW:0]      wr_occ,
    input  wire             rd_rst,
    input  wire             rd_clk,
    input  wire             rd_en,
    output wire [WIDTH-1:0] rd_data,
    output wire             rd_valid,
    output wire             rd_empty
);
    localparam DEPTH = (1 << AW);
    localparam PT    = AW + 1;

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    function [PT-1:0] g2b;
        input [PT-1:0] g;
        integer i;
        begin
            g2b[PT-1] = g[PT-1];
            for (i = PT-2; i >= 0; i = i - 1)
                g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction

    // ---------------- 写域 ----------------
    reg  [PT-1:0] wbin, wgray;
    reg  [AW-1:0] wptr;
    reg  [PT-1:0] rgray_w1, rgray_w2;
    // ★ 格雷→二进制单独打一拍：g2b 是 PT-1 级串行 XOR（14 位 → 13 级），
    //   原来与"减法算占用 + 比较出 full"串成一条 11.3ns 路径，125MHz（8ns）
    //   下违例 -3.4ns（实测 u_bfifo/rgray_w2 → skip_pkt，ADDER=5）。
    //   多打一拍照样安全：rbin_w 更滞后 → 占用只会估得更大 → full 更早，
    //   方向保守（与"读指针同步滞后"同一性质），不会溢出。
    reg  [PT-1:0] rbin_w_q;
    wire [PT-1:0] rbin_w = g2b(rgray_w2);
    wire [PT-1:0] wbin_nxt = wbin + 1'b1;
    wire [PT-1:0] wgray_nxt = wbin_nxt ^ (wbin_nxt >> 1);

    assign wr_occ  = wbin - rbin_w_q;
    assign wr_full = (wr_occ >= DEPTH[PT-1:0]);

    // ---------------- 读域 ----------------
    reg  [PT-1:0] rbin, rgray;
    reg  [AW-1:0] rptr;
    reg  [PT-1:0] wgray_r1, wgray_r2;
    wire [PT-1:0] wbin_r = g2b(wgray_r2);
    wire [PT-1:0] occ_r  = wbin_r - rbin;
    wire [PT-1:0] rbin_nxt = rbin + 1'b1;
    wire [PT-1:0] rgray_nxt = rbin_nxt ^ (rbin_nxt >> 1);
    wire [AW-1:0] rptr_nxt = rptr + 1'b1;

    reg [WIDTH-1:0] dout_r;
    reg             dvalid_r;

    assign rd_data  = dout_r;
    assign rd_valid = dvalid_r;
    assign rd_empty = (occ_r == {PT{1'b0}}) && !dvalid_r;

    // ★ 存储读地址（唯一）：消费拍预取下一字，其余拍保持当前字。
    //   = pop ? rptr+1 : rptr —— 写成加法正好省掉一个地址多路器。
    wire                   pop    = dvalid_r && rd_en;
    wire [AW-1:0]          mem_ra = rptr + {{(AW-1){1'b0}}, pop};

    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) begin
            wbin <= {PT{1'b0}};
            wgray <= {PT{1'b0}};
            wptr <= {AW{1'b0}};
            rgray_w1 <= {PT{1'b0}};
            rgray_w2 <= {PT{1'b0}};
            rbin_w_q <= {PT{1'b0}};
        end else begin
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
            rbin_w_q <= g2b(rgray_w2);
            if (wr_en && !wr_full) begin
                mem[wptr] <= wr_data;
                wptr  <= wptr + 1'b1;
                wbin  <= wbin_nxt;
                wgray <= wgray_nxt;
            end
        end
    end

    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) begin
            rbin <= {PT{1'b0}};
            rgray <= {PT{1'b0}};
            rptr <= {AW{1'b0}};
            wgray_r1 <= {PT{1'b0}};
            wgray_r2 <= {PT{1'b0}};
            dout_r   <= {WIDTH{1'b0}};
            dvalid_r <= 1'b0;
        end else begin
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
            // ★ P5-P1：存储读口收成"唯一地址 + 无条件同步读"。
            //   原实现是两个分支各读一个地址（消费拍读 mem[rptr_nxt] 预取、
            //   其余拍读 mem[rptr]），综合器无法把 mem 映射成 BRAM，退化成
            //   ~15.7K LUT 分布式逻辑 —— B 板 LUT 爆容(248%)与 125M 域
            //   "SEQ+4×ADDER+DRAM" -2652ps 违例的共同根因。
            //   合并为 mem_ra = 消费则 +1 否则不动（= pop ? rptr+1 : rptr），
            //   读出仍是寄存输出、每拍无气泡，逐拍语义与旧版完全一致。
            dout_r <= mem[mem_ra];
            if (pop) begin
                // 消费当前字节；同时预取下一个（≥2 字节时无气泡）
                rbin  <= rbin_nxt;
                rgray <= rgray_nxt;
                rptr  <= rptr_nxt;
                dvalid_r <= (occ_r > {{(PT-1){1'b0}}, 1'b1});
            end else if (!dvalid_r) begin
                dvalid_r <= (occ_r != {PT{1'b0}});
            end
        end
    end

endmodule
