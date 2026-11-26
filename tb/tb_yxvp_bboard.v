`timescale 1ns/1ps
// tb_yxvp_bboard.v — 板 B SoC 集成验收 TB
//
// 链路：vp_720_5f.yxv2 字节流 → yingxu_vq_board_top（ixdec→ixbuf→band→扫描写端
//       → vendor SDRAM 控制器+硬宏 → HDMI 扫出）
// 索引缓冲 SDRAM 随机口接行为模型（写直入；读电平请求→次拍 dvld）。
//
// 断言：
//   A1 扫描对拍：每带 scan_done 时，SDRAM 帧缓冲区 [b*2560,+2560) 与 band 行缓冲
//      半区（2 像素/字打包）逐字一致；
//   A2 不欠扫描：渲染器 pend_cnt==2 的滞留拍数占比受限于阈值（默认 5%）；
//   A3 帧计数：frame_done_vq 次数 = 流内帧数；
//   P3 显示判据：AXI-Stream 内容对拍（读对窗、流对序）+ 写读窗互斥 + RD1 供数。
module tb_yxvp_bboard;
`ifdef YXVP_W
    parameter W = `YXVP_W;
`else
    parameter W = 1280;
`endif
`ifdef YXVP_H
    parameter H = `YXVP_H;
`else
    parameter H = 720;
`endif
`ifdef YXVP_CBSIZE
    parameter CBSIZE = `YXVP_CBSIZE;
`else
    parameter CBSIZE = 1024;
`endif
    localparam BH = H/4, FB_WB = 4*W/2, FB_TOTAL = BH*FB_WB;
    localparam FBB = 2*(W/4)*(H/4);        // 帧缓冲基址 = 2×NB（与索引区不重叠）
    localparam AW = ((2*(W/4)*(H/4)) > (1<<17)) ? 19 : 17;

    reg ref_clk = 1'b0;
    always #10 ref_clk = ~ref_clk;          // 50M
    wire clk100;                             // 顶层内部 PLL
                                             // 73.33M 像素时钟 dbg_pixel_clk（下）

    reg rst_n = 1'b0;

    // ---- 字节流 ----
`ifdef BBOARD_ETH
    // 以太网入口模式（P4）：stream 由 yx_b_eth_rx 驱动（见下方 ETH 块）
    wire       s_valid;
    wire [7:0] s_data;
`else
    reg        s_valid = 1'b0;
    reg  [7:0] s_data  = 8'h00;
`endif
    wire       s_ready;

    // ---- 索引 SDRAM 行为模型 ----
    // ★ SYS 模式（体系化）下 cp 拷贝读口已由 fetch v5 经 RD2 分时顺序承载
    //   （板上契约闭环），本模型的 cp 服务分支停用；ixmem 仅保留两用：
    //   a) WR2 镜像（下）= 索引窗金标供给源；b) band 抽象读（模式 1 用）。
    wire        ix_wv; wire [AW-1:0] ix_wa; wire [15:0] ix_wd;
    wire        cp_rd_w; wire [AW-1:0] cp_a_w; reg cp_dvld_r; reg [15:0] cp_d_r;
    wire        breq_w; wire [AW-1:0] baddr_w; reg bdvld_r; reg [15:0] bd_d_r;
    reg [15:0]  ixmem [0:(1<<AW)-1];

    always @(posedge clk100 or negedge rst_n) begin
        if (!rst_n) begin
            cp_dvld_r <= 1'b0; bdvld_r <= 1'b0;
        end else begin
`ifdef BBOARD_SYS
            cp_dvld_r <= 1'b0;          // 体系模式：cp 口由 fetch v5 承载，模型停用
            cp_d_r    <= 16'h0000;
`else
            cp_dvld_r <= cp_rd_w;   cp_d_r  <= ixmem[cp_a_w];
`endif
            bdvld_r   <= breq_w;    bd_d_r  <= ixmem[baddr_w];
            if (ix_wv) ixmem[ix_wa] <= ix_wd;
        end
    end

    // ---- 模式 0 索引窗金标供给：把 WR2 稠密写流镜像进 ixmem ----
    // 体系模式（SIM_ABSTRACT=0）下抽象写口 ix_wr_* 强制置 0，ixmem 仅由此镜像
    // 供给。★ 自 fetch v5 起 cp 拷贝读改由 RD2 分时承载（真实 SDRAM 回路），
    // ixmem 不再被 DUT 读取，只作 igold 对拍的镜像参考。KEY 流无 DELTA，
    // 不触及 cp 口。wr2_load_u 与 wr2_en_u 分属不同状态，永不同拍。
    reg [16:0] mir_cnt;
    always @(posedge clk100 or negedge rst_n) begin
        if (!rst_n) mir_cnt <= 17'd0;
        else if (u_top.wr2_load_u) mir_cnt <= 17'd0;
        else if (u_top.wr2_en_u) begin
            ixmem[u_top.wr2_addr_u + mir_cnt] <= u_top.wr2_data_u[15:0];
            mir_cnt <= mir_cnt + 17'd1;
        end
    end

    // ---- 顶层 ----
    wire [15:0] commit_no, rendered_no;
    wire        frame_done_vq, scan_done, scan_ack;
    wire [8:0]  scan_band_no;
    wire [1:0]  pend_cnt;
    wire        video_user_w, video_valid_w, video_last_w;
    wire [23:0] video_data_w;
    wire        win_show_w;
    wire [15:0] disp_pass_w, disp_stall_w;
    wire        pixel_clk_w;
    wire [31:0] DRAM_DQ; wire [10:0] DRAM_ADDR; wire [1:0] DRAM_BA, DRAM_CS_N;
    wire DRAM_CKE, DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N; wire [3:0] DRAM_DQM; wire DRAM_CLK;
    // ★ P5：顶层 eth_mdio 已改为三态（Clause 22 MDIO）。仿真里不挂 PHY 模型，
    //   按板上做法给一根 PULLUP —— 主机释放总线时读到全 1，yx_b_phy_init 会走
    //   "PHY 未响应 → 跳过写"分支，结果确定（否则读到 Z，rdata 变 X）。
    wire eth_mdio_w;
    pullup (eth_mdio_w);

    yingxu_vq_board_top #(.W(W), .H(H), .CBSIZE(CBSIZE), .AW(AW)
`ifdef BBOARD_SYS
                          , .SIM_ABSTRACT(0)
`endif
                          ) u_top (
        .ref_clk(ref_clk), .rst_n(rst_n),
        .stream_valid(s_valid), .stream_data(s_data), .stream_ready(s_ready),
        .ix_wr_valid(ix_wv), .ix_wr_addr(ix_wa), .ix_wr_data(ix_wd), .ix_wr_gnt(1'b1),
        .cp_rd(cp_rd_w), .cp_addr(cp_a_w), .cp_dvld(cp_dvld_r), .cp_data(cp_d_r),
        .band_rd_req(breq_w), .band_rd_addr(baddr_w),
        .band_rd_dvld(bdvld_r), .band_rd_data(bd_d_r),
        .video_user(video_user_w), .video_valid(video_valid_w),
        .video_last(video_last_w), .video_data(video_data_w),
        .win_show(win_show_w), .disp_pass(disp_pass_w), .disp_stall(disp_stall_w),
        .commit_no(commit_no), .rendered_no(rendered_no),
        .frame_done_vq(frame_done_vq), .scan_done(scan_done), .scan_band_no(scan_band_no),
        .scan_ack(scan_ack),
        .band_pend_cnt(pend_cnt),
        .dbg_clk100(clk100), .dbg_pixel_clk(pixel_clk_w),
        .eth_mdio(eth_mdio_w),
        .DRAM_DQ(DRAM_DQ), .DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA),
        .DRAM_CS_N(DRAM_CS_N), .DRAM_CKE(DRAM_CKE), .DRAM_RAS_N(DRAM_RAS_N),
        .DRAM_CAS_N(DRAM_CAS_N), .DRAM_WE_N(DRAM_WE_N), .DRAM_DQM(DRAM_DQM),
        .DRAM_CLK(DRAM_CLK)
    );

    // ================= 以太网 UDP 入口（P4，-DBBOARD_ETH）=================
    // 数据源 = GMII 帧 → yx_b_eth_rx（125M→100M CDC + 包级提交）→ 顶层 stream。
    // 判据与 bboard_sys 完全一致（golden/igold/axerr/…），传输层追加：
    // 全部包 CRC 正确、零丢包（ethdrop=0、ethok=包数）。
`ifdef BBOARD_ETH
    localparam [47:0] ETH_LOCAL_MAC  = 48'h00_0a_35_02_00_01;
    localparam [31:0] ETH_LOCAL_IP   = 32'hc0_a8_00_64;    // 192.168.0.100
    localparam [15:0] ETH_LOCAL_PORT = 16'd5000;
    localparam [47:0] ETH_SRC_MAC    = 48'h00_0a_35_01_fe_c0;
    localparam [31:0] ETH_SRC_IP     = 32'hc0_a8_00_02;    // 192.168.0.2
    localparam [15:0] ETH_SRC_PORT   = 16'd5000;

    reg gmii_clk = 1'b0;
    always #4 gmii_clk = ~gmii_clk;            // 125M PHY 时钟（与 100M 异步）

    reg  [7:0] gmii_rxd  = 8'h00;
    reg        gmii_rxdv = 1'b0;

    wire        eth_sv;
    wire [7:0]  eth_sd;
    wire [15:0] eth_ok_cnt, eth_drop_cnt, eth_room;
    wire [31:0] eth_byte_cnt;

    // ★ 吞吐压力模式（+NOSTALL）：跳过 FIFO room 节流，按 GMII 线速不间断灌包。
    //
    //   为什么需要：默认测试里发送进程有一句
    //       while (eth_room < (e_len + 128)) @(negedge gmii_clk);
    //   即 **TB 会等 FIFO 有空位才发**。所以默认门禁的 drop=0 / bytes 精确匹配
    //   只证明"在 TB 配合的节奏下不丢包"，**没有证明设计能承受不配合的真实主机**。
    //
    //   压力模式只判两件事（不判解码正确性——人为不节流必然整包丢弃，
    //   码流不完整，金标/逐带对拍判据在这里不适用，不是放宽判据而是换判据）：
    //     1. 过载确实发生（drop > 0），否则说明没测到饱和点，测量无效；
    //     2. 设计仍在推进（delivered > 0）且正常 $finish —— 没有死锁。
    reg     nostall = 1'b0;
    integer st_cyc = 0;                 // clk100 周期计数（速率分母）
    reg     st_pend = 1'b0;
    // ★ 速率必须在**发送窗口内**测：TB 用线速把 slen 字节发完只需约
    //   slen/125MBps ≈ 24 万拍，而主流程要跑满 wd（数百万拍）。若用整段
    //   st_cyc 当分母，后面无负载的空转期会把速率稀释十几倍。
    //   所以在 eth_tx_done 那一刻快照「窗口周期数 + 已交付字节」。
    integer st_cyc_tx = 0;              // 发送窗口内的 clk100 周期数
    integer st_byte_tx = 0;             // 发送窗口内已交付字节
    real    st_rate = 0.0;              // 压力模式：发送窗口内的交付速率 MB/s
    real    st_rate_off = 0.0;          // 压力模式：发送窗口内的提供速率 MB/s
    reg     pstress = 1'b0;
    initial nostall = $test$plusargs("NOSTALL") ? 1'b1 : 1'b0;
    always @(posedge clk100) if (st_pend) st_cyc <= st_cyc + 1;

    assign s_valid = eth_sv;
    assign s_data  = eth_sd;

    yx_b_eth_rx #(.USE_RGMII(0), .FIFO_AW(13)) u_ethrx (
        .clk100       (clk100),
        .rst_n        (rst_n),
        .local_mac    (ETH_LOCAL_MAC),
        .local_ip     (ETH_LOCAL_IP),
        .local_port   (ETH_LOCAL_PORT),
        .gmii_rx_clk  (gmii_clk),
        .gmii_rxd     (gmii_rxd),
        .gmii_rxdv    (gmii_rxdv),
        .rgmii_rx_clk (1'b0),
        .rgmii_rxd    (4'd0),
        .rgmii_rxdv   (1'b0),
        .stream_valid (eth_sv),
        .stream_data  (eth_sd),
        .stream_ready (s_ready),
        .pkt_ok_cnt   (eth_ok_cnt),
        .pkt_drop_cnt (eth_drop_cnt),
        .byte_cnt     (eth_byte_cnt),
        .fifo_room    (eth_room),
        .rx_clk125    ()
    );

    // ---- 发送侧 FCS（复用厂商 CRC 件，与 RX 同口径）----
    reg  [7:0]  e_dat  = 8'h00;
    reg         e_en   = 1'b0;
    reg         e_init = 1'b0;
    wire [31:0] e_crcv;
    crc32_d8 u_ethcrc (
        .clk        (gmii_clk),
        .reset_p    (1'b0),
        .data       (e_dat),
        .crc_init   (e_init),
        .crc_en     (e_en),
        .crc_result (e_crcv)
    );

    reg [7:0] efb [0:2047];

    task e_gmii_byte(input [7:0] b);
    begin
        @(negedge gmii_clk);
        gmii_rxdv = 1'b1;
        gmii_rxd  = b;
    end
    endtask

    task e_gmii_idle(input integer n);
        integer i;
        begin
            @(negedge gmii_clk);
            gmii_rxdv = 1'b0;
            gmii_rxd  = 8'h00;
            for (i = 0; i < n; i = i + 1) @(negedge gmii_clk);
        end
    endtask

    integer e_ipid = 0;

    task e_send_pkt(input integer off, input integer len);
        integer i;
        reg [15:0] tot, id16, udplen;
        reg [31:0] suma, sumb;
        reg [15:0] sumc, ipck;
        reg [31:0] fcs;
        begin
            tot    = 16'd20 + 16'd8 + len[15:0];
            id16   = e_ipid[15:0]; e_ipid = e_ipid + 1;
            udplen = 16'd8 + len[15:0];

            for (i = 0; i < 6; i = i + 1) efb[i]   = ETH_LOCAL_MAC >> (8*(5-i));
            for (i = 0; i < 6; i = i + 1) efb[6+i] = ETH_SRC_MAC   >> (8*(5-i));
            efb[12] = 8'h08; efb[13] = 8'h00;
            efb[14] = 8'h45; efb[15] = 8'h00;
            efb[16] = tot[15:8]; efb[17] = tot[7:0];
            efb[18] = id16[15:8]; efb[19] = id16[7:0];
            efb[20] = 8'h40; efb[21] = 8'h00;
            efb[22] = 8'd64; efb[23] = 8'h11;
            suma = 32'h0000_4500 + tot + id16 + 32'h0000_4000 +
                   32'h0000_4011 + ETH_SRC_IP[31:16] + ETH_SRC_IP[15:0] +
                   ETH_LOCAL_IP[31:16] + ETH_LOCAL_IP[15:0];
            sumb = suma[31:16] + suma[15:0];
            sumc = sumb[16] + sumb[15:0];
            ipck = ~sumc;
            efb[24] = ipck[15:8]; efb[25] = ipck[7:0];
            for (i = 0; i < 4; i = i + 1) efb[26+i] = ETH_SRC_IP   >> (8*(3-i));
            for (i = 0; i < 4; i = i + 1) efb[30+i] = ETH_LOCAL_IP >> (8*(3-i));
            efb[34] = ETH_SRC_PORT[15:8];   efb[35] = ETH_SRC_PORT[7:0];
            efb[36] = ETH_LOCAL_PORT[15:8]; efb[37] = ETH_LOCAL_PORT[7:0];
            efb[38] = udplen[15:8]; efb[39] = udplen[7:0];
            efb[40] = 8'h00; efb[41] = 8'h00;
            for (i = 0; i < len; i = i + 1) efb[42+i] = smem[off+i];

            // FCS：init/en 撤除必须跨过时钟沿的 delta（#1），否则与 DUT
            // always 块竞争导致 CRC 寄存器不更新（P4 实测坑）。
            e_init = 1'b1; @(posedge gmii_clk); #1; e_init = 1'b0;
            for (i = 0; i < 42 + len; i = i + 1) begin
                e_dat = efb[i]; e_en = 1'b1;
                @(posedge gmii_clk);
            end
            #1; e_en = 1'b0;
            @(posedge gmii_clk); #1;
            fcs = e_crcv;

            for (i = 0; i < 7; i = i + 1) e_gmii_byte(8'h55);
            e_gmii_byte(8'hD5);
            for (i = 0; i < 42 + len; i = i + 1) e_gmii_byte(efb[i]);
            e_gmii_byte(fcs[7:0]);
            e_gmii_byte(fcs[15:8]);
            e_gmii_byte(fcs[23:16]);
            e_gmii_byte(fcs[31:24]);
            e_gmii_idle(12);
        end
    endtask

    reg     eth_tx_done = 1'b0;
    integer e_npkt, e_pi, e_off, e_len;

    // 发送进程：等顶层 INIT 完成（LOAD 不落控制器 POR 窗）后按 FIFO room 节流
    //   （+NOSTALL 时**不节流**，按线速灌满，用于测饱和/丢包，见上方声明处注释）
    initial begin : ethsrc
        wait (init_done === 1'b1);
        repeat (100) @(negedge gmii_clk);
        e_npkt = (slen + 1023) / 1024;
        st_pend = 1'b1;                       // 开始计周期（速率分母）
        for (e_pi = 0; e_pi < e_npkt; e_pi = e_pi + 1) begin
            e_off = e_pi * 1024;
            e_len = (e_off + 1024 <= slen) ? 1024 : (slen - e_off);
            while (!nostall && (eth_room < (e_len + 128))) @(negedge gmii_clk);
            e_send_pkt(e_off, e_len);
            if (e_pi % 64 == 0 || e_pi == e_npkt-1)
                $display("ETHPKT %0d/%0d off=%0d len=%0d ok=%0d drop=%0d",
                         e_pi, e_npkt-1, e_off, e_len, eth_ok_cnt, eth_drop_cnt);
        end
        eth_tx_done = 1'b1;
        st_cyc_tx   = st_cyc;              // ★ 快照：窗口周期数（速率分母）
        st_byte_tx  = eth_byte_cnt;        // ★ 快照：窗口内已交付字节（分子）
        $display("ETHTX done pkts=%0d bytes=%0d nostall=%b win_clk=%0d delivered_in_win=%0d",
                 e_npkt, slen, nostall, st_cyc_tx, st_byte_tx);
    end
`endif

    // ================= 断言状态 =================
    integer scan_errs = 0, frames_done = 0, bands_scanned = 0;    integer stall2_cnt = 0, total_cnt = 0;
    reg     pfinal = 1'b0;              // 最终 PASS 判据（压力模式与默认模式共用一条 TB-SUMMARY）
    integer k, ofs, expw, gotw;
    integer disp_pop_prev = 0, disp_samp = 0;   // （旧显示判据遗留名，退役）

    // A1：scan_done 拍，帧缓冲区 vs 行缓冲半区逐字对拍（零延阻塞循环）
    // SYS 模式追加金标对拍：+GOLDEN_FB 给出时用 gen_golden.py 期望值（真实流），
    // 否则用合成流公式（KEY-only 入口）。
    integer golden_errs = 0;
    integer frm, pe, po, expf;
    // ---- 文件金标（真实流）----
    localparam NBW = (W/4)*(H/4);          // 每窗索引字数 = NB
    reg [255:0] gidx_path, gfb_path;
    reg [15:0] gidx_mem [0:5*NBW-1];
    reg [31:0] gfb_mem  [0:5*FB_TOTAL-1];
    integer gidx_on = 0, gfb_on = 0;
    integer idx_golden_errs = 0;
    integer win_wr_cnt0 = 0, win_wr_cnt1 = 0;
    reg [1:0] rg_prev = 2'b00;
    integer gi, gfi, gwbase;
    // 分帧错误分布（YX6 排障）：igerr_cnt_f[f]=帧 f 索引窗错误数、首错偏移
    integer igerr_cnt_f [0:5];
    integer igerr_first_i [0:5];
    integer gerr_cnt_f [0:5];
    integer gerr_first_b [0:5];
    // 收口判定用：各判据布尔结果 + X/Z 违例计数 + mem 落写检查
    integer pd, pf, pb, pg, ps, px, xz_errs, pig, pce, pcp, phe, pax, pmu, pst, pm;
    integer peth;   // P4 传输层判据（仅 -DBBOARD_ETH 有实质）
    integer nx_idx, nx_fb, mx;
    // Task1: u_ixwr 入口计数
    integer ivc = 0, gnc = 0, ldc = 0, psc = 0, fwc = 0;
    // H1/H2 判别探针（只测量，不影响判定）
    integer cur_ba = 0, cur_row = 0, cur_col = 0, burst_cnt = 0, i_lin, wr_win = 0;
    integer w_x_idx = 0, w_r_idx = 0, w_x_fb = 0, w_r_fb = 0;
    integer x_i_a = -1, x_i_n = 0, x_f_a = -1, x_f_n = 0;
    reg [31:0] s_i0 = 32'h0, s_i1 = 32'h0, s_i2 = 32'h0, s_i3 = 32'h0, s_i4 = 32'h0;
    integer sa_i0 = -1, sa_i1 = -1, sa_i2 = -1, sa_i3 = -1, sa_i4 = -1;
    reg [31:0] s_f0 = 32'h0, s_f1 = 32'h0, s_f2 = 32'h0, s_f3 = 32'h0, s_f4 = 32'h0;
    integer sa_f0 = -1, sa_f1 = -1, sa_f2 = -1, sa_f3 = -1, sa_f4 = -1;
    // H2: write_fifo pop 沿 do vs TB 侧推入影子队列
    reg [31:0] q1 [0:1023];
    reg [31:0] q2 [0:1023];
    // ★ P5-P0 诊断：记录首个带的扫描推数流（u_top.wr1_en/sc_wdata），用于区分
    //   "扫描推数流本身错"（pt !== ln32）与 "SDRAM 写入被控制器弄错"（pt === ln32
    //   但 sdram !== ln32）。只测量，不参与判定。
    reg [31:0] ptrace [0:2559];
    integer pn = 0;
    always @(posedge clk100) begin
        if (rst_n && u_top.wr1_en && pn < 2560) begin
            ptrace[pn] = u_top.sc_wdata;
            pn = pn + 1;
        end
    end
    integer h1q = 0, t1q = 0, h2q = 0, t2q = 0;
    integer p1r = 0, p2r = 0, x1c = 0, x2c = 0, m1c = 0, m2c = 0, u1c = 0, u2c = 0, n1c = 0, n2c = 0;
    reg [31:0] got1 = 32'h0, got2 = 32'h0, mm1e = 32'h0, mm1g = 32'h0, mm2e = 32'h0, mm2g = 32'h0;
    integer mm1s = -1, mm2s = -1;
    integer px1c = 0, pr1c = 0, px2c = 0, pr2c = 0;
    reg [31:0] pv1_0 = 32'h0, pv1_1 = 32'h0, pv1_2 = 32'h0;
    reg [31:0] pv2_0 = 32'h0, pv2_1 = 32'h0, pv2_2 = 32'h0;
    always @(posedge clk100) begin
        if (rst_n && scan_done) begin
            ofs = scan_band_no[0] ? 4*W : 0;
            // ★ 帧号根修：比对带所属帧=渲染侧实际帧号（scan_done 拍 render_no
            //   恒为该带所在帧——渲染带 k+1 同帧推进/帧尾 frame_wait 时不变）。
            //   旧 bands_scanned/180 计数在比对滞后跨帧时与渲染帧号错位。
            frm = u_top.u_band.render_no;
            for (k = 0; k < FB_WB; k = k + 1) begin
                // ★ P5-P0：行缓冲已打包成 32bit 字（{奇,偶}），字地址 = 像素地址/2
                expw = u_top.u_band.u_ln32.mem[ofs/2 + k];
                // ★ P3 双窗：带写入帧窗 frm%2（[FBB+win*FB_TOTAL, +FB_TOTAL)）
                gotw = u_top.u_dram.sdram.mem[FBB + (frm % 2) * FB_TOTAL + scan_band_no * FB_WB + k];
`ifdef BBOARD_SYS
                if (gfb_on) begin
                    // 真实流文件金标：gen_golden.py 期望值（帧 f 渲染窗 f%2 状态）
                    expf = gfb_mem[frm*FB_TOTAL + scan_band_no*FB_WB + k];
                    if (gotw !== expf) begin
                        golden_errs = golden_errs + 1;
                        gerr_cnt_f[frm] = gerr_cnt_f[frm] + 1;
                        if (gerr_first_b[frm] < 0) gerr_first_b[frm] = scan_band_no;
                        if (golden_errs <= 8)
                            $display("GOLDEN-ERR b=%0d w=%0d sdram=%08h exp=%08h",
                                     scan_band_no, k, gotw, expf);
                    end
                end else begin
                // 合成流金标：带内像素 p=2k/2k+1，4×4 块二维映射：
                //   blk = (band*4 + 行/4)*(W/4) + 列/4；块内字 j = (行%4)*4 + 列%4
                //   像素 = cb[blkidx][j] = blkidx + j（合成码本 i+j）
                pe = ((((scan_band_no*4 + (2*k)  /W) /4)*(W/4) + ((2*k)  %W)/4) * 11
                      + frm*313) % CBSIZE + (((2*k)  /W)%4)*4 + ((2*k)  %W)%4;
                po = ((((scan_band_no*4 + (2*k+1)/W) /4)*(W/4) + ((2*k+1)%W)/4) * 11
                      + frm*313) % CBSIZE + (((2*k+1)/W)%4)*4 + ((2*k+1)%W)%4;
                expf = {po[15:0], pe[15:0]};
                if (gotw !== expf[31:0]) begin
                    golden_errs = golden_errs + 1;
                    if (golden_errs <= 8)
                        $display("GOLDEN-ERR b=%0d w=%0d sdram=%08h exp=%08h",
                                 scan_band_no, k, gotw, expf);
                end
                end
                // 诊断采样（不影响判定）：真实带的前 2 字实际内容 vs 金标
                if ((scan_band_no == 9'd40 || scan_band_no == 9'd400) && k < 2)
                    $display("GSAMPLE b=%0d w=%0d sdram=%08h ln=%08h exp=%08h",
                             scan_band_no, k, gotw, expw, expf);
`endif
                if (expw !== gotw) begin
                    scan_errs = scan_errs + 1;
                    if (scan_errs <= 8)
                        $display("BSCAN-ERR b=%0d w=%0d sdram=%08h ln=%08h",
                                 scan_band_no, k, gotw, expw);
                end
            end
            bands_scanned = bands_scanned + 1;
`ifdef P0_TRACE
            // ★ 首个带：把"推进 FIFO 的数据流"与行缓冲逐字对齐，定位错位点
            if (bands_scanned == 1) begin
                for (k = 0; k < FB_WB; k = k + 1) begin
                    if (ptrace[k] !== u_top.u_band.u_ln32.mem[k]) begin
                        $display("PTR-DIFF k=%0d pt=%08h ln=%08h sdram=%08h | prev pt=%08h ln=%08h | next pt=%08h ln=%08h",
                                 k, ptrace[k], u_top.u_band.u_ln32.mem[k],
                                 u_top.u_dram.sdram.mem[FBB + scan_band_no * FB_WB + k],
                                 (k>0) ? ptrace[k-1] : 32'h0,
                                 (k>0) ? u_top.u_band.u_ln32.mem[k-1] : 32'h0,
                                 ptrace[k+1], u_top.u_band.u_ln32.mem[k+1]);
                    end
                end
            end
`endif
            if (scan_errs == 0 && (bands_scanned % 30 == 0))
                $display("BSCAN ok bands=%0d (frame %0d)", bands_scanned, rendered_no);
        end
    end

    // A2：渲染器满挂（pend_cnt==2）滞留占比
    always @(posedge clk100) begin
        if (rst_n) begin
            total_cnt = total_cnt + 1;
            if (pend_cnt == 2'd2) stall2_cnt = stall2_cnt + 1;
        end
    end

    // ================= 逐级占空比（定位 0.85× 的阻断级）=================
    // ★ 教训：第一版只统计 `stall2 期间 band 在哪个状态`，得出"100% 在 st=1"，
    //   就误判成"在等 fetch 数据"。但 st=1 是个**多用途状态**：
    //     · !can_render            → 被扫描端深度 2 背压挡住（pend_cnt==2）
    //     · can_render && !fetch_r → 正在发出取数请求
    //     · can_render && fetch_r  → 真在等 rd_dvld
    //   而 stall2 的定义就是 pend_cnt==2，等于 can_render==0 —— 所以"stall2 期间
    //   band 必然在 st=1"是同义反复，什么也没证明。必须做**完整周期会计**。
    integer duty_tot = 0;
    integer w_idle = 0;                  // st=0 等帧
    integer w_backpressure = 0;          // st=1 且被 pend_cnt<2 背压挡住
    integer w_issue = 0;                 // st=1 发取数请求
    integer w_fetchwait = 0;             // st=1 已发请求、等 rd_dvld（真延迟）
    integer w_book = 0;                  // st=2 装载 book
    integer w_write = 0;                 // st=3 写 16 像素
    integer duty_sdram_busy = 0;         // SDRAM 控制器有突发在跑

    // SDRAM 控制器"有活"：任一 mask 非零，或 IN_REQ/OUT_VALID 在跑
    wire sdram_busy_w = (u_top.st_wr_mask_w != 2'b00) || (u_top.st_rd_mask_w != 2'b00) ||
                        u_top.st_in_req_w || u_top.st_out_valid_w;

    // 渲染器的三种子情况（层次引用，仅仿真用）
    wire band_st1 = (u_top.u_band.st == 2'd1);
    wire band_bp  = band_st1 && !u_top.u_band.can_render;
    wire band_iss = band_st1 &&  u_top.u_band.can_render && !u_top.u_band.fetch_r[0];
    wire band_wait= band_st1 &&  u_top.u_band.can_render &&  u_top.u_band.fetch_r[0]
                                  && !u_top.u_band.rd_dvld;

    always @(posedge clk100) begin
        if (rst_n) begin
            duty_tot = duty_tot + 1;
            if (sdram_busy_w)          duty_sdram_busy = duty_sdram_busy + 1;
            if (u_top.u_band.st == 2'd0) w_idle = w_idle + 1;
            if (band_bp)               w_backpressure = w_backpressure + 1;
            if (band_iss)              w_issue = w_issue + 1;
            if (band_wait)             w_fetchwait = w_fetchwait + 1;
            if (u_top.u_band.st == 2'd2) w_book = w_book + 1;
            if (u_top.u_band.st == 2'd3) w_write = w_write + 1;
        end
    end

    // ================= 解码链占空比（band 在 st=0 等帧时，上游在干什么）=================
    // 5A 会计证明真实流的 1.50M 拍额外耗时全在 band 的 idle（等下一帧提交）。
    // 本段回答"那段时间上游在忙什么"：解码在干活 / 在等数据 / 在等 SDRAM 写。
    integer di_tot = 0;
    integer di_ixdec_busy = 0;       // ixdec 不在 S_HDR0（收头相）之外的空闲
    integer di_ixdec_hdr = 0;        // ixdec 停在 S_HDR0..S_HDR4（等/收字节）
    integer di_ixwr_wait = 0;        // seq_wr 在 S_WAIT0/S_WINWAIT（等补丁）
    integer di_ixwr_grp = 0;         // seq_wr 在 S_GRPDONE（等突发落 SDRAM）
    integer di_ixwr_push = 0;        // seq_wr 在 S_PUSH（推字）
    integer di_sdram = 0;            // SDRAM 控制器忙
    integer di_dec_nrdy = 0;         // 解码器不收（dec_rdy_w=0）
    integer di_hdr_nrdy = 0;         // hdr_parse 不收（hdr_rdy=0）
    wire band_idle_w = (u_top.u_band.st == 2'd0);

    // ixdec 状态分布（0..10 = S_HDR0..S_HDR4 / S_KEY / S_MAP / S_WALK /
    //   S_DIDX / S_FD / S_WALKR；见 yx_vp_ixdec.v:47-49）
    integer dx_st [0:15];
    integer dx_st_idle [0:15];
    integer dx_n;
    initial begin
        for (dx_n = 0; dx_n < 16; dx_n = dx_n + 1) begin
            dx_st[dx_n] = 0; dx_st_idle[dx_n] = 0;
        end
    end

    always @(posedge clk100) begin
        if (rst_n) begin
            dx_st[u_top.u_ixdec.state] = dx_st[u_top.u_ixdec.state] + 1;
            if (band_idle_w)
                dx_st_idle[u_top.u_ixdec.state] = dx_st_idle[u_top.u_ixdec.state] + 1;
        end
    end

    // ---- S_WALK 子情况拆分（判定 7.8M 拍到底卡在哪）----
    //   变块只占 7.6%（DIDX 13,176 / WALKR 172,800），却占了 7.8M 拍 —— 与
    //   "S_KEY 写 57,600 字只用 405,545 拍" 矛盾，必须拆开看，别在错误前提上改 RTL。
    integer dw_walk_wait = 0;    // S_WALK 且 map_bite 且 !q_room（等 skid 腾位）
    integer dw_walk_didx = 0;    // S_WALK 且 map_bite 且 q_room（转 DIDX）
    integer dw_walk_next = 0;    // S_WALK 且 !map_bite（未变块，下一块）
    integer dw_map1 = 0;         // map_bite 为 1 的总拍数
    // ix_rdy = ix_acc_phase && pf_room && !busy[act^1]（yx_vp_ixbuf.v:120）
    //   走查停顿时拆开这三项，定位 skid 排不出去的真正原因
    integer iw_phase = 0;        // 阶段不对（不在接收相）
    integer iw_pfroom = 0;       // 补丁 FIFO 满
    integer iw_busy = 0;         // 另一个索引缓冲正忙
    always @(posedge clk100) begin
        if (rst_n) begin
            if (u_top.u_ixdec.map_bite) dw_map1 = dw_map1 + 1;
            if (u_top.u_ixdec.state == 4'd7) begin
                if (!u_top.u_ixdec.map_bite)                       dw_walk_next = dw_walk_next + 1;
                else if (u_top.u_ixdec.q_room)                     dw_walk_didx = dw_walk_didx + 1;
                else begin
                    dw_walk_wait = dw_walk_wait + 1;
                    if (!u_top.u_ixbuf.ix_acc_phase)               iw_phase = iw_phase + 1;
                    else if (!u_top.u_ixbuf.pf_room)               iw_pfroom = iw_pfroom + 1;
                    else if (u_top.u_ixbuf.busy[u_top.u_ixbuf.act ^ 1'b1]) iw_busy = iw_busy + 1;
                end
            end
        end
    end

    always @(posedge clk100) begin
        if (rst_n && band_idle_w) begin
            di_tot = di_tot + 1;
            if (u_top.u_ixdec.state >= 4'd5)      di_ixdec_busy = di_ixdec_busy + 1;
            else                                  di_ixdec_hdr  = di_ixdec_hdr  + 1;
            if (u_top.REAL_IX.u_ixwr.st == 3'd0 ||
                u_top.REAL_IX.u_ixwr.st == 3'd4)  di_ixwr_wait = di_ixwr_wait + 1;
            if (u_top.REAL_IX.u_ixwr.st == 3'd2)  di_ixwr_grp  = di_ixwr_grp  + 1;
            if (u_top.REAL_IX.u_ixwr.st == 3'd1)  di_ixwr_push = di_ixwr_push + 1;
            if (sdram_busy_w)                     di_sdram     = di_sdram     + 1;
            if (!u_top.dec_rdy_w)                 di_dec_nrdy  = di_dec_nrdy  + 1;
            if (!u_top.hdr_rdy)                   di_hdr_nrdy  = di_hdr_nrdy  + 1;
        end
    end

    // RD 路径观测：控制器 RD 突发数 + 显示待数据（RD FIFO 空）拍数
    integer rd_bursts = 0, disp_empty_cnt = 0, dec_frames = 0;
    reg [1:0] rd_mask_prev = 2'b00;
    integer patch_cnt = 0;
    always @(posedge clk100) begin
        if (rst_n) begin
            if ((u_top.u_sdram.RD_MASK != 2'b00) && (rd_mask_prev == 2'b00))
                rd_bursts = rd_bursts + 1;
            rd_mask_prev <= u_top.u_sdram.RD_MASK;
            if (u_top.rd1_empty_w) disp_empty_cnt = disp_empty_cnt + 1;
            if (u_top.dec_fdone) dec_frames = dec_frames + 1;
            // 补丁探针：前 8 个 (blk,idx)（期望 (0,0),(1,11),(2,22)...）
            if (u_top.hdr_ok_w && u_top.ix_we && patch_cnt < 8) begin
                patch_cnt = patch_cnt + 1;
                $display("PATCH %0d: blk=%0d idx=%0d", patch_cnt, u_top.ix_blk, u_top.ix_idx);
            end
            // 字节流探针：入口 vs 解析器实际消费的前 12 字节
            // ★ 用独立计数：ETH 模式下 sent 恒 0（由 eth 驱动），若不计数会每拍
            //   打印一行刷爆日志（P4 实测 2.4MB/秒）。只在 valid 时计数。
            if (feed_cnt < 12 && s_ready && s_valid) begin
                feed_cnt = feed_cnt + 1;
                $display("FEED %0d: %02x", feed_cnt, s_data);
            end
        end
    end
    // ================= P1b 帧首结构探针 =================
    // 判据（用户指定）：
    //   ① 一帧内 user 恰好 1 拍；
    //   ② user 必须与"第 0 个有效像素"同一拍；
    //   ③ valid 高电平拍数 == HACTIVE*VACTIVE = 1280*720 = 921600。
    // 帧首 dump 前 32 拍 {user, valid, last, data}，看 user 是否比首个有效像素
    //   早/晚 k 拍（k 即常数偏移来源）。重点看首帧：render 尚未 arm 时 user 是否漏出。
    integer fs_beat = -1;
    integer fs_frm = 0;
    integer fs_vcnt = 0;
    integer fs_ucnt = 0;
    localparam FS_WANT_VALID = 1280*720;
    always @(posedge u_top.pixel_clk_w) begin
        if (video_user_w) begin
            if (fs_frm > 0)
                $display("FSTAT frm=%0d valid=%0d user=%0d (want valid=%0d user=1) %s",
                         fs_frm-1, fs_vcnt, fs_ucnt, FS_WANT_VALID,
                         ((fs_vcnt == FS_WANT_VALID) && (fs_ucnt == 1)) ? "OK" : "BAD");
            fs_frm  = fs_frm + 1;
            fs_beat = 0;
            fs_vcnt = 0;
            fs_ucnt = 1;          // 本拍即本帧的 user
            $display("FSBEGIN frm=%0d t=%0t", fs_frm-1, $time);
        end
        if (fs_beat >= 0) begin
            if (fs_beat <= 32)
                $display("FSB %0d u=%b v=%b l=%b d=%06h", fs_beat,
                         video_user_w, video_valid_w, video_last_w, video_data_w);
            fs_beat = fs_beat + 1;
        end
        if (video_valid_w) fs_vcnt = fs_vcnt + 1;
    end

    // ================= P1b-1 RD1 首次 pop 探针 =================
    // 目标：定位"首字丢在哪一级"。在 book32+user修复+AX_OFF=0 配置下，
    //   key 的 AXIS 从 SDRAM word 1 起吐（跳过 word 0）。
    // 做法：每帧 LOAD 释放后，抓 RD1 FIFO 的前 8 次 pop 及其 do，
    //   与 SDRAM 帧窗 mem[i_base + n] 逐字比对。
    // 判据：第 0 次 pop 的 do 是否 == mem[i_base]。
    //   · 若第 0 次 pop 的 do 就是 mem[i_base+1] → 首字在 pop 前已被吃掉
    //   · 若第 0 次 pop 的 do == mem[i_base] 但 AXIS 仍从 word1 起
    //     → 丢在 skid→pair→输出 这一段
    reg     rp_armed = 1'b0;
    integer rp_n = 0;
    integer rp_frm = 0;
    always @(posedge clk100) begin
        if (rst_n) begin
            if (u_top.u_scanout.u_play.rd1_load) begin
                rp_armed = 1'b1;         // LOAD 期间武装
                rp_n     = 0;
            end else if (rp_armed && u_top.u_scanout.u_play.rd1_en) begin
                if (rp_n < 8)
                    $display("RD1POP frm=%0d n=%0d do=%08h exp=%08h %s",
                             rp_frm, rp_n,
                             u_top.u_scanout.u_play.rd1_data,
                             u_top.u_dram.sdram.mem[u_top.u_scanout.i_base_r + rp_n],
                             (u_top.u_scanout.u_play.rd1_data ===
                              u_top.u_dram.sdram.mem[u_top.u_scanout.i_base_r + rp_n])
                             ? "OK" : "MISMATCH");
                rp_n = rp_n + 1;
                if (rp_n >= 8) begin
                    rp_armed = 1'b0;
                    rp_frm   = rp_frm + 1;
                end
            end
        end
    end

    // 码本探针：hdr_ok 沿转储 book[0..7]（期望 0,1,2,3,4,5,6,7）
    reg hdr_ok_r = 1'b0;
    always @(posedge clk100) begin
        if (rst_n && u_top.hdr_ok_w && !hdr_ok_r) begin
            hdr_ok_r <= 1'b1;
            $display("BOOK[0..7] = %0d %0d %0d %0d %0d %0d %0d %0d",
                     u_top.u_band.book[0], u_top.u_band.book[1],
                     u_top.u_band.book[2], u_top.u_band.book[3],
                     u_top.u_band.book[4], u_top.u_band.book[5],
                     u_top.u_band.book[6], u_top.u_band.book[7]);
        end else begin
            hdr_ok_r <= u_top.hdr_ok_w;
        end
    end

    // 诊断（不影响判定）：SDRAM 引脚级命令探针 + H1 写窗归因
    // 命令编码：ACTIVE=RAS0/CAS1/WE1  READ=RAS1/CAS0/WE1  WRITE=RAS1/CAS0/WE0
    //           PRECHARGE=RAS0/CAS1/WE0  AUTO-REFRESH=RAS0/CAS0/WE1
    // 地址换算：linear = ba*524288 + row*256 + col（11bit row × 8bit col × 4 bank）
    //           linear < FBB(115200) = 索引区(WR2)，否则帧区(WR1)
    integer sd_act = 0, sd_wr = 0, sd_rd = 0, sd_pre = 0, sd_ref = 0;
    always @(posedge DRAM_CLK) begin
        if (DRAM_CS_N[0] === 1'b0) begin
            if (!DRAM_RAS_N && !DRAM_CAS_N && DRAM_WE_N) begin
                sd_ref = sd_ref + 1;
                wr_win = 0;
            end else if (!DRAM_RAS_N && !DRAM_CAS_N && !DRAM_WE_N) begin
                sd_pre = sd_pre + 1;
                wr_win = 0;
            end else if (!DRAM_RAS_N && DRAM_CAS_N && DRAM_WE_N) begin
                sd_act = sd_act + 1;
                cur_ba  = DRAM_BA;
                cur_row = DRAM_ADDR;
                wr_win  = 0;
            end else if (DRAM_RAS_N && !DRAM_CAS_N && !DRAM_WE_N) begin
                sd_wr = sd_wr + 1;
                cur_col  = DRAM_ADDR % 256;
                burst_cnt = 0;
                wr_win   = 1;
                if (sd_wr <= 4)
                    $display("SDWR t=%0t ba=%0d sa=%03h dqm=%b dq=%08h",
                             $time, DRAM_BA, DRAM_ADDR, DRAM_DQM, DRAM_DQ);
            end else if (DRAM_RAS_N && !DRAM_CAS_N && DRAM_WE_N) begin
                sd_rd = sd_rd + 1;
                wr_win = 0;
            end else begin
                wr_win = 0;
            end
        end else if ((wr_win === 1) && (burst_cnt < 256)) begin
            // 写数据拍：DQ 由控制器驱动，逐字归类到地址窗
            burst_cnt = burst_cnt + 1;
            i_lin  = cur_ba * 524288 + cur_row * 256 + cur_col;
            cur_col = (cur_col + 1) % 256;
            if (^DRAM_DQ === 1'bx) begin
                if (i_lin < FBB) begin
                    w_x_idx = w_x_idx + 1;
                    if (x_i_a < 0) x_i_a = i_lin;
                end else begin
                    w_x_fb = w_x_fb + 1;
                    if (x_f_a < 0) x_f_a = i_lin;
                end
            end else begin
                if (i_lin < FBB) begin
                    w_r_idx = w_r_idx + 1;
                    if      (w_r_idx == 1) begin s_i0 = DRAM_DQ; sa_i0 = i_lin; end
                    else if (w_r_idx == 2) begin s_i1 = DRAM_DQ; sa_i1 = i_lin; end
                    else if (w_r_idx == 3) begin s_i2 = DRAM_DQ; sa_i2 = i_lin; end
                    else if (w_r_idx == 4) begin s_i3 = DRAM_DQ; sa_i3 = i_lin; end
                    else if (w_r_idx == 5) begin s_i4 = DRAM_DQ; sa_i4 = i_lin; end
                end else begin
                    w_r_fb = w_r_fb + 1;
                    if      (w_r_fb == 1) begin s_f0 = DRAM_DQ; sa_f0 = i_lin; end
                    else if (w_r_fb == 2) begin s_f1 = DRAM_DQ; sa_f1 = i_lin; end
                    else if (w_r_fb == 3) begin s_f2 = DRAM_DQ; sa_f2 = i_lin; end
                    else if (w_r_fb == 4) begin s_f3 = DRAM_DQ; sa_f3 = i_lin; end
                    else if (w_r_fb == 5) begin s_f4 = DRAM_DQ; sa_f4 = i_lin; end
                end
            end
        end
    end

    // Task1: u_ixwr 入口活动计数（valid/gnt/en/load/full）
    always @(posedge clk100) begin
        if (rst_n) begin
            if (u_top.wr_valid_w === 1'b1) ivc = ivc + 1;
            if (u_top.ixwr_gnt_w === 1'b1) gnc = gnc + 1;
            if (u_top.REAL_IX.u_ixwr.wr2_en === 1'b1) psc = psc + 1;
            if (u_top.REAL_IX.u_ixwr.wr2_load === 1'b1) ldc = ldc + 1;
            if (u_top.wr2_full_w === 1'b1) fwc = fwc + 1;
        end
    end

    // CPSTAT：fetch v5 cp 口 RD2 分时服务观测（仅 SYS）。
    //   deliv = cp_dvld 脉冲数（merge 实际收到的源字）——真实流精确期望
    //   = ΣDELTA(NB-npatch) = 3*NBW-6588 = 166212（f1 D595/f2 D355/f4 D5638）；
    //   loads = CP_LOAD 完成数（流启动；被抢占重入 +1）；
    //   disc/stale = 补丁跳字的两种实现路径（和恒 = 补丁数，拆分随管线竞速浮动）。
    integer cp_deliv = 0, cp_disc = 0, cp_stale = 0, cp_loads = 0;
`ifdef BBOARD_SYS
    always @(posedge clk100) begin
        if (rst_n) begin
            if (u_top.REAL_IX.u_ixfetch.cp_dvld === 1'b1)
                cp_deliv = cp_deliv + 1;
            if (u_top.REAL_IX.u_ixfetch.rd2_re === 1'b1 &&
                u_top.REAL_IX.u_ixfetch.cp_pop_disc === 1'b1)
                cp_disc = cp_disc + 1;
            if (u_top.REAL_IX.u_ixfetch.cp_w_v === 1'b1 &&
                u_top.REAL_IX.u_ixfetch.cp_dvld === 1'b0 &&
                u_top.REAL_IX.u_ixfetch.cp_w_a !== u_top.cp_addr)
                cp_stale = cp_stale + 1;
            if (u_top.REAL_IX.u_ixfetch.cp_on === 1'b1 &&
                u_top.REAL_IX.u_ixfetch.cp_ld === 1'b1 &&
                u_top.rd2_empty_w === 1'b1 && u_top.rd2_bmask1_w === 1'b0)
                cp_loads = cp_loads + 1;
        end
    end
`endif

    // H2：write_fifo pop 沿 do 采样 vs TB 侧推入影子队列
    // negedge 采样 = 沿前电平（FIFO 在 posedge 采样的正是该电平）；do 在 pop 沿更新，
    // 下一个 negedge 读到的即该次弹出值。推入在 negedge 记录 = 下一沿落 FIFO 的值。
    always @(negedge clk100) begin
        if (p1r !== 0) begin
            got1 = u_top.u_sdram.mDATAIN1;
            n1c = n1c + 1;
            if (^got1 === 1'bx) x1c = x1c + 1;
            else if (h1q >= t1q) u1c = u1c + 1;
            else if (got1 !== q1[h1q % 1024]) begin
                m1c = m1c + 1;
                if (m1c <= 3) begin mm1e = q1[h1q % 1024]; mm1g = got1; mm1s = h1q; end
            end
            if (h1q < t1q) h1q = h1q + 1;
        end
        if (p2r !== 0) begin
            got2 = u_top.u_sdram.mDATAIN2;
            n2c = n2c + 1;
            if (^got2 === 1'bx) x2c = x2c + 1;
            else if (h2q >= t2q) u2c = u2c + 1;
            else if (got2 !== q2[h2q % 1024]) begin
                m2c = m2c + 1;
                if (m2c <= 3) begin mm2e = q2[h2q % 1024]; mm2g = got2; mm2s = h2q; end
            end
            if (h2q < t2q) h2q = h2q + 1;
        end
        p1r = (u_top.u_sdram.IN_REQ === 1'b1) && (u_top.u_sdram.WR_MASK[0] === 1'b1);
        p2r = (u_top.u_sdram.IN_REQ === 1'b1) && (u_top.u_sdram.WR_MASK[1] === 1'b1);
        if (u_top.wr1_en === 1'b1) begin
            q1[t1q % 1024] = u_top.sc_wdata; t1q = t1q + 1;
            if (^u_top.sc_wdata === 1'bx) px1c = px1c + 1; else pr1c = pr1c + 1;
            if (pr1c == 1) pv1_0 = u_top.sc_wdata;
            else if (pr1c == 2) pv1_1 = u_top.sc_wdata;
            else if (pr1c == 3) pv1_2 = u_top.sc_wdata;
        end
        if (u_top.wr2_en_w === 1'b1) begin
            q2[t2q % 1024] = u_top.wr2_data_w; t2q = t2q + 1;
            if (^u_top.wr2_data_w === 1'bx) px2c = px2c + 1; else pr2c = pr2c + 1;
            if (pr2c == 1) pv2_0 = u_top.wr2_data_w;
            else if (pr2c == 2) pv2_1 = u_top.wr2_data_w;
            else if (pr2c == 3) pv2_2 = u_top.wr2_data_w;
        end
    end

    // ================= AXI-Stream 内容对拍（P3 显示判据）=================
    // 像素域（dbg_pixel_clk）采样 video_*。显示遍 = "最后完成窗"的帧内容：
    //   frm = 最近完成帧且窗号匹配（C=完成帧数；首窗完成前显示黑屏，不判）。
    //   第 pass 内第 j 个 valid 拍 ↔ SDRAM 帧窗字 mem[FBB+win*FB_TOTAL+j/2]
    //   的对应半字（窗内容正确性由 igold/A1+golden 覆盖；本判据管"读对窗、
    //   流对序"——像素值与顺序逐拍全检）。
    //   AX_OFF/AX_SWAP = 管线相位校准常量（首轮仿真实测回填；校准非放宽）。
    // 写读窗互斥：写入期（sc_st 2..4）sc_win 必 ≠ 显示窗（100M 域断言）。
    integer ax_errs = 0, ax_beats = 0, ax_lines = 0, ax_j = 0, ax_frm = -1;
    integer ax_win = 0;           // 本帧锁存的显示窗（与 i_base 同步）
    integer ax_base = 0;          // 本帧 DUT 实际读基址（判据基准）
    integer mutex_errs = 0, vbl_loads = 0;
    integer ax_clk_cnt = 0, ax_valid_cnt = 0, ax_user_cnt = 0;
    reg [63:0] ax_first_user_t = 64'd0;
    // ★★ 2026-11-26：AX_OFF / AX_SWAP **已删除**。
    //   它们是"管线相位校准常量"，长期用来补偿 user/last 与数据的错位。
    //   但两个真 bug 修好后（yx_b_scanout 的 user/last 改走 vud[VDLY-2]；
    //   yx_b_scanout_play 的 skid 清计数时同时复位 sk_wp/sk_rp），
    //   **AX_OFF=0 下合成流与真实流同时 ax_errs=0** —— 常量不再需要。
    //   保留它们只会掩盖同类结构缺陷（实测：book32 后同一常量只能修好一个流，
    //   造成"两流反转"的假象，浪费了多轮排查）。判据里不再有任何可调相位项。
    // ★ P1a：滑移陷阱（+AXJTRAP=<j>，缺省关闭）
    integer ax_trap_j = 0;
    integer ax_trap_rc = 0;
    reg     ax_trap_on = 1'b0;
    initial begin
        ax_trap_on = $test$plusargs("AXJTRAP") ? 1'b1 : 1'b0;
        ax_trap_rc = $value$plusargs("AXJTRAP=%d", ax_trap_j);
    end
    integer C;
    integer gwd_i;
    reg [15:0] gpx;
    reg [23:0] gexp;
    always @(posedge u_top.pixel_clk_w) begin
        ax_clk_cnt = ax_clk_cnt + 1;
        if (ax_clk_cnt <= 3)
            $display("PCLK-EDGE %0t cnt=%0d valid=%b user=%b", $time, ax_clk_cnt,
                     video_valid_w, video_user_w);
        if (rst_n) begin
            if (video_user_w) begin
                ax_user_cnt = ax_user_cnt + 1;
                if (ax_first_user_t == 64'd0) ax_first_user_t = $time;
                C = bands_scanned / BH;               // 已完成帧数
                // ★ 锁存本帧显示窗：DUT 的 i_base 只在 vblank（当前拍）更新，
                //   若用实时 win_show 判据会在换窗时刻错位（实测首错正好落在
                //   窗 0→1 切换点）。
                ax_win = win_show_w;
                // ★ 用 DUT 实际的读基址作判据基准（i_base 只在 vblank 更新，
                //   而 win_show_req 可能在 vblank 后、user 前翻转 → 用 req 推断
                //   窗号会与真实读地址不一致，实测首错正是帧末尾换窗时刻）。
                ax_base = u_top.u_scanout.i_base_r;
                if (C >= 1 && (ax_win == ((C-1) % 2)))      ax_frm = C-1;
                else if (C >= 2 && (ax_win == ((C-2) % 2))) ax_frm = C-2;
                else ax_frm = -1;                     // 黑屏期/异常：跳过
                ax_j = 0;
                $display("AXUSER t=%0t C=%0d win=%b base=%0d fwd=%b lded=%b",
                         $time, C, ax_win, ax_base, u_top.first_win_done_w,
                         u_top.u_scanout.loaded_w);
            end
            if (video_valid_w) begin
                ax_valid_cnt = ax_valid_cnt + 1;
                ax_beats = ax_beats + 1;
                // ★ P1a 滑移陷阱：+AXJTRAP=<j> 在指定 beat 前后各 16 拍逐拍抓
                //   AXIS 握手 + 扫描 skid + 拷贝相态，用于定位"帧中滑移"。
                //   判据：滑移点前后 axis_tready 是否 1 拍拉低而 valid 仍高。
                //   注：仿真里 video_ready_w 恒 1（top:722 "ready 仅 informational"），
                //   故若滑移在仿真可复现，机制不在 AXIS 背压而在别处。
                if (ax_trap_on && ax_j >= ax_trap_j - 16 && ax_j <= ax_trap_j + 16)
                    $display("AXTRAP j=%0d v=%b u=%b l=%b rdy=%b | skc=%0d cap=%b pair=%08h refw=%b load=%b | sc_st=%0d push=%0d win=%b b=%0d",
                             ax_j, video_valid_w, video_user_w, video_last_w,
                             u_top.video_ready_w,
                             u_top.u_scanout.u_play.sk_cnt, u_top.u_scanout.u_play.sk_cap,
                             u_top.u_scanout.u_play.pair,
                             u_top.u_scanout.u_play.refwait, u_top.u_scanout.u_play.loading,
                             u_top.sc_st, u_top.sc_push, u_top.sc_win, u_top.sc_cur);
                // ★ 无相位常量：ax_j 直接就是帧内像素序号（结构已对齐）
                if (ax_frm >= 0 && ax_frm < 5) begin
                    gwd_i = ax_base + (ax_j >> 1);
                    gpx = (ax_j & 1) ? u_top.u_dram.sdram.mem[gwd_i][31:16]
                                     : u_top.u_dram.sdram.mem[gwd_i][15:0];
                    // RGB565→RGB888 扩展（与 yx_b_scanout_play 同款）
                    gexp = { gpx[15:11], gpx[15:13], gpx[10:5], gpx[10:9],
                             gpx[4:0],   gpx[4:2] };
                    if (video_data_w !== gexp) begin
                        ax_errs = ax_errs + 1;
                        if (ax_errs <= 8)
                            $display("AXERR j=%0d frm=%0d win=%0d base=%0d got=%06h exp=%06h (wd=%08h@%0d) | sc_win=%0d sc_b=%0d sc_st=%0d bands=%0d fd=%0d req=%b",
                                     ax_j, ax_frm, ax_win, ax_base, video_data_w, gexp,
                                     u_top.u_dram.sdram.mem[gwd_i], gwd_i,
                                     u_top.sc_win, scan_band_no, u_top.sc_st,
                                     bands_scanned, frames_done, u_top.win_show_req_w);
                    end
                end
                if (ax_frm >= 0 && ax_frm < 5 && (ax_j % 1280) < 2 && ax_lines < 12)
                    $display("LINEHD t=%0t j=%0d got=%06h exp=%06h primed=%b pair=%08h ld=%b en=%b emp=%b",
                             $time, ax_j, video_data_w, gexp,
                             u_top.u_scanout.u_play.primed, u_top.u_scanout.u_play.pair,
                             u_top.rd1_load_w, u_top.rd1_en_w, u_top.rd1_empty_w);
                ax_j = ax_j + 1;
            end
            if (video_last_w && ax_frm >= 0)
                ax_lines = ax_lines + 1;
        end
    end

    // 写读地址区间互斥（精确版）+ vblank LOAD 计数（100M 域）
    // 真正的冲突 = 控制器当前读地址（rRD1_ADDR）落在扫描写端正在写的带内。
    // 用整个显示窗比较会误报（显示窗很大、写的是其中一带，但显示此刻并不读
    // 那一带）——YX6 实测整窗比较报 9288 次而 ax_errs=0。
    integer wr_lo, wr_hi, rd_lo, rd_hi;
    always @(posedge clk100) begin
        if (rst_n) begin
            wr_lo = (u_top.sc_win ? (FBB + FB_TOTAL) : FBB) + u_top.sc_cur * FB_WB;
            wr_hi = wr_lo + FB_WB;
            rd_lo = u_top.u_sdram.rRD1_ADDR;
            rd_hi = rd_lo + 21'd256;      // 一次读突发
            if (u_top.first_win_done_w && (u_top.sc_st >= 3'd2) && (u_top.sc_st <= 3'd4) &&
                (wr_lo < rd_hi) && (rd_lo < wr_hi)) begin
                mutex_errs = mutex_errs + 1;
                if (mutex_errs <= 4)
                    $display("MUTEX-ERR t=%0t wr=[%0d,%0d) rd=[%0d,%0d) st=%0d",
                             $time, wr_lo, wr_hi, rd_lo, rd_hi, u_top.sc_st);
            end
            if (u_top.rd1_load_w) vbl_loads = vbl_loads + 1;
        end
    end

    // ★ P5 WR1 排空计数等价性（HDL-8007 修复的逐拍证明）：顶层原用写 FIFO 内部
    //   rp_bin 影子差分（综合不可见），现改 pop 打拍计数。此处在 TB 侧复刻原
    //   影子差分模型（仿真可穿透 shim），每拍与 DUT 的 wr1_popd 比对，须恒等。
    //   同时覆盖"空 FIFO 不被读"前提（若读空，re 计数会多于 rp 步进而失配）。
    //   posedge 采样读到的均为 NBA 更新前的旧值，模型与 DUT 同拍推进。
    reg  [9:0]  wq_rp_q = 10'd0;
    reg  [12:0] wq_popd = 13'd0;
    reg  [9:0]  wq_rp_now, wq_rp_d;
    integer     wr1_eq_errs = 0;
    always @(posedge clk100 or negedge rst_n) begin
        if (!rst_n) begin
            wq_rp_q = 10'd0;
            wq_popd = 13'd0;
        end else begin
            if (u_top.wr1_popd !== wq_popd) begin
                wr1_eq_errs = wr1_eq_errs + 1;
                if (wr1_eq_errs <= 4)
                    $display("WR1EQ-ERR t=%0t dut=%0d model=%0d st=%0d",
                             $time, u_top.wr1_popd, wq_popd, u_top.sc_st);
            end
            wq_rp_now = u_top.u_sdram.write_fifo1.logic_fifo.SAMEDOM.rp_bin;
            wq_rp_d   = wq_rp_now - wq_rp_q;
            wq_rp_q   = wq_rp_now;
            wq_popd   = (u_top.sc_st == 3'd1) ? 13'd0 : (wq_popd + {3'd0, wq_rp_d});
        end
    end

    // ================= 索引窗文件金标（真实流）=================
    // region_done[w] 上升沿 = 窗 w 已整窗落 SDRAM（seq_wr v3 组屏障保证）。
    // 第 N 次写窗 w ↔ 帧 2*(N-1)+w（f0→w0、f1→w1、f2→w0、f3→w1、f4→w0）。
`ifdef BBOARD_SYS
    task igold_cmp;
        input integer w;
        integer loc;
        begin
            gfi = 2 * ((w == 0) ? win_wr_cnt0 : win_wr_cnt1) + w;
            if (w == 0) win_wr_cnt0 = win_wr_cnt0 + 1; else win_wr_cnt1 = win_wr_cnt1 + 1;
            gwbase = w * NBW;
            loc = 0;
            for (gi = 0; gi < NBW; gi = gi + 1) begin
                if (u_top.u_dram.sdram.mem[gwbase + gi] !== {16'h0000, gidx_mem[gfi*NBW + gi]}) begin
                    idx_golden_errs = idx_golden_errs + 1;
                    loc = loc + 1;
                    if (igerr_first_i[gfi] < 0) igerr_first_i[gfi] = gi;
                    if (idx_golden_errs <= 8)
                        $display("IGOLDEN-ERR f=%0d w=%0d i=%0d sdram=%08h exp=%04h",
                                 gfi, w, gi, u_top.u_dram.sdram.mem[gwbase + gi],
                                 gidx_mem[gfi*NBW + gi]);
                end
            end
            igerr_cnt_f[gfi] = igerr_cnt_f[gfi] + loc;
        end
    endtask

    always @(posedge clk100) begin
        if (rst_n && gidx_on) begin
            if (u_top.REAL_IX.u_ixwr.region_done[0] && !rg_prev[0]) igold_cmp(0);
            if (u_top.REAL_IX.u_ixwr.region_done[1] && !rg_prev[1]) igold_cmp(1);
            rg_prev <= u_top.REAL_IX.u_ixwr.region_done;
        end
    end
`endif

    // ================= 字节流发生器 =================
    localparam SMAX = 4*1024*1024;
    reg [7:0] smem [0:SMAX-1];
    integer slen, soff, sent, payload_len, sf;
    integer feed_cnt = 0;      // FEED 探针独立计数（ETH 模式 sent 恒 0）
    reg [255:0] path;
    integer hdr_cb;

    // ================= 主控 =================
    integer wd = 12000000;
    integer cyc = 0;
    reg     init_done = 1'b0;    // 顶层 SDRAM 初始化完成（ETH 发送进程的门）
    initial begin
        if (!$value$plusargs("STREAM=%s", path)) begin $display("TB-ERR: +STREAM 必需"); $finish; end
        if (!$value$plusargs("WD=%d", wd)) wd = 12000000;
`ifdef BBOARD_SYS
        // SYS 模式：整文件（含文件头/码本）经流口喂入，码本由头解析装载，BOOK 可省
`endif
        sf = $fopen(path, "rb");
        if (sf == 0) begin $display("TB-ERR: 打不开 %s", path); $finish; end
        slen = $fread(smem, sf);
        $fclose(sf);
        hdr_cb = smem[14] | (smem[15] << 8);
        // 文件金标（真实流，gen_golden.py 生成）；未给参数 → 合成流公式路径
        if ($value$plusargs("GOLDEN_IDX=%s", gidx_path)) begin
            $readmemh(gidx_path, gidx_mem);
            gidx_on = 1;
        end
        if ($value$plusargs("GOLDEN_FB=%s", gfb_path)) begin
            $readmemh(gfb_path, gfb_mem);
            gfb_on = 1;
        end
        for (k = 0; k < 6; k = k + 1) begin
            igerr_cnt_f[k] = 0; igerr_first_i[k] = -1;
            gerr_cnt_f[k] = 0; gerr_first_b[k] = -1;
        end
`ifdef BBOARD_SYS
        soff = 0;
`else
        soff = 20 + hdr_cb*32;
`endif
        payload_len = slen - soff;
        $display("TB: stream=%0dB cb=%0d payload=%0d", slen, hdr_cb, payload_len);

        rst_n = 0; #40; @(posedge clk100); rst_n = 1;
        wait (u_top.u_sdram.sdram_pll1.extlock === 1'b1);
        #250000;   // INIT_PER=24000 clk（100M）+ 裕量
        $display("INIT done t=%0t", $time);
        init_done = 1'b1;

        // 推流：valid 高直至 ready 采样（带拍数上限，避免 accept 长期为低时死等）
        sent = 0;
`ifndef BBOARD_ETH
        s_data = smem[soff];
        s_valid = 1'b1;
`endif
`ifdef BBOARD_ETH
        while (!eth_tx_done && cyc < wd) begin
`else
        while (sent < payload_len && cyc < wd) begin
`endif
            @(posedge clk100);
            cyc = cyc + 1;
`ifdef BBOARD_ETH
            sent = eth_byte_cnt;      // 观测：已转发字节数（POLL 显示用）
`endif
            if (s_ready) begin
`ifndef BBOARD_ETH
                sent = sent + 1;
                if (sent < payload_len) s_data <= smem[soff + sent];
                else s_valid <= 1'b0;
`endif
            end
            if (frame_done_vq) begin
                frames_done = frames_done + 1;
                $display("FRAME #%0d t=%0d bands=%0d errs=%0d stall2=%0d rd_b=%0d dispE=%0d win=%0d dp=%0d commit=%0d rno=%0d bst=%0d scb=%b",
                         frames_done, cyc, bands_scanned, scan_errs, stall2_cnt,
                         rd_bursts, disp_empty_cnt, u_top.win_show,
                         u_top.disp_pass, commit_no, rendered_no,
                         u_top.u_band.st, u_top.sc_busy);
            end
            if (cyc % 250000 == 0) begin
                $display("POLL t=%0d sent=%0d commit=%0d rno=%0d ixph=%0d act=%b busy=%b%b pf=%0d prno=%0d rdrq=%b | band: st=%0d b=%0d bx=%0d f=%b fw=%b pd=%0d | fet: dr=%b ov=%b cap=%b lr=%b emp=%b re=%b dvl=%b rl=%b bm1=%b we=%b ab=%0d | scan: st=%0d cur=%0d pv=%b push=%0d drn=%0d | ixwr: st=%0d gnt=%b pf_full=%b | ctl: msk=%b mwr=%b ST=%0d ack=%b rpd=%b rreq=%b exw=%b exr=%b dwa=%b dra=%b | w2f: full=%b occ=%0d af=%b wp=%0d rp=%0d rst=%b cw=%b | f1: AE=%0d occ=%0d wp=%0d rp=%0d | rd1f: af=%b emp=%b wb=%0d rbw=%0d ld=%b ldX=%b afX=%b w1=%b r1=%b | ixw2: st=%0d vld=%b gnt=%b en=%b ld=%b full=%b dc=%0d win=%b wn=%b | cnt: ivc=%0d gnc=%0d ldc=%0d psc=%0d fwc=%0d",
                         cyc, sent, commit_no, u_top.rno_done, u_top.u_ixbuf.phase,
                         u_top.u_ixbuf.act, u_top.u_ixbuf.busy[1], u_top.u_ixbuf.busy[0],
                         u_top.u_ixbuf.pf_cnt, u_top.u_ixbuf.prev_rno,
                         u_top.band_rd_req_w,
                         u_top.u_band.st, u_top.u_band.band, u_top.u_band.bx,
                         u_top.u_band.fetch_r, u_top.u_band.frame_wait,
                         u_top.u_band.pend_cnt,
                         u_top.REAL_IX.u_ixfetch.drain, u_top.REAL_IX.u_ixfetch.out_v,
                         u_top.REAL_IX.u_ixfetch.cap, u_top.REAL_IX.u_ixfetch.load_r,
                         u_top.rd2_empty_w, u_top.ixf_re_w, u_top.ixf_dvld_w,
                         u_top.fetch_reload_r, u_top.rd2_bmask1_w, u_top.rd2_we_w,
                         u_top.act_base,
                         u_top.sc_st, u_top.sc_cur, u_top.sc_pend_v, u_top.sc_push,
                         u_top.sc_drain,
                         u_top.REAL_IX.u_ixwr.st, u_top.REAL_IX.u_ixwr.wr_gnt,
                         u_top.REAL_IX.u_ixwr.wr2_full,
                         u_top.u_sdram.WR_MASK, u_top.u_sdram.mWR,
                         u_top.u_sdram.ST, u_top.u_sdram.CMDACK,
                         u_top.u_sdram.command1.rp_done, u_top.u_sdram.control1.REF_REQ,
                         u_top.u_sdram.command1.ex_write, u_top.u_sdram.command1.ex_read,
                         u_top.u_sdram.command1.do_writea, u_top.u_sdram.command1.do_reada,
                         u_top.wr2_full_w, u_top.u_sdram.write_fifo2.logic_fifo.SAMEDOM.occ,
                         u_top.u_sdram.write_fifo2.logic_fifo.afull_flag,
                         u_top.u_sdram.write_fifo2.logic_fifo.SAMEDOM.wp_bin,
                         u_top.u_sdram.write_fifo2.logic_fifo.SAMEDOM.rp_bin,
                         u_top.u_sdram.write_fifo2.logic_fifo.rst,
                         u_top.u_sdram.write_fifo2.logic_fifo.clkw,
                         u_top.u_sdram.write_fifo1.logic_fifo.AE,
                         u_top.u_sdram.write_fifo1.logic_fifo.SAMEDOM.occ,
                         u_top.u_sdram.write_fifo1.logic_fifo.SAMEDOM.wp_bin,
                         u_top.u_sdram.write_fifo1.logic_fifo.SAMEDOM.rp_bin,
                         u_top.u_sdram.rd1_afull_w, u_top.rd1_empty_w,
                         u_top.u_sdram.read_fifo1.logic_fifo.ASYNDOM.wbin,
                         u_top.u_sdram.read_fifo1.logic_fifo.ASYNDOM.rbin_w,
                         u_top.rd1_load_w, (^u_top.rd1_load_w === 1'bx),
                         (^u_top.u_sdram.rd1_afull_w === 1'bx),
                         (^u_top.u_sdram.read_fifo1.logic_fifo.ASYNDOM.wgray === 1'bx),
                         (^u_top.u_sdram.read_fifo1.logic_fifo.ASYNDOM.rgray === 1'bx),
                         u_top.REAL_IX.u_ixwr.st,
                         u_top.wr_valid_w,
                         u_top.ixwr_gnt_w,
                         u_top.REAL_IX.u_ixwr.wr2_en,
                         u_top.REAL_IX.u_ixwr.wr2_load,
                         u_top.wr2_full_w,
                         u_top.REAL_IX.u_ixwr.drain_cnt,
                         u_top.REAL_IX.u_ixwr.win,
                         u_top.REAL_IX.u_ixwr.win_next,
                         ivc, gnc, ldc, psc, fwc);
`ifdef BBOARD_SYS
                $display("POLLCP t=%0d on=%b ld=%b pv=%b pos=%0d req=%b wa=%0d wv=%b dv=%b qt=%b | dlv=%0d dsc=%0d stl=%0d lds=%0d",
                         cyc,
                         u_top.REAL_IX.u_ixfetch.cp_on,
                         u_top.REAL_IX.u_ixfetch.cp_ld,
                         u_top.REAL_IX.u_ixfetch.cp_pos_v,
                         u_top.REAL_IX.u_ixfetch.cp_pos,
                         cp_rd_w, u_top.cp_addr,
                         u_top.REAL_IX.u_ixfetch.cp_w_v,
                         u_top.REAL_IX.u_ixfetch.cp_dvld,
                         u_top.REAL_IX.u_ixfetch.cp_quiet,
                         cp_deliv, cp_disc, cp_stale, cp_loads);
`endif
                $fflush;      // 实时落盘（长跑时 POLL/FRAME 可即时观测）
            end
        end
`ifndef BBOARD_ETH
        s_valid <= 1'b0;
`endif

        // 等渲染/扫描收尾 + 显示至少一整有效遍（P3：AXIS 对拍覆盖 720 行）
        // ★ 收尾条件：等 5 帧渲染完成（frames_done*BH），并保证显示已覆盖
        //   至少 720 行有效遍；不能用 ax_lines 单独触发（会早退，实测只跑 3 帧）
        while (cyc < wd && (frames_done < 5 || bands_scanned < 5*BH || ax_lines < 720)) begin
            @(posedge clk100); cyc = cyc + 1;
            if (frame_done_vq) begin
                frames_done = frames_done + 1;
                $display("FRAME #%0d t=%0d bands=%0d errs=%0d rd_b=%0d dispE=%0d win=%0d dp=%0d commit=%0d rno=%0d bst=%0d",
                         frames_done, cyc, bands_scanned, scan_errs, rd_bursts,
                         disp_empty_cnt, u_top.win_show, u_top.disp_pass,
                         commit_no, rendered_no, u_top.u_band.st);
            end
        end
        #100000;

        // 诊断（不影响判定）：SDRAM 行为模型 mem 落写检查
        begin : mem_probe
            nx_idx = 0; nx_fb = 0;
            for (mx = 0; mx < FBB; mx = mx + 1)
                if (^u_top.u_dram.sdram.mem[mx] !== 1'bx) nx_idx = nx_idx + 1;
            // ★ P3 双窗：帧缓冲 = 两个帧窗 [FBB, FBB+2*FB_TOTAL)
            for (mx = FBB; mx < FBB + 2*FB_TOTAL; mx = mx + 1)
                if (^u_top.u_dram.sdram.mem[mx] !== 1'bx) nx_fb = nx_fb + 1;
            $display("MEMCHK idx_nonX=%0d/%0d fb_nonX=%0d/%0d m0=%08h m1=%08h m2=%08h",
                     nx_idx, FBB, nx_fb, 2*FB_TOTAL,
                     u_top.u_dram.sdram.mem[0], u_top.u_dram.sdram.mem[1],
                     u_top.u_dram.sdram.mem[2]);
            $display("SDCMD act=%0d wr=%0d rd=%0d pre=%0d ref=%0d",
                     sd_act, sd_wr, sd_rd, sd_pre, sd_ref);
            $display("WRWIN idx: beats=%0d X=%0d real=%0d firstX@linear=%0d",
                     w_x_idx + w_r_idx, w_x_idx, w_r_idx, x_i_a);
            $display("WRIDX-S a=%0d v=%08h | a=%0d v=%08h | a=%0d v=%08h | a=%0d v=%08h | a=%0d v=%08h",
                     sa_i0, s_i0, sa_i1, s_i1, sa_i2, s_i2, sa_i3, s_i3, sa_i4, s_i4);
            $display("WRWIN fb: beats=%0d X=%0d real=%0d firstX@linear=%0d",
                     w_x_fb + w_r_fb, w_x_fb, w_r_fb, x_f_a);
            $display("WRFB-S a=%0d v=%08h | a=%0d v=%08h | a=%0d v=%08h | a=%0d v=%08h | a=%0d v=%08h",
                     sa_f0, s_f0, sa_f1, s_f1, sa_f2, s_f2, sa_f3, s_f3, sa_f4, s_f4);
            $display("FIFOPOP wr1: pops=%0d doX=%0d mismatch=%0d underrun=%0d mm(seq=%0d exp=%08h got=%08h)",
                     n1c, x1c, m1c, u1c, mm1s, mm1e, mm1g);
            $display("FIFOPOP wr2: pops=%0d doX=%0d mismatch=%0d underrun=%0d mm(seq=%0d exp=%08h got=%08h)",
                     n2c, x2c, m2c, u2c, mm2s, mm2e, mm2g);
            $display("PUSHSTAT wr1: pushes=%0d X=%0d real=%0d first3_real=%08h,%08h,%08h",
                     t1q, px1c, pr1c, pv1_0, pv1_1, pv1_2);
            $display("PUSHSTAT wr2: pushes=%0d X=%0d real=%0d first3_real=%08h,%08h,%08h",
                     t2q, px2c, pr2c, pv2_0, pv2_1, pv2_2);
            $display("CPSTAT deliv=%0d disc=%0d stale=%0d loads=%0d (disc=补丁跳字+对齐首段丢弃，后者=LOAD地址 mod64)",
                     cp_deliv, cp_disc, cp_stale, cp_loads);
            $display("IGERR-DIST f0=%0d(first i=%0d) f1=%0d(i=%0d) f2=%0d(i=%0d) f3=%0d(i=%0d) f4=%0d(i=%0d)",
                     igerr_cnt_f[0], igerr_first_i[0], igerr_cnt_f[1], igerr_first_i[1],
                     igerr_cnt_f[2], igerr_first_i[2], igerr_cnt_f[3], igerr_first_i[3],
                     igerr_cnt_f[4], igerr_first_i[4]);
            $display("GERR-DIST f0=%0d(first b=%0d) f1=%0d(b=%0d) f2=%0d(b=%0d) f3=%0d(b=%0d) f4=%0d(b=%0d)",
                     gerr_cnt_f[0], gerr_first_b[0], gerr_cnt_f[1], gerr_first_b[1],
                     gerr_cnt_f[2], gerr_first_b[2], gerr_cnt_f[3], gerr_first_b[3],
                     gerr_cnt_f[4], gerr_first_b[4]);
        end

        // ---- 收口判定 1：关键输出 X/Z 检查（归约异或，任一位 x/z 即检出）----
        xz_errs = 0;
        if (^commit_no === 1'bx)    begin xz_errs = xz_errs + 1; $display("XZ commit_no");    end
        if (^rendered_no === 1'bx)  begin xz_errs = xz_errs + 1; $display("XZ rendered_no");  end
        if (^disp_pass_w === 1'bx)  begin xz_errs = xz_errs + 1; $display("XZ disp_pass");   end
        if (^disp_stall_w === 1'bx) begin xz_errs = xz_errs + 1; $display("XZ disp_stall");  end
        if (^win_show_w === 1'bx)   begin xz_errs = xz_errs + 1; $display("XZ win_show");    end
        if (^scan_band_no === 1'bx) begin xz_errs = xz_errs + 1; $display("XZ scan_band_no"); end
        if (^pend_cnt === 1'bx)     begin xz_errs = xz_errs + 1; $display("XZ pend_cnt");     end
        if ((frame_done_vq === 1'bx) || (scan_done === 1'bx) || (scan_ack === 1'bx)) begin
            xz_errs = xz_errs + 1; $display("XZ handshake");
        end

        // ---- 收口判定 2：逐条判据打印实际值（FAIL 可定位到条）----
        // 判据严格强于旧版（旧版仅 scan_errs==0 && disp_errs==0 && frames_done>=5）
        pd = (dec_frames    == 5);
        pf = (frames_done   == 5);
        pb = (bands_scanned == 5*BH);   // 720p: 5*180 = 900
        pg = (golden_errs   == 0);
        ps = (scan_errs     == 0);
        px = (xz_errs       == 0);
        // mem 落写门禁（补 X===X 盲区）：索引区/帧区任一为全 X 即 BAD
        pm = (nx_idx > 0) && (nx_fb > 0);
        // 索引窗文件金标（真实流）+ 合并流越位违例计数
        pig = (gidx_on == 0) || (idx_golden_errs == 0);
        pce = (u_top.u_ixbuf.cp_err == 0);
        // cp 分时服务精确计数（fetch v5 契约闭环验收，真实流专属）：
        //   交付 = ΣDELTA(NB-npatch) = 3*NBW-6588（f1 D595/f2 D355/f4 D5638）。
        //   重 LOAD 次数依赖运行期抢占时序（帧尾空闲窗被新帧 SWAP 打断 →
        //   重入重 LOAD），不做精确门禁，仅作观测。
        pcp = (gidx_on == 0) || (cp_deliv == 3*NBW - 6588);
        // 首帧 KEY 强制校验收口（hdr_parse f0_chk；模式 1 无 hdr_parse → 悬空 Z 视为通过）
        phe = (u_top.hdr_err_w !== 1'b1);
        // P3 显示判据：AXIS 内容对拍 + 覆盖 ≥1 有效遍 + 写读窗互斥 + RD1 供数
        pax = (ax_errs == 0) && (ax_lines >= 720);
`ifdef BBOARD_ETH
        // P4 传输层判据：全部包 CRC 正确（ok=包数）、零丢包、转发的字节数
        // 必须等于源文件长度（slen）。
        peth = (eth_ok_cnt == e_npkt) && (eth_drop_cnt == 0) &&
               (eth_byte_cnt == slen);
`else
        peth = 1'b1;
`endif
        pmu = (mutex_errs == 0);
        // disp_stall 含消隐期冲洗（正常），且已被 skid 吸收——ax_errs=0 是
        // 更强的逐像素证据，故 stall 仅作观测，不进 AND 链。
        pst = 1'b1;
        $display("GATE dec_frames=%0d(want 5:%s) frames_done=%0d(want 5:%s) bands=%0d(want %0d:%s) golden=%0d(want 0:%s) scan=%0d(want 0:%s) xz=%0d(want 0:%s) mem=%0d/%0d(want >0:%s) igold=%0d(want 0:%s) cperr=%0d(want 0:%s) cpdeliv=%0d(want %0d:%s) cploads=%0d hdrerr=%0d(want 0:%s) axerr=%0d(want 0:%s) axlines=%0d(want >=720:%s) mutex=%0d(want 0:%s) dstall=%0d(want 0:%s)",
                 dec_frames, pd?"OK":"BAD", frames_done, pf?"OK":"BAD",
                 bands_scanned, 5*BH, pb?"OK":"BAD",
                 golden_errs, pg?"OK":"BAD",
                 scan_errs, ps?"OK":"BAD",
                 xz_errs, px?"OK":"BAD",
                 nx_idx, nx_fb, pm?"OK":"BAD",
                 idx_golden_errs, pig?"OK":"BAD",
                 u_top.u_ixbuf.cp_err, pce?"OK":"BAD",
                 cp_deliv, 3*NBW - 6588, pcp?"OK":"BAD",
                 cp_loads,
                 u_top.hdr_err_w, phe?"OK":"BAD",
                 ax_errs, pax?"OK":"BAD",
                 ax_lines, (ax_lines >= 720)?"OK":"BAD",
                 mutex_errs, pmu?"OK":"BAD",
                 disp_stall_w, pst?"OK":"BAD");
        $display("GATE-WR1 eq_errs=%0d(want 0:%s)", wr1_eq_errs, (wr1_eq_errs == 0)?"OK":"BAD");
`ifdef BBOARD_ETH
        $display("GATE-ETH ok=%0d(want %0d:%s) drop=%0d(want 0:%s) bytes=%0d(want %0d:%s)",
                 eth_ok_cnt, e_npkt, (eth_ok_cnt == e_npkt)?"OK":"BAD",
                 eth_drop_cnt, (eth_drop_cnt == 0)?"OK":"BAD",
                 eth_byte_cnt, slen, (eth_byte_cnt == slen)?"OK":"BAD");
        // ★ 压力分支必须留在本 `ifdef BBOARD_ETH` 内：它引用的 nostall / eth_* /
        //   e_npkt / slen 都只在 ETH 构建里声明。初版把 `if (nostall)` 写到了
        //   `endif` 之后，导致 bboard_sys / bboard_key 编译报
        //   "Unable to bind wire/reg/memory `nostall'"（实测 2026-11-25）。
        //   结构：ETH 构建走 if/else；非 ETH 构建只有 else 那条 pfinal 赋值。
        if (nostall) begin
            // ---- 压力模式（+NOSTALL）：换判据，不判解码正确性 ----
            //   不节流必然整包丢弃 → 码流不完整 → 解码/金标/逐带对拍判据在此不适用。
            //   （这是**换判据**，不是放宽判据：默认入口的判据一个字没动。）
            //   只判两件事：
            //     1. drop > 0 —— 过载确实发生，否则没测到饱和点，测量无效；
            //     2. delivered > 0 —— 设计仍能把数据推出去。若超载就卡死（FIFO 满导致
            //        下游状态机不推进），这里会是 0 或整个仿真超时。
            //   ★ 速率用**发送窗口**（st_cyc_tx / st_byte_tx），不用整段 st_cyc：
            //     否则随后的空转期会把速率稀释十几倍，得到一个毫无意义的小数。
            st_rate     = (st_byte_tx * 100.0) / ((st_cyc_tx > 0) ? st_cyc_tx : 1);  // = MB/s
            st_rate_off = (slen       * 100.0) / ((st_cyc_tx > 0) ? st_cyc_tx : 1);
            pstress = (eth_drop_cnt > 0) && (eth_byte_cnt > 0);
            // ★ 注意 offered 不是 125MB/s（GMII 线速）：tb 的 e_send_pkt 为了算 FCS
            //   先把载荷走一遍（@(posedge gmii_clk)），再走一遍真正发送，所以每个包
            //   花约两倍 gmii 周期 —— 实际 offered ≈ 59MB/s。写成常量 125 会误导。
            $display("GATE-STRESS offered=%0.2f_MBps pkts_ok=%0d/%0d dropped=%0d delivered=%0d/%0d (%0d%%)",
                     st_rate_off, eth_ok_cnt, e_npkt, eth_drop_cnt, eth_byte_cnt, slen,
                     (eth_byte_cnt*100)/((slen>0)?slen:1));
            $display("GATE-RATE win_clk=%0d delivered_in_win=%0d of %0d bytes -> window_rate=%0.2f_MBps",
                     st_cyc_tx, st_byte_tx, slen, st_rate);
            pfinal = pstress;          // 结果交给下面唯一那条 TB-SUMMARY
        end else
`endif
            pfinal = (pd && pf && pb && pg && ps && px && pm && pig && pce && pcp &&
                      phe && pax && pmu && pst && peth && (wr1_eq_errs == 0));
        $display("=== TB-SUMMARY: %s ===", pfinal ? "ALL PASS" : "FAIL");
        $display("DECFRAMES=%0d", dec_frames); $display("IXWR ivc=%0d gnc=%0d psc=%0d ldc=%0d fwc=%0d", ivc, gnc, psc, ldc, fwc); $display("GOLDEN=%0d", golden_errs);
        $display("CNT: frames=%0d bands=%0d scan_errs=%0d ax_errs=%0d ax_beats=%0d ax_lines=%0d disp_pass=%0d disp_stall=%0d vbl_loads=%0d stall2=%0d/%0d (%0d%%)",
                 frames_done, bands_scanned, scan_errs, ax_errs, ax_beats, ax_lines,
                 disp_pass_w, disp_stall_w, vbl_loads,
                 stall2_cnt, total_cnt, (stall2_cnt*100)/(total_cnt>0?total_cnt:1));
        // ---- 逐级占空比（定位 0.85x 的阻断级）----
        // 完整周期会计：六项之和应 = duty_tot（差值是 st=1 的其它拍）
        $display("DUTY tot=%0d sdram_busy=%0d (%0d%%)",
                 duty_tot, duty_sdram_busy, (duty_sdram_busy*100)/((duty_tot>0)?duty_tot:1));
        $display("DUTY-BAND idle=%0d(%0d%%) backpressure=%0d(%0d%%) issue=%0d(%0d%%) fetchwait=%0d(%0d%%) book=%0d(%0d%%) write=%0d(%0d%%)",
                 w_idle,         (w_idle*100)/((duty_tot>0)?duty_tot:1),
                 w_backpressure, (w_backpressure*100)/((duty_tot>0)?duty_tot:1),
                 w_issue,        (w_issue*100)/((duty_tot>0)?duty_tot:1),
                 w_fetchwait,    (w_fetchwait*100)/((duty_tot>0)?duty_tot:1),
                 w_book,         (w_book*100)/((duty_tot>0)?duty_tot:1),
                 w_write,        (w_write*100)/((duty_tot>0)?duty_tot:1));
        $display("DUTY-CHK sum=%0d tot=%0d (st1-其它=%0d)",
                 w_idle+w_backpressure+w_issue+w_fetchwait+w_book+w_write, duty_tot,
                 duty_tot-(w_idle+w_backpressure+w_issue+w_fetchwait+w_book+w_write));
        // ---- band 在 st=0 等帧期间，上游解码链在干什么 ----
        $display("DUTY-DECODE tot_idle=%0d ixdec_busy=%0d(%0d%%) ixdec_hdr=%0d(%0d%%) ixwr_wait=%0d(%0d%%) ixwr_push=%0d(%0d%%) ixwr_grp=%0d(%0d%%) sdram=%0d(%0d%%) dec_nrdy=%0d(%0d%%) hdr_nrdy=%0d(%0d%%)",
                 di_tot,
                 di_ixdec_busy, (di_ixdec_busy*100)/((di_tot>0)?di_tot:1),
                 di_ixdec_hdr,  (di_ixdec_hdr*100)/((di_tot>0)?di_tot:1),
                 di_ixwr_wait,  (di_ixwr_wait*100)/((di_tot>0)?di_tot:1),
                 di_ixwr_push,  (di_ixwr_push*100)/((di_tot>0)?di_tot:1),
                 di_ixwr_grp,   (di_ixwr_grp*100)/((di_tot>0)?di_tot:1),
                 di_sdram,      (di_sdram*100)/((di_tot>0)?di_tot:1),
                 di_dec_nrdy,   (di_dec_nrdy*100)/((di_tot>0)?di_tot:1),
                 di_hdr_nrdy,   (di_hdr_nrdy*100)/((di_tot>0)?di_tot:1));
        // ---- ixdec 状态分布（0..4 收头 / 5 KEY / 6 MAP / 7 WALK / 8 DIDX / 9 FD / 10 WALKR）----
        $display("DUTY-IXDEC hdr0-4=%0d KEY=%0d MAP=%0d WALK=%0d DIDX=%0d FD=%0d WALKR=%0d (tot=%0d)",
                 dx_st[0]+dx_st[1]+dx_st[2]+dx_st[3]+dx_st[4],
                 dx_st[5], dx_st[6], dx_st[7], dx_st[8], dx_st[9], dx_st[10], duty_tot);
        $display("DUTY-IXDEC pct: KEY=%0d%% MAP=%0d%% WALK=%0d%% DIDX=%0d%% FD=%0d%% WALKR=%0d%%",
                 (dx_st[5]*100)/((duty_tot>0)?duty_tot:1), (dx_st[6]*100)/((duty_tot>0)?duty_tot:1),
                 (dx_st[7]*100)/((duty_tot>0)?duty_tot:1), (dx_st[8]*100)/((duty_tot>0)?duty_tot:1),
                 (dx_st[9]*100)/((duty_tot>0)?duty_tot:1), (dx_st[10]*100)/((duty_tot>0)?duty_tot:1));
        // ---- S_WALK 子情况（walk_next 应为每块 1 拍；walk_wait 才是真停滞）----
        $display("DUTY-WALK walk_next=%0d(%0d%%) walk_didx=%0d(%0d%%) walk_wait=%0d(%0d%%) map1=%0d",
                 dw_walk_next, (dw_walk_next*100)/((duty_tot>0)?duty_tot:1),
                 dw_walk_didx, (dw_walk_didx*100)/((duty_tot>0)?duty_tot:1),
                 dw_walk_wait, (dw_walk_wait*100)/((duty_tot>0)?duty_tot:1), dw_map1);
        $display("DUTY-WAIT phase=%0d(%0d%%) pfroom=%0d(%0d%%) busy_other=%0d(%0d%%) (of walk_wait=%0d)",
                 iw_phase, (iw_phase*100)/((dw_walk_wait>0)?dw_walk_wait:1),
                 iw_pfroom, (iw_pfroom*100)/((dw_walk_wait>0)?dw_walk_wait:1),
                 iw_busy, (iw_busy*100)/((dw_walk_wait>0)?dw_walk_wait:1), dw_walk_wait);
        $display("AXDBG clk_cnt=%0d valid_cnt=%0d user_cnt=%0d first_user_t=%0t frm=%0d",
                 ax_clk_cnt, ax_valid_cnt, ax_user_cnt, ax_first_user_t, ax_frm);
        $finish;
    end

    // 看门狗
    integer c100 = 0;
    always @(posedge clk100) c100 = c100 + 1;
    initial begin
        #(wd * 20 + 5000000);
        $display("=== WATCHDOG: frames=%0d bands=%0d scan_errs=%0d ===", frames_done, bands_scanned, scan_errs);
        $display("DIAG: clk100_edges=%0d extlock=%b rst_n=%b", c100,
                 u_top.u_sdram.sdram_pll1.extlock, rst_n);
        $display("=== TB-SUMMARY: FAIL (watchdog) ===");
        $finish;
    end
endmodule
