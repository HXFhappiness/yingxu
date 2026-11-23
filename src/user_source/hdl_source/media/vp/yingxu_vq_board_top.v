// yingxu_vq_board_top.v — 板 B SoC 顶层（VQ 视频协处理，仿真验收版）
//
// 数据流：A板字节流 → ixdec → ixbuf → band（深度2握手+双扫描读口）
//          → 扫描写端（行缓冲半区 → WR1 → SDRAM 帧缓冲，band-major 页对齐）
//          → 显示消费端（RD1 连续流读出，按带节拍）
//
// 时钟：单域 100MHz（控制器内部 Sdram_PLL clk0 → clk100）；视频逻辑与控制器同域直连。
// SDRAM 帧缓冲布局：带 b 的 4 行×1280 像素 = 5120 像素 = 2560 字(32bit, 2像素/字)
//   = 10 页(256字/页)，页对齐；带 b 占 [b*2560, (b+1)*2560)。
//
// 索引缓冲的 SDRAM 口（逐字随机地址：ixbuf 补丁写、band 取带读）从顶层引出——
// vendor 4port 控制器只支持顺序突发。★ cp 拷贝读口已闭环（fetch v5 经 RD2 分时
// 顺序承载，板上无随机口）；ixbuf 补丁写经 seq_wr/WR2 顺序组协议承载。顶层
// cp_dvld/cp_data/band_rd_* 输入口仅 SIM_ABSTRACT=1（抽象仿真）消费。
// 帧缓冲走真实控制器（页模式流式，恰为其设计用途）。
//
// 扫描读双口（scan_ra/scan_rb）每拍取偶/奇两像素打包 32bit 字 → WR1 推数 1 字/拍
// 与突发排空同速（不欠载，sanity 实测契约）。地址流水：LOAD 拍发首地址，PUSH 态
// 每拍"推上一拍地址的数据 + 发下一地址"，恰好 256 拍推 256 字。
module yingxu_vq_board_top #(
    parameter W      = 1280,
    parameter H      = 720,
    parameter CBSIZE = 1024,
    parameter AW     = 17,
    parameter NB     = (W/4)*(H/4),
    // 1=抽象口模式（既有仿真：流/索引 SDRAM 由 TB 侧承载）；0=体系模式：
    // 头解析+码本装载、索引顺序写（WR2）、取带读出（RD2）全部内部实例化
    parameter SIM_ABSTRACT = 1
)(
    input  wire        ref_clk,        // 50M 晶振（控制器内部 PLL 生成 100M）
    input  wire        rst_n,

    // ---- A→B 字节流 ----
    input  wire        stream_valid,
    input  wire [7:0]  stream_data,
    output wire        stream_ready,

    // ---- 索引缓冲 SDRAM 口（顶层引出，随机访问）----
    output wire          ix_wr_valid,
    output wire [AW-1:0] ix_wr_addr,
    output wire [15:0]   ix_wr_data,
    input  wire          ix_wr_gnt,
    output wire          cp_rd,
    output wire [AW-1:0] cp_addr,
    input  wire          cp_dvld,
    input  wire [15:0]   cp_data,
    output wire          band_rd_req,
    output wire [AW-1:0] band_rd_addr,
    input  wire          band_rd_dvld,
    input  wire [15:0]   band_rd_data,

    // ---- HDMI 扫出观测口（P3；TD 构建下同一信号入加密核）----
    output wire        video_user,      // 帧首 sideband（每帧 1 拍）
    output wire        video_valid,     // 活跃像素有效
    output wire        video_last,      // 活跃行末
    output wire [23:0] video_data,      // RGB888 像素流
    // ---- 显示遥测（像素域）----
    output wire        win_show,        // 当前显示窗号
    output wire [15:0] disp_pass,       // 显示遍计数（每帧首 +1）
    output wire [15:0] disp_stall,      // pair 保持事件（RD1 供数不足观测）

    // ---- 状态/遥测 ----
    output wire [15:0] commit_no,
    output wire [15:0] rendered_no,
    output wire        frame_done_vq,   // 渲染整帧完成脉冲
    output reg         scan_done,       // 1 clk：带 scan_band_no 已写入帧缓冲
    output reg  [8:0]  scan_band_no,
    output reg         scan_ack,        // 1 clk：带 scan_band_no 行缓冲半区已释放
    output wire [1:0]  band_pend_cnt,   // 渲染器未 ack 带数（欠扫描观测）
    output wire        dbg_clk100,      // 内部 100M 逻辑域时钟（TB 用；板上为内部走线）
    output wire        dbg_pixel_clk,   // 73.33M 像素时钟（TB 对拍采样用）

    // ---- SDRAM 引脚（TD 布线用；仿真中 sdram_ip 硬宏在顶层内部）----
    inout  wire [31:0] DRAM_DQ,
    output wire [10:0] DRAM_ADDR,
    output wire [1:0]  DRAM_BA,
    output wire [1:0]  DRAM_CS_N,
    output wire        DRAM_CKE, DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N,
    output wire [3:0]  DRAM_DQM,
    output wire        DRAM_CLK
);
    localparam BH       = H/4;             // 180
    localparam PIX_BAND = 4*W;             // 5120 像素/带
    localparam FB_WB    = PIX_BAND/2;      // 2560 字(32bit)/带
    localparam FB_PAGES = FB_WB/256;       // 10 页/带
    localparam FB_TOTAL = BH*FB_WB;        // 460800 字
    localparam FB_BASE  = 2*NB;            // ★ 帧缓冲基址：索引双缓冲 [0,2NB) 之后，
                                           //   与索引区严格不重叠（720p: 115200 起）

    wire clk100;                           // 控制器内部 PLL 输出（本顶层唯一逻辑域）
    assign dbg_clk100 = clk100;
    wire ix_rdy_w;

    // ================= 视频前端 =================
    wire        ix_we;
    wire [16:0] ix_blk;
    wire [9:0]  ix_idx;
    wire        dec_fdone, dec_fstart, dec_fkind;

    // ---- SIM_ABSTRACT=0：头解析/索引写/取带适配接线 ----
    wire        hdr_v, hdr_rdy;
    wire [7:0]  hdr_d;
    wire        dec_v = SIM_ABSTRACT ? stream_valid : hdr_v;
    wire [7:0]  dec_d = SIM_ABSTRACT ? stream_data  : hdr_d;
    assign stream_ready = SIM_ABSTRACT ? dec_rdy_w : hdr_rdy;
    wire        dec_rdy_w;
    wire        hdr_book_we;
    wire [13:0] hdr_book_wa;
    wire [15:0] hdr_book_wd;
    wire        hdr_ok_w, hdr_err_w;
    wire        ixwr_gnt_w;
    wire        ixf_dvld_w, ixf_re_w, ixf_load_w;
    wire [15:0] ixf_data_w;
    wire [20:0] ixf_addr_w;
    wire [31:0] wr2_data_w;
    wire        wr2_en_w, wr2_load_w;
    wire [20:0] wr2_addr_w;
    wire        wr2_full_w;   // ★ 须在 REAL_IX generate 块前声明：否则块内引用会生成同名隐式线网（悬空 Z）
    // ★ WR2 突发完成事件（CLK 域 1 拍）：seq_wr v3 组屏障的推进依据。
    //   mWR_DONE 为 SDR_CLK 域 1 拍脉冲，WR_MASK[1] 在突发期间保持——厂商
    //   控制器自身即用此组合判定 WR2 地址步进（Sdram_Control_4Port.v 同构）。
    wire        wr2_done_w    = u_sdram.mWR_DONE & u_sdram.WR_MASK[1];
    wire [1:0]  ixwr_rdone_w;    // seq_wr 按窗完成标志 → fetch 屏障门
    wire        wr2_busy_w  = (u_sdram.WR_MASK != 2'b00) || (u_sdram.mWR != 1'b0);
    wire        rd2_empty_w;
    wire [31:0] rd2_dat_w;
    wire        rd2_we_w      = u_sdram.OUT_VALID & u_sdram.RD_MASK[1];
    wire        rd2_bmask1_w  = u_sdram.RD_MASK[1];
    wire        wr2_re_w      = u_sdram.IN_REQ & u_sdram.WR_MASK[1];
    // ★ cp 读口体系模式供给线：fetch v5 经 RD2 分时服务 ixbuf 拷贝读（板上契约
    //   闭环——板上无顶层随机口，cp 读 = RD2 顺序流的一段分时复用）。模式 1 仍
    //   走顶层输入口（TB 随机口模型）。cp_rd/cp_addr 为 ixbuf 输出，两模式均
    //   驱动顶层观测口，fetch 直接引同一线网作请求源。
    wire        cp_dvld_ixf_w;
    wire [15:0] cp_data_ixf_w;
    wire          wr_valid_w, swap_done_w;
    wire [AW-1:0] wr_addr_w, act_base;             // ixbuf 当前 active 区基址（= SDRAM 字地址）
    wire [15:0]   wr_data_w;
    wire [20:0] rd2_max_w   = u_band.base_l + NB[20:0];   // 取带窗 = 渲染器锁存基址
    wire        band_rd_req_w;   // band 的取带请求（两种模式都在内部）
    // ★ 行缓冲扫描读地址（悬空修复）：sc_ra 是扫描写端自己的地址计数，
    //   但 band 的 scan_ra/scan_rb 端口此前从未被驱动（悬空 Z → ln[Z]=X →
    //   扫描推数全 X 的根因之一）。scan_rb=奇像素地址（ra+1），与 scan_ra
    //   同拍双口读出，打包 {奇,偶} 32bit 字。
    assign scan_ra_w = sc_ra;
    assign scan_rb_w = sc_ra + 14'd1;
    // 模式复用：模式 1 保持原 WR2/RD2 停用接线（LENGTH=0，行为与已验证版本一致）
    // ★ 模式 0 WR2_LENGTH=128：seq_wr v3 组协议要求"触发阈值(占用≥128)=突发长度"，
    //   128 字组推满即停推→突发恰吞 128 字→FIFO 清 0 零滞留零欠载（NB=57600=128×450）
    wire [31:0] wr2_data_u  = SIM_ABSTRACT ? 32'd0     : wr2_data_w;
    wire        wr2_en_u    = SIM_ABSTRACT ? 1'b0      : wr2_en_w;
    wire [20:0] wr2_addr_u  = SIM_ABSTRACT ? 21'd0     : wr2_addr_w;
    wire        wr2_load_u  = SIM_ABSTRACT ? 1'b0      : wr2_load_w;
    wire [8:0]  wr2_len_u   = SIM_ABSTRACT ? 9'd0      : 9'd128;
    wire        rd2_re_u    = SIM_ABSTRACT ? 1'b0      : ixf_re_w;
    wire [20:0] rd2_addr_u  = SIM_ABSTRACT ? 21'd0     : ixf_addr_w;
    wire        rd2_load_u  = SIM_ABSTRACT ? 1'b0      : ixf_load_w;
    // ★ v4 取带协议：MAX 恒全域（永不自动回卷——rRD2_MAX_ADDR 只在复位锁存，
    //   整窗循环读在窗 1 死循环读窗头）；LENGTH=64（带 320 字=5 突发整除），
    //   fetch 每带边界发 LOAD 锁新带首地址
    wire [20:0] rd2_max_u   = SIM_ABSTRACT ? 21'h1FFFFF: 21'h1FFFFF;
    wire [8:0]  rd2_len_u   = SIM_ABSTRACT ? 9'd0      : 9'd64;
    wire        band_dvld_mux = SIM_ABSTRACT ? band_rd_dvld : ixf_dvld_w;
    wire [15:0] band_data_mux = SIM_ABSTRACT ? band_rd_data : ixf_data_w;
    reg         fetch_reload_r;
    // 取带重载触发 = 渲染器帧启动事件（band.frame_start，两条路径）：
    //   a) IDLE 收 swap_done 立即开帧；b) 帧尾 ack 后接挂起帧。
    //   ★ 此拍 band 已锁存新 base_l（旧 frame_done 触发点早于接帧拍，锁到旧窗
    //   基址 → 渲染帧 N 读窗 N-1 数据撕裂——实测帧 1 带 0 读到帧 0 数据）。
    always @(posedge clk100 or negedge rst_n)
        if (!rst_n) begin
            fetch_reload_r <= 1'b0;
        end else begin
            fetch_reload_r <= SIM_ABSTRACT ? 1'b0 : u_band.frame_start;
        end
    // 抽象索引口（仅模式 1 对外呈现）
    assign ix_wr_valid = SIM_ABSTRACT ? wr_valid_w : 1'b0;
    assign ix_wr_addr  = SIM_ABSTRACT ? wr_addr_w  : {AW{1'b0}};
    assign ix_wr_data  = SIM_ABSTRACT ? wr_data_w  : 16'd0;
    assign band_rd_req = band_rd_req_w;   // 两模式均为 band 输出
    wire        band_rd_req_unused = band_rd_req;

    yx_vp_ixdec #(.W(W), .H(H), .CBSIZE(CBSIZE)) u_ixdec (
        .clk(clk100), .rst_n(rst_n),
        .stream_valid(dec_v), .stream_data(dec_d), .stream_ready(dec_rdy_w),
        .ix_we(ix_we), .ix_blk(ix_blk), .ix_idx(ix_idx), .ix_rdy(ix_rdy_w),
        .frame_done(dec_fdone), .frame_key(), .frame_no(),
        .frame_started(dec_fstart), .frame_kind(dec_fkind)
    );

    // ixbuf 契约：rendered_no = 渲染器"最后完成"帧号（其变更沿释放 busy[dst]）。
    // band 在"帧最后一带完成"拍发 frame_done，此刻 render_no 仍是刚完成的帧号
    // （下一帧尚未锁存）——必须在此拍锁存，不能等到 ack（那时 render_no 已推进）。
    reg [15:0] rno_done;
    always @(posedge clk100 or negedge rst_n) begin
        if (!rst_n) rno_done <= 16'hffff;
        else if (frame_done_vq) rno_done <= u_band.render_no;
    end

    yx_vp_ixbuf #(.NB(NB), .AW(AW)) u_ixbuf (
        .clk(clk100), .rst_n(rst_n),
        .ix_we(ix_we), .ix_blk(ix_blk), .ix_idx(ix_idx), .ix_rdy(ix_rdy_w),
        .frame_done(dec_fdone), .frame_started(dec_fstart), .frame_kind(dec_fkind),
        .wr_valid(wr_valid_w), .wr_addr(wr_addr_w), .wr_data(wr_data_w),
        .wr_gnt(SIM_ABSTRACT ? 1'b1 : ixwr_gnt_w),
        // cp 读口：模式 1 → 顶层输入口（TB 随机口模型）；模式 0 → fetch v5
        // 经 RD2 分时供给。cp_rd/cp_addr 保持直驱顶层观测口（fetch 引同一 net）。
        .cp_rd(cp_rd), .cp_addr(cp_addr),
        .cp_dvld(SIM_ABSTRACT ? cp_dvld : cp_dvld_ixf_w),
        .cp_data(SIM_ABSTRACT ? cp_data : cp_data_ixf_w),
        .swap_done(swap_done_w), .commit_no(commit_no), .act_base(act_base),
        .rendered_no(rno_done)
    );

    // ================= 条带渲染器 =================
    wire        band_done_w;
    wire [8:0]  band_no_w;
    wire [13:0] scan_ra_w, scan_rb_w;
    wire [15:0] scan_rd_w, scan_rd_b_w;
    wire        band_fs_w;     // band 帧启动脉冲（fetch reload 触发源）

    yx_vp_band #(.W(W), .H(H), .CBSIZE(CBSIZE), .AW(AW)) u_band (
        .clk(clk100), .rst_n(rst_n),
        .swap_done(swap_done_w), .commit_no(commit_no), .act_base(act_base),
        .rd_req(band_rd_req_w), .rd_addr(band_rd_addr),
        .rd_dvld(band_dvld_mux), .rd_data(band_data_mux),
        .scan_ra(scan_ra_w), .scan_rd(scan_rd_w),
        .scan_rb(scan_rb_w), .scan_rd_b(scan_rd_b_w),
        .book_we(SIM_ABSTRACT ? 1'b0 : hdr_book_we),
        .book_wa(SIM_ABSTRACT ? 14'd0 : hdr_book_wa),
        .book_wd(SIM_ABSTRACT ? 16'd0 : hdr_book_wd),
        .band_done(band_done_w), .render_no(rendered_no), .band_no(band_no_w),
        .band_ack(scan_ack), .frame_done(frame_done_vq), .frame_start(band_fs_w)
    );
    assign band_pend_cnt = u_band.pend_cnt;

    // ================= 体系模式：头解析 + 索引写/取带适配 =================
    generate if (!SIM_ABSTRACT) begin : REAL_IX

    yx_b_hdr_parse #(.W(W), .H(H), .CBSIZE(CBSIZE)) u_hdr (
        .clk(clk100), .rst_n(rst_n),
        .in_valid(stream_valid), .in_data(stream_data), .in_ready(stream_ready),
        .out_valid(hdr_v), .out_data(hdr_d), .out_ready(dec_rdy_w),
        .book_we(hdr_book_we), .book_wa(hdr_book_wa), .book_wd(hdr_book_wd),
        .hdr_ok(hdr_ok_w), .hdr_err(hdr_err_w)
    );

    yx_b_ix_seq_wr #(.AW(AW), .NB(NB)) u_ixwr (
        .clk(clk100), .rst_n(rst_n),
        .wr_valid(wr_valid_w), .wr_addr(wr_addr_w), .wr_data(wr_data_w),
        .wr_gnt(ixwr_gnt_w),
        .wr2_data(wr2_data_w), .wr2_en(wr2_en_w), .wr2_addr(wr2_addr_w),
            .wr2_load(wr2_load_w), .wr2_full(wr2_full_w),
            .wr2_done(wr2_done_w),
            .region_done(ixwr_rdone_w)
    );

    yx_b_ix_fetch #(.AW(AW), .NB(NB)) u_ixfetch (
        .clk(clk100), .rst_n(rst_n),
        .rd_req(band_rd_req_w), .rd_dvld(ixf_dvld_w), .rd_data(ixf_data_w),
        .cp_req(cp_rd), .cp_addr(cp_addr),
            .cp_dvld(cp_dvld_ixf_w), .cp_data(cp_data_ixf_w),
        .rd2_fifo_dat(rd2_dat_w), .rd2_empty(rd2_empty_w),
        .rd2_re(ixf_re_w), .rd2_addr(ixf_addr_w), .rd2_load(ixf_load_w),
        .rd2_we(rd2_we_w), .rd2_bmask1(rd2_bmask1_w),
        .reload(fetch_reload_r), .reload_base(u_band.base_l),
        .region_done(ixwr_rdone_w)
    );

    end endgenerate

    // ================= 扫描写端 v3（vendor 原生：每带一次 LOAD，流式灌满一带）=================
    // 每带一次 LOAD（ADDR=带基址、LENGTH=256、MAX_ADDR=带基址+FB_WB），控制器
    // 自动按 256 字突发步进、越过 MAX_ADDR 回卷到带基址；写端以 1 字/拍流式灌
    // 2560 字。★ 带完成后等 WR1 FIFO 全部落 SDRAM（rp 影子差分计数）再报
    // scan_done——TB 在 scan_done 拍直读 SDRAM mem 比对，早报会把 FIFO 尾字
    // 读成 X/旧值（带尾 2184..2560 大片 X 的根因）。旧 600 拍固定 DRAIN 由
    // 排空等待取代（精确且更快）。
    reg        sc_busy, sc_pend_v;
    reg [8:0]  sc_cur, sc_pend;
    reg        sc_win, sc_pend_win; // ★ P3：带所属帧的写窗号（band_done 拍锁 render_no[0]）
    reg [11:0] sc_push;          // 带内已推字数 0..2560
    reg [2:0]  sc_st;            // 0=IDLE 1=LOAD 2=PUSH 3=FLUSH 4=DONE(裕量)
    reg [13:0] sc_ra;            // 行缓冲读地址（偶像素；组合读=本拍地址本拍数据）
    reg [31:0] sc_wdata;
    reg        wr1_load, wr1_en;
    reg [20:0] wr1_addr;
    reg [15:0] sc_drain;         // ★ 末突发写完裕量拍计数（256）

    // WR1 FIFO 排空判据：rp 指针影子差分计数（pop 事件每拍 ≤1，mod 1024 减法
    // 天然处理回绕；TB 同款层次路径 u_sdram.write_fifo1.logic_fifo.rp_bin）
    reg [9:0]  wr1_rp_q;
    reg [12:0] wr1_popd;         // 带内已落 SDRAM 字数（0..2560）
    wire [9:0] wr1_rp_now = u_sdram.write_fifo1.logic_fifo.SAMEDOM.rp_bin;
    wire [9:0] wr1_rp_d   = wr1_rp_now - wr1_rp_q;

    wire [13:0] sc_half_ofs = sc_cur[0] ? PIX_BAND[13:0] : 14'd0;
    wire        wr1_full_w;                 // ★ WR1 FIFO 背压：满时暂停推数（防 shim 丢字）
    // ★ P3 写窗基址：帧窗 k%2（帧 k = render_no k；窗 k%2 与索引窗同号交替）
    wire [20:0] sc_win_base = sc_win ? (FB_BASE[20:0] + FB_TOTAL[20:0]) : FB_BASE[20:0];

    always @(posedge clk100 or negedge rst_n) begin
        if (!rst_n) begin
            sc_busy<=1'b0; sc_pend_v<=1'b0; sc_pend<=9'd0; sc_cur<=9'd0;
            sc_win<=1'b0; sc_pend_win<=1'b0;
            sc_push<=12'd0; sc_st<=3'd0;
            sc_ra<=14'd0; sc_wdata<=32'd0;
            wr1_load<=1'b0; wr1_en<=1'b0; wr1_addr<=21'd0; sc_drain<=16'd0;
            scan_done<=1'b0; scan_band_no<=9'd0; scan_ack<=1'b0;
            wr1_rp_q<=10'd0; wr1_popd<=13'd0;
        end else begin
            scan_done <= 1'b0;
            scan_ack  <= 1'b0;
            wr1_load  <= 1'b0;
            wr1_en    <= 1'b0;

            // WR1 FIFO pop 影子计数（每带 LOAD 拍清零）
            wr1_rp_q  <= wr1_rp_now;
            wr1_popd  <= wr1_popd + {4'd0, wr1_rp_d};

            // 新带到达：空闲即开扫，否则挂起（扫描恒快于渲染，1 级挂起足够）
            // ★ P3：band_done 拍锁 render_no[0]（带所属帧 → 写窗）；闸门扣住
            //   发往"显示正读窗"的写（band 已锁存，LOAD 推迟至显示换走）
            if (band_done_w) begin
                if (!sc_busy) begin
                    sc_cur  <= band_no_w; sc_busy <= 1'b1;
                    sc_win  <= u_band.render_no[0];
                    sc_push <= 12'd0;
                    sc_st   <= win_free_w ? 3'd1 : 3'd0;
                end else if (!sc_pend_v) begin
                    sc_pend     <= band_no_w; sc_pend_v <= 1'b1;
                    sc_pend_win <= u_band.render_no[0];
                end
            end

            case (sc_st)
            3'd0: if (sc_busy && win_free_w) sc_st <= 3'd1;
            3'd1: begin // LOAD 本带基址（一次；地址自动步进，窗尾不回卷——MAX=全域）
                wr1_addr  <= sc_win_base + sc_cur * FB_WB;
                wr1_load  <= 1'b1;
                sc_ra     <= sc_half_ofs;
                sc_push   <= 12'd0;
                wr1_popd  <= 13'd0;
                sc_st     <= 3'd2;
            end
            3'd2: begin // 流式推 2560 字（1 字/拍；行缓冲组合读=本拍地址本拍数据）
                if (!wr1_full_w) begin
                    // ★ 无 wr2_aempty_w 门控：WR1 推数与 WR2 FIFO 占用无关；
                    //   WR1 背压由 wr1_full_w 承担（停推时 sc_ra 冻结、恢复无重复）
                    wr1_en   <= 1'b1;
                    sc_wdata <= {scan_rd_b_w, scan_rd_w};
                    sc_push  <= sc_push + 12'd1;
                    sc_ra    <= sc_ra + 14'd2;
                    if (sc_push == FB_WB - 1) sc_st <= 3'd3;
                end
            end
            3'd3: begin // FLUSH：等 2560 字全部落 SDRAM（rp 影子计数）
                if (wr1_popd >= FB_WB[12:0]) begin
                    sc_drain <= 16'd256;      // 末突发写完裕量
                    sc_st    <= 3'd4;
                end
            end
            3'd4: begin
                sc_drain <= sc_drain - 16'd1;
                if (sc_drain == 16'd1) begin
                    // 整带完成（已落 SDRAM）：ack 渲染器（半区释放）+ 上报 + 接挂起带
                    scan_done    <= 1'b1;
                    scan_ack     <= 1'b1;
                    scan_band_no <= sc_cur;
                    sc_busy      <= 1'b0;
                    sc_st        <= 3'd0;
                    if (sc_pend_v) begin
                        sc_cur      <= sc_pend;
                        sc_win      <= sc_pend_win;   // ★ 挂起带的写窗随行
                        sc_pend_v   <= 1'b0;
                        sc_busy     <= 1'b1;
                        sc_st       <= win_free_w ? 3'd1 : 3'd0;
                    end
                end
            end
            default: sc_st <= 3'd0;
            endcase
        end
    end

    // ================= HDMI 扫出（P3：双窗 + 73.33M 像素域）=================
    // 帧窗：渲染帧 k 写帧窗 k%2（写端 §扫描写端窗选择），显示读"最后完成窗"
    // ——写读窗恒异（撕裂免疫）。显示每帧恰好消耗一整窗（720×640=FB_TOTAL），
    // vblank LOAD 既重置读指针又换窗，MAX 恒 0x1FFFFF（回卷不依赖 rRD_MAX
    // 复位锁存——YX4 教训）。设计：docs/YX_BBOARD_P3_DISPLAY_20261121.md。
    wire        pixel_clk_w, serial_clk_w, pll_lock_w;
    pll_hdmi1_4b u_hdmi_pll (
        .refclk   (ref_clk),
        .reset    (1'b0),
        .extlock  (pll_lock_w),
        .clk1_out (pixel_clk_w),        // 73.33M 像素时钟
        .clk2_out (serial_clk_w)        // 366.67M 串行时钟（TD 加密核用）
    );
    // 像素域复位（高有效）：rst_n 低 + PLL 未锁，双拍同步
    reg [1:0] prst_ff;
    reg [1:0] plock_ff = 2'b00;
    always @(posedge pixel_clk_w or negedge rst_n)
        if (!rst_n) prst_ff <= 2'b11;
        else        prst_ff <= {prst_ff[0], 1'b0};
    always @(posedge pixel_clk_w) plock_ff <= {plock_ff[0], pll_lock_w};
    wire pixel_rst_w = prst_ff[1] | !plock_ff[1];
    assign dbg_pixel_clk = pixel_clk_w;

    // 窗完成跟踪（100M 域）：帧尾 band 179 scan_done ⇒ 该帧窗可显示
    reg win_show_req_w;
    reg first_win_done_w;
    always @(posedge clk100 or negedge rst_n)
        if (!rst_n) begin
            win_show_req_w   <= 1'b0;
            first_win_done_w <= 1'b0;
        end else if (scan_done && (scan_band_no == BH - 1)) begin
            win_show_req_w   <= sc_win;         // 刚完成的帧所在窗
            first_win_done_w <= 1'b1;
        end

    // ★ 写窗闸门（原 P3 方案"渲染器开新帧前若目标窗正被读则等待"）：显示以
    //   59.3fps 换窗，渲染更快时会对显示正读的窗发起写入（超越一圈）→ 撕裂。
    //   闸门 = 目标窗 == 显示窗 时扣住扫描写（band 已锁存、LOAD 推迟）——渲染
    //   器 pend 满 → 取带停 → ix_rdy 背压 → 码流停，全管线安全暂停；显示下一
    //   个 vblank 按 win_show_req 换走即放行。首窗完成前不设闸（显示未启动）。
    reg [1:0] wsh_sync;
    always @(posedge clk100 or negedge rst_n)
        if (!rst_n) wsh_sync <= 2'b00;
        else        wsh_sync <= {wsh_sync[0], win_show};
    wire win_show_100 = wsh_sync[1];
    wire win_free_w   = !first_win_done_w || (sc_win != win_show_100);

    // 扫出（时序+取数+AXIS；EMIT_HDMI=1 时 AXIS 入加密核）
    wire        rd1_en_w, rd1_load_w, rd1_empty_w, rd1_we_w, rd1_bmask0_w;
    wire [20:0] rd1_addr_w;
    wire [8:0]  rd1_len_w;
    wire [31:0] rd1_data_w;
    wire        video_ready_w;
    assign rd1_we_w      = u_sdram.OUT_VALID & u_sdram.RD_MASK[0];
    assign rd1_bmask0_w  = u_sdram.RD_MASK[0];
    yx_b_scanout #(
        .FB_WIN0  (FB_BASE[20:0]),
        .FB_TOTAL (FB_TOTAL[20:0])
    ) u_scanout (
        .rst_n          (rst_n),
        .win_show_req   (win_show_req_w),
        .first_win_done (first_win_done_w),
        .pixel_clk      (pixel_clk_w),
        .pixel_rst      (pixel_rst_w),
        .rd1_addr       (rd1_addr_w),
        .rd1_load       (rd1_load_w),
        .rd1_len        (rd1_len_w),
        .rd1_en         (rd1_en_w),
        .rd1_data       (rd1_data_w),
        .rd1_empty      (rd1_empty_w),
        .rd1_we         (rd1_we_w),
        .rd1_bmask0     (rd1_bmask0_w),
        .rd1_clk        (pixel_clk_w),
        .video_user     (video_user),
        .video_valid    (video_valid),
        .video_last     (video_last),
        .video_data     (video_data),
        .video_ready    (video_ready_w),
        .disp_pass      (disp_pass),
        .win_show       (win_show),
        .disp_stall     (disp_stall)
    );
`ifdef EMIT_HDMI
    // TD 构建：AXIS → 加密核 → PHY（iverilog 不编 .enc，仿真构建无此块）。
    // TMDS 引脚端口随 P5 引脚表一并加入（现接内部 wire）。
    wire core_ready_w, video_locked_w;
    wire [9:0] tmds_ch0_w, tmds_ch1_w, tmds_ch2_w, tmds_clk_w;
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE               ("EG"),
        .HTOTAL               (1650),
        .HSA                  (40),
        .HFP                  (110),
        .HBP                  (220),
        .HACTIVE              (1280),
        .VTOTAL               (750),
        .VSA                  (5),
        .VFP                  (5),
        .VBP                  (20),
        .VACTIVE              (720),
        .VIDEO_VIC            (69),
        .VIDEO_TPG            ("Disable"),
        .VIDEO_FORMAT         ("RGB"),
        .AUDIO_SAMPLE_RATE    ("48K"),
        .IIC_SCL_DIV          (125)
    ) u_hdmi_core (
        .I_pixel_clk        (pixel_clk_w),
        .I_rst              (pixel_rst_w),
        .I_edid_read_trig   (1'b0),          // 观察项：不触发 EDID 读取
        .O_edid_read_valid  (),
        .O_edid_read_data   (),
        .I_axis_s_user      (video_user),
        .I_axis_s_valid     (video_valid),
        .I_axis_s_last      (video_last),
        .I_axis_s_data      (video_data),
        .O_axis_s_ready     (core_ready_w),
        .I_audio_valid      (1'b0),          // mute
        .I_audio_left_data  (24'd0),
        .I_audio_right_data (24'd0),
        .I_acr_valid        (1'b0),          // mute 无 ACR
        .I_acr_cts          (20'd0),
        .I_acr_n            (20'd0),
        .O_video_locked     (video_locked_w),
        .O_ch0_tmds_data    (tmds_ch0_w),
        .O_ch1_tmds_data    (tmds_ch1_w),
        .O_ch2_tmds_data    (tmds_ch2_w),
        .O_clk_tmds_data    (tmds_clk_w)
    );
    hdmi_phy_wrapper u_hdmi_phy (
        .I_pixel_clk   (pixel_clk_w),
        .I_serial_clk  (serial_clk_w),
        .I_rst         (pixel_rst_w),
        .I_tmds_channel_0   (tmds_ch0_w),
        .I_tmds_channel_1   (tmds_ch1_w),
        .I_tmds_channel_2   (tmds_ch2_w),
        .I_tmds_channel_clk (tmds_clk_w),
        .O_tmds_ch0_p       (tmds_ch0_p_w),
        .O_tmds_ch1_p       (tmds_ch1_p_w),
        .O_tmds_ch2_p       (tmds_ch2_p_w),
        .O_tmds_clk_p       (tmds_clk_p_w)
    );
    assign video_ready_w = core_ready_w;
`else
    assign video_ready_w = 1'b1;    // 仿真：ready 仅 informational（A 板语义）
`endif

    // ================= vendor SDRAM 控制器 + 硬宏 =================
    Sdram_Control_4Port u_sdram (
        .REF_CLK(ref_clk), .RESET_N(rst_n), .CLK(clk100),
        .WR1_DATA(sc_wdata), .WR1(wr1_en), .WR1_ADDR(wr1_addr),
        // ★ P3：MAX 恒全域（双窗下 rWR1_MAX 复位锁存无法跟随窗切换——回卷
        //   由每带 LOAD 承担，窗尾溢出走 LOAD 纠偏，同 fetch v4 哲学）
        .WR1_MAX_ADDR(21'h1FFFFF), .WR1_LENGTH(9'd256), .WR1_LOAD(wr1_load),
        .WR1_CLK(clk100), .WR1_FULL(wr1_full_w), .WR1_USE(),
        .WR2_DATA(wr2_data_u), .WR2(wr2_en_u), .WR2_ADDR(wr2_addr_u),
        .WR2_MAX_ADDR(21'h1FFFFF), .WR2_LENGTH(wr2_len_u), .WR2_LOAD(wr2_load_u),
        .WR2_CLK(clk100), .WR2_FULL(wr2_full_w), .WR2_USE(),
        .RD1_DATA(rd1_data_w), .RD1(rd1_en_w), .RD1_ADDR(rd1_addr_w),
        .RD1_MAX_ADDR(21'h1FFFFF), .RD1_LENGTH(rd1_len_w), .RD1_LOAD(rd1_load_w),
        .RD1_CLK(pixel_clk_w), .RD1_EMPTY(rd1_empty_w), .RD1_USE(),
        .RD2_DATA(rd2_dat_w), .RD2(rd2_re_u), .RD2_ADDR(rd2_addr_u),
        .RD2_MAX_ADDR(rd2_max_u), .RD2_LENGTH(rd2_len_u), .RD2_LOAD(rd2_load_u),
        .RD2_CLK(clk100), .RD2_EMPTY(rd2_empty_w), .RD2_USE(),
        .SA(DRAM_ADDR), .BA(DRAM_BA), .CS_N(DRAM_CS_N), .CKE(DRAM_CKE),
        .RAS_N(DRAM_RAS_N), .CAS_N(DRAM_CAS_N), .WE_N(DRAM_WE_N),
        .DQ(DRAM_DQ), .DQM(DRAM_DQM), .SDR_CLK(DRAM_CLK),
        .test_oe()
    );

    sdram_ip u_dram (
        .clk(DRAM_CLK), .ras_n(DRAM_RAS_N), .cas_n(DRAM_CAS_N), .we_n(DRAM_WE_N),
        .addr(DRAM_ADDR), .ba(DRAM_BA), .dq(DRAM_DQ), .cs_n(DRAM_CS_N[0]),
        .dm0(DRAM_DQM[0]), .dm1(DRAM_DQM[1]), .dm2(DRAM_DQM[2]), .dm3(DRAM_DQM[3]),
        .cke(DRAM_CKE)
    );

endmodule
