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
// 扫描读单口（scan_ra）：行缓冲内部为 32bit 打包字，同步读出 → WR1 推数 1 字/拍
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
    parameter SIM_ABSTRACT = 1,
    // ---- 以太网入口（-DUSE_ETH 编译宏门控；见下）----
    // 板级码流来源：RGMII PHY（AC601+AC201 与 A 板同构）。默认 0 = 由 stream_* 口
    // 外部驱动（P4 验收基线）；TD 板级构建用 -DUSE_ETH 打开内部 yx_b_eth_rx。
    parameter [47:0] LOCAL_MAC  = 48'h00_0a_35_02_00_01,
    parameter [31:0] LOCAL_IP   = 32'hc0_a8_00_64,     // 192.168.0.100
    parameter [15:0] LOCAL_PORT = 16'd5000,
    // ---- 状态指示灯极性 ----
    // B 板 4 个用户 LED（AC201：LED0..3 = M12/R16/R15/T15）在原理图上未标注驱动
    // 极性（引脚直驱 or 经三极管），无法从 RTL 侧判定。默认"驱动 1 = 点亮"；
    // 若上板发现全反（例如心跳灯常亮不闪），把本参数置 1 即可整体反转。
    parameter LED_ACTIVE_LOW = 1'b0
)(
    input  wire        ref_clk,        // 50M 晶振（控制器内部 PLL 生成 100M）
    input  wire        rst_n,

    // ---- A→B 字节流 ----
    input  wire        stream_valid,
    input  wire [7:0]  stream_data,
    output wire        stream_ready,

    // ---- 以太网 PHY（RGMII；-DUSE_ETH 时使用，否则常数驱动/忽略）----
    // ★ 只收不发：TX 需要 125M TX 时钟源（本板无），eth_gtxc/txd/txen 不引出。
    input  wire        eth_rxc,
    input  wire [3:0]  eth_rxd,
    input  wire        eth_rxdv,
    output wire        eth_rst_n,      // PHY 复位（低有效，跟随板级复位）
    output wire        eth_mdc,        // Clause 22 MDIO 时钟（yx_b_mdio 驱动）
    inout  wire        eth_mdio,       // Clause 22 MDIO 数据（三态；板上 PULLUP）

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

    // ---- 板级状态指示灯（B 板 4 个用户 LED；P5 板级可观测性）----
    //   位定义见下方 LED 逻辑处。极性由参数 LED_ACTIVE_LOW 控制。
    output wire [3:0]  o_led,

    // ---- HDMI TMDS/DDC 输出（P5；引脚号待 AC601 引脚表，见 timing_b.sdc）----
    //   EMIT_HDMI=0（仿真）：TMDS 恒 0、DDC_SCL 恒 0、DDC_SDA 高阻。
    //   EMIT_HDMI=1（TD）  ：AXIS → 加密核 → hdmi_phy_wrapper → 本组端口。
    output wire        tmds_ch0_p,
    output wire        tmds_ch1_p,
    output wire        tmds_ch2_p,
    output wire        tmds_clk_p,
    output wire        tmds_ddc_scl,    // 观察项：当前 I_edid_read_trig 恒 0，不发起读
    inout  wire        tmds_ddc_sda,

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
    wire        dec_rdy_w;
    wire        dec_v = SIM_ABSTRACT ? stream_valid : hdr_v;
    wire [7:0]  dec_d = SIM_ABSTRACT ? stream_data  : hdr_d;
`ifdef USE_ETH
    // 板级：码流来自以太网，A→B 字节流端口不参与（保持 0，避免悬空）
    assign stream_ready = 1'b0;
`else
    assign stream_ready = SIM_ABSTRACT ? dec_rdy_w : hdr_rdy;
`endif

    // ---- PHY 控制（两种构建一致）----
    // 复位跟随板级复位（低有效）。
    // ★ P5：PHY = RTL8211F-CG（U14）。其 RGMII RX 内部延时 strap = RXD0，本板被
    //   4.7K 上拉到 ETH_DVDDH；若该 strap 语义为"使能"，PHY 会给 RXC 再加 ~2ns，
    //   采样点 T+5.705ns 落到 4ns 数据眼（[T+1.075, T+5.075]）之外。上电后用
    //   MDIO 把扩展页 0xd08 / 寄存器 0x15 的 bit3 清掉（详见 yx_b_phy_init.v 与
    //   docs/YX_BBOARD_P5_PHY1_20261124.md §3）。
    // ★ MDIO 时钟域 = clk100（来自 Sdram_PLL，只依赖板载 50M 晶振）——**不依赖
    //   PHY 的 RXC**，即使 PHY 上电后 RXC 未就绪也能完成配置。
    assign eth_rst_n = rst_n;

    wire        mdio_req_w, mdio_wr_w, mdio_done_w, mdio_busy_w;
    wire [4:0]  mdio_rega_w;
    wire [15:0] mdio_wdata_w, mdio_rdata_w;
    wire        mdio_oe_w, mdio_o_w;
    wire [15:0] phy_rxcr_w;          // 读回的 RXCR 原值（0xffff = PHY 未响应）
    wire        phy_cfg_done_w, phy_cfg_skip_w;

    yx_b_mdio #(.PHY_ADDR(5'd1), .HALF_DIV(8'd20)) u_mdio (
        .clk(clk100), .rst_n(rst_n),
        .req(mdio_req_w), .wr(mdio_wr_w), .reg_a(mdio_rega_w), .wdata(mdio_wdata_w),
        .rdata(mdio_rdata_w), .done(mdio_done_w), .busy(mdio_busy_w),
        .mdc(eth_mdc), .mdio_oe(mdio_oe_w), .mdio_o(mdio_o_w), .mdio_i(eth_mdio)
    );

    // PHY_INIT_WAIT = 100ms @100MHz：复位释放后等 PHY 内部初始化完成再发 MDIO。
    //   （RTL8211F 复位脚要求 ≥10ms，之后还需内部 PLL/自协商初始化时间；本设计
    //     的视频通路不依赖该配置，等久一点无代价。）
    yx_b_phy_init #(
        .PHY_ADDR(5'd1), .PHY_INIT_WAIT(24'd10_000_000)
    ) u_phyinit (
        .clk(clk100), .rst_n(rst_n),
        .req(mdio_req_w), .wr(mdio_wr_w), .reg_a(mdio_rega_w), .wdata(mdio_wdata_w),
        .rdata(mdio_rdata_w), .done(mdio_done_w), .busy(mdio_busy_w),
        .rxcr_r(phy_rxcr_w), .cfg_done(phy_cfg_done_w), .cfg_skip(phy_cfg_skip_w)
    );

    // MDIO 三态：oe=0 时释放总线（板上 PULLUP 拉高；读操作的 TA/数据相位由 PHY 驱动）
    assign eth_mdio = mdio_oe_w ? mdio_o_w : 1'bz;

    // ================= 板级状态指示灯（4 个用户 LED）=================
    // 为什么需要它：B 板此前是"哑板"——上板后若收不到包，无法区分
    // "PHY 没起来 / MDIO 序列没生效 / RGMII 时序不对 / 码流没到"。
    // 这 4 盏灯把最关键的四个事实直接摆出来：
    //   led[0] = phy_cfg_done    MDIO 配置序列已跑完
    //   led[1] = phy_cfg_skip    仅当 PHY 无响应（读回 0xffff）时置 1。
    //                           注意没有"无需改"路径：序列无条件清 bit3，
    //                           原本为 0 时也走完整写流程，cfg_skip 仍为 0。
    //   led[2] = phy_rxcr_w[3]  **清除前**的 RXCR bit3 —— 即 RGMII RX 延时使能位，
    //                           把"strap 到底使能还是关闭"从推断变成实测。
    //                           ⚠ cfg_skip=1 时该位恒为 1（0xffff 的 bit3），
    //                             属假阳性 —— 判读时先看 led[1]。
    //   led[3] = 心跳            clk100 分频（~1.5Hz），证明时钟/配置在跑
    // 极性：参数 LED_ACTIVE_LOW（默认 0 = 驱动 1 点亮）。
    // ★ 位宽必须 ≥25：33,000,000 > 2^24−1 = 16,777,215。初版写成 [23:0] 时
    //   24'd33_000_000 被 iverilog/TD **静默截断**成 16,222,784，心跳变 ~3.08Hz
    //   （iverilog 只给一句 "Numeric constant truncated"，不挡编译，容易漏）。
    localparam [24:0] LED_HB_DIV = 25'd33_000_000;   // 100MHz → 每 0.33s 翻转 → 1.5Hz 周期
    reg [24:0] led_hb_cnt;
    reg        led_hb;
    always @(posedge clk100 or negedge rst_n) begin
        if (!rst_n) begin
            led_hb_cnt <= 25'd0;
            led_hb     <= 1'b0;
        end else if (led_hb_cnt == LED_HB_DIV - 25'd1) begin
            led_hb_cnt <= 25'd0;
            led_hb     <= ~led_hb;
        end else begin
            led_hb_cnt <= led_hb_cnt + 25'd1;
        end
    end

    wire [3:0] led_raw = {led_hb, phy_rxcr_w[3], phy_cfg_skip_w, phy_cfg_done_w};
    assign o_led = LED_ACTIVE_LOW ? ~led_raw : led_raw;
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
    // ★ P5：控制器状态经 Sdram_Control_4Port_B 的 st_* 端口引出（原为层次引用，
    //   TD 不可综合）。st_wr_done/st_wr_mask/st_in_req/st_out_valid 均为控制器
    //   CLK(=clk100) 域信号，与使用它们的逻辑同域。
    wire        wr2_done_w    = st_wr_done_w & st_wr_mask_w[1];
    wire [1:0]  ixwr_rdone_w;    // seq_wr 按窗完成标志 → fetch 屏障门
    wire        wr2_busy_w  = (st_wr_mask_w != 2'b00) || (st_wr_w != 1'b0);
    wire        rd2_empty_w;
    wire [31:0] rd2_dat_w;
    wire        rd2_we_w      = st_out_valid_w & st_rd_mask_w[1];
    wire        rd2_bmask1_w  = st_rd_mask_w[1];
    wire        wr2_re_w      = st_in_req_w & st_wr_mask_w[1];
    // ★ cp 读口体系模式供给线：fetch v5 经 RD2 分时服务 ixbuf 拷贝读（板上契约
    //   闭环——板上无顶层随机口，cp 读 = RD2 顺序流的一段分时复用）。模式 1 仍
    //   走顶层输入口（TB 随机口模型）。cp_rd/cp_addr 为 ixbuf 输出，两模式均
    //   驱动顶层观测口，fetch 直接引同一线网作请求源。
    wire        cp_dvld_ixf_w;
    wire [15:0] cp_data_ixf_w;
    wire          wr_valid_w, swap_done_w;
    wire [AW-1:0] wr_addr_w, act_base;             // ixbuf 当前 active 区基址（= SDRAM 字地址）
    wire [15:0]   wr_data_w;
    wire [20:0] rd2_max_w   = band_base_w + NB[20:0];   // 取带窗 = 渲染器锁存基址
    wire        band_rd_req_w;   // band 的取带请求（两种模式都在内部）
    // ★ 行缓冲扫描读地址（悬空修复）：sc_ra 是扫描写端自己的地址计数。
    //   命名保留"偶像素地址"语义（线性像素地址，步长 2），但行缓冲内部已是
    //   32bit 打包字 —— band 侧取 scan_ra[13:1] 作字地址，单口同步读出
    //   {奇,偶} 打包字（P5-P0：单读口才能映射 BRAM）。
    reg  [13:0] sc_ra;            // 行缓冲读地址（线性像素地址，偶像素起步，步长 2）
    wire [13:0] scan_ra_w;
    assign scan_ra_w = sc_ra;
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
            fetch_reload_r <= SIM_ABSTRACT ? 1'b0 : band_fs_w;
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
        else if (frame_done_vq) rno_done <= rendered_no;
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
    wire [31:0] scan_rd32_w;   // 行缓冲打包字 {奇像素, 偶像素}（同步读，1 拍延迟）
    wire        band_fs_w;     // band 帧启动脉冲（fetch reload 触发源）
    wire [AW-1:0] band_base_w;   // band 本帧索引基址（= 原 u_band.base_l）
    wire [1:0]  band_pend_cnt_w; // band 已渲染未 ack 带数（= 原 u_band.pend_cnt）

    yx_vp_band #(.W(W), .H(H), .CBSIZE(CBSIZE), .AW(AW)) u_band (
        .clk(clk100), .rst_n(rst_n),
        .swap_done(swap_done_w), .commit_no(commit_no), .act_base(act_base),
        .rd_req(band_rd_req_w), .rd_addr(band_rd_addr),
        .rd_dvld(band_dvld_mux), .rd_data(band_data_mux),
        .scan_ra(scan_ra_w), .scan_rd32(scan_rd32_w),
        .book_we(SIM_ABSTRACT ? 1'b0 : hdr_book_we),
        .book_wa(SIM_ABSTRACT ? 14'd0 : hdr_book_wa),
        .book_wd(SIM_ABSTRACT ? 16'd0 : hdr_book_wd),
        .band_done(band_done_w), .render_no(rendered_no), .band_no(band_no_w),
        .band_ack(scan_ack), .frame_done(frame_done_vq), .frame_start(band_fs_w),
        // P5：原先用层次引用读的两个内部状态，现在走显式端口
        .frame_base(band_base_w), .pend_cnt_o(band_pend_cnt_w)
    );
    assign band_pend_cnt = band_pend_cnt_w;

    // ================= 体系模式：头解析 + 索引写/取带适配 =================
    generate if (!SIM_ABSTRACT) begin : REAL_IX

`ifdef USE_ETH
    // ---- 板级以太网入口（RGMII 接收）→ hdr_parse 字节流 ----
    // 只收不发：PHY 的 gtxc/txd/txen 需要 125M TX 时钟（本板无该时钟源），
    // 不接入；以太网 bring-up（MDIO 配置/RXC delay）见 P5 文档。
    wire        eth_sv;
    wire [7:0]  eth_sd;
    wire        eth_rdy;
    yx_b_eth_rx #(
        .USE_RGMII (1),
        .FIFO_AW   (14)
    ) u_ethrx (
        .clk100       (clk100),
        .rst_n        (rst_n),
        .local_mac    (LOCAL_MAC),
        .local_ip     (LOCAL_IP),
        .local_port   (LOCAL_PORT),
        .gmii_rx_clk  (1'b0),
        .gmii_rxd     (8'd0),
        .gmii_rxdv    (1'b0),
        .rgmii_rx_clk (eth_rxc),
        .rgmii_rxd    (eth_rxd),
        .rgmii_rxdv   (eth_rxdv),
        .stream_valid (eth_sv),
        .stream_data  (eth_sd),
        .stream_ready (eth_rdy),
        .pkt_ok_cnt   (),
        .pkt_drop_cnt (),
        .byte_cnt     (),
        .fifo_room    (),
        .rx_clk125    ()
    );
`endif

    yx_b_hdr_parse #(.W(W), .H(H), .CBSIZE(CBSIZE)) u_hdr (
        .clk(clk100), .rst_n(rst_n),
`ifdef USE_ETH
        .in_valid(eth_sv), .in_data(eth_sd), .in_ready(eth_rdy),
`else
        .in_valid(stream_valid), .in_data(stream_data), .in_ready(stream_ready),
`endif
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
        .reload(fetch_reload_r), .reload_base(band_base_w),
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
    // ★ P5-P0b：WR1_DATA 直连行缓冲寄存输出（wire，非寄存器），与旧版逐拍等价
    wire [31:0] sc_wdata = scan_rd32_w;
    // ★★ 写使能是寄存器（与已验证的 032049 版一致）：状态机在 PUSH 拍置 1，
    //   下一拍 FIFO 才真正写入。这套时序已在 bboard_key/bboard_sys 双门禁
    //   ALL PASS 过，勿再改相位或改成组合使能（实测会引入整带/周期性错位）。
    reg        wr1_load, wr1_en;
    reg [20:0] wr1_addr;
    reg [15:0] sc_drain;         // ★ 末突发写完裕量拍计数（256）

    // WR1 FIFO 排空判据：FIFO 读使能计数（每带 LOAD 拍清零，每次 FIFO pop 递增）。
    // 原为读 FIFO rp 指针影子差分，但层次路径 u_sdram.write_fifo1.logic_fifo.SAMEDOM.rp_bin
    // 穿透厂商 IP 内部（仿真行为模型可见，TD 综合黑盒报错 HDL-8007），改用读使能计数等价实现。
    // FIFO pop = Sdram_Control_4Port 的 IN_REQ & WR_MASK[0]（write_fifo1 实例化参数 .re）。
    // ★ 逐拍等价：原影子差分在 pop 沿的**下一拍**才累加（rp_q 滞后一拍），故 pop
    //   再打一拍（wr1_pop_q）后计数。实测不打拍（提前 1 拍出 FLUSH）会改变 SDRAM
    //   仲裁相位，bboard_sys 显示流出现整字错位（axerr=1603800），见 P5 文档。
    wire        wr1_pop = st_in_req_w & st_wr_mask_w[0];
    reg         wr1_pop_q;
    reg  [12:0] wr1_popd;           // 带内已落 SDRAM 字数（0..2560）

    // ★ 扫描读端口：行缓冲内部为 32bit 打包字 + 厂商 BRAM 原语，B 口读延迟 = 1 拍
    //   （原语内部寄存地址）。因此推数时序与改造前的 reg 数组版本**完全一致**：
    //   sc_ra 在 LOAD 拍预置为带内半区基址，首推落在 LOAD+1，第 k 拍推 ln[k]。
    //   本控制器对推数相位极敏感（P5 文档已记两次整字错位），故此处不改相位。
    wire [13:0] sc_half_ofs = sc_cur[0] ? PIX_BAND[13:0] : 14'd0;
    wire        wr1_full_w;                 // ★ WR1 FIFO 背压：满时暂停推数（防 shim 丢字）
    wire        win_free_w;                 // 防撕裂闸门（赋值见下方 wsh_sync 处）
    // ★ P3 写窗基址：帧窗 k%2（帧 k = render_no k；窗 k%2 与索引窗同号交替）
    wire [20:0] sc_win_base = sc_win ? (FB_BASE[20:0] + FB_TOTAL[20:0]) : FB_BASE[20:0];

    always @(posedge clk100 or negedge rst_n) begin
        if (!rst_n) begin
            sc_busy<=1'b0; sc_pend_v<=1'b0; sc_pend<=9'd0; sc_cur<=9'd0;
            sc_win<=1'b0; sc_pend_win<=1'b0;
            sc_push<=12'd0; sc_st<=3'd0;
            sc_ra<=14'd0;
            wr1_load<=1'b0; wr1_en<=1'b0; wr1_addr<=21'd0; sc_drain<=16'd0;
            scan_done<=1'b0; scan_band_no<=9'd0; scan_ack<=1'b0;
            wr1_popd<=13'd0; wr1_pop_q<=1'b0;
        end else begin
            scan_done <= 1'b0;
            scan_ack  <= 1'b0;
            wr1_load  <= 1'b0;
            wr1_en    <= 1'b0;

            // WR1 FIFO pop 计数（每拍累加；LOAD 态在下方 case 中清零——与原
            // rp 影子差分的清零时刻一致，case 内赋值后写覆盖本行）
            wr1_pop_q <= wr1_pop;
            if (wr1_pop_q)
                wr1_popd <= wr1_popd + 13'd1;

            // 新带到达：空闲即开扫，否则挂起（扫描恒快于渲染，1 级挂起足够）
            // ★ P3：band_done 拍锁 render_no[0]（带所属帧 → 写窗）；闸门扣住
            //   发往"显示正读窗"的写（band 已锁存，LOAD 推迟至显示换走）
            if (band_done_w) begin
                if (!sc_busy) begin
                    sc_cur  <= band_no_w; sc_busy <= 1'b1;
                    sc_win  <= rendered_no[0];
                    sc_push <= 12'd0;
                    sc_ra   <= (band_no_w[0] ? PIX_BAND[13:0] : 14'd0); // 半区基址（LOAD 拍再用也无害）
                    sc_st   <= win_free_w ? 3'd1 : 3'd0;
                end else if (!sc_pend_v) begin
                    sc_pend     <= band_no_w; sc_pend_v <= 1'b1;
                    sc_pend_win <= rendered_no[0];
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
            3'd2: begin // 流式推 2560 字（1 字/拍）
                if (!wr1_full_w) begin
                    // ★ 无 wr2_aempty_w 门控：WR1 推数与 WR2 FIFO 占用无关；
                    //   WR1 背压由 wr1_full_w 承担（停推时 sc_ra 冻结、恢复无重复）
                    // ★ 数据直连：WR1_DATA = 行缓冲寄存输出 = ln32[sc_ra-2 像素]。
                    //   该 1 拍 BRAM 读延迟正好替代旧版 sc_wdata 寄存级，因此
                    //   "首个 PUSH 落在 LOAD+1、第 k 拍推 ln[k]"与旧版**逐拍一致**
                    //   （旧 sc_wdata(C) = 组合读(ra(C-1)) = ln32[ra(C-1)]，同式）。
                    //   本控制器对推数相位极敏感（P5 文档已记一次整字错位），
                    //   故此处刻意保持与基线同相位，勿再插入空拍。
                    // ★ 写使能（寄存器）在 PUSH 拍置 1，下一拍真正入 FIFO；
                    //   数据同拍由行缓冲寄存输出直连供上（wr1_en 与 sc_wdata 同拍对齐）。
                    wr1_en   <= 1'b1;
                    sc_push  <= sc_push + 12'd1;
                    sc_ra    <= sc_ra + 14'd2;
                    if (sc_push == FB_WB - 1) sc_st <= 3'd3;
                end
            end
            3'd3: begin // FLUSH：等 2560 字全部被 FIFO 弹出送往 SDRAM（pop 计数）
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
                        sc_ra       <= (sc_pend[0] ? PIX_BAND[13:0] : 14'd0);
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
    // ★ P5：不要自己再插 BUFG——TD 会为该时钟网自动插时钟缓冲；手工例化
    //   BUFG_0 会与工具插的那只形成多驱动，TD 报 SYN-5066 并断开驱动源，
    //   导致 rd1_clk 恒 0、整个像素域被当死逻辑清除（实测 b_pix_clk 端点=0）。
    //   像素时钟在 timing_b.sdc 里用 create_clock 显式定义（TD 的
    //   derive_pll_clocks 漏派生 C1）。
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
    assign win_free_w = !first_win_done_w || (sc_win != win_show_100);

    // 扫出（时序+取数+AXIS；EMIT_HDMI=1 时 AXIS 入加密核）
    // ★ P5：scanout 的 rd1_clk 是**输出**（= pixel_clk，送给 SDRAM 控制器 RD1 域）。
    //   原接线把它接回 pixel_clk_w，与 PLL 输出构成多驱动网——仿真因两值相同看不
    //   出来，TD 报 SYN-5066 并断开驱动源，rd1_clk 变常 0，整个像素域被当死逻辑
    //   清除（实测 b_pix_clk 端点=0、u_scanout 从层次表消失）。单独一根线即可。
    wire        rd1_clk_w;
    wire        rd1_en_w, rd1_load_w, rd1_empty_w, rd1_we_w, rd1_bmask0_w;
    wire [20:0] rd1_addr_w;
    wire [8:0]  rd1_len_w;
    wire [31:0] rd1_data_w;
    wire        video_ready_w;
    assign rd1_we_w      = st_out_valid_w & st_rd_mask_w[0];
    assign rd1_bmask0_w  = st_rd_mask_w[0];
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
        .rd1_clk        (rd1_clk_w),
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
    // TD 构建：AXIS → 加密核 → PHY → 顶层 TMDS/DDC 端口。
    // iverilog 不编 .enc，仿真构建走 else 分支（AXIS 已由顶层观测口引出）。
    // ★ P5 骨架：端口/连线已完整（含 DDC），仅缺 AC601 引脚表与 timing_b.sdc
    //   的引脚绑定；加密核 wrapper 需从安路 IP 库获取（不在本仓库）。
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
        .O_ddc_scl          (tmds_ddc_scl),
        .IO_ddc_sda         (tmds_ddc_sda),
        .O_ch0_tmds_data    (tmds_ch0_w),
        .O_ch1_tmds_data    (tmds_ch1_w),
        .O_ch2_tmds_data    (tmds_ch2_w),
        .O_clk_tmds_data    (tmds_clk_w)
    );
    hdmi_phy_wrapper #(.DEVICE("EG")) u_hdmi_phy (
        .I_pixel_clk   (pixel_clk_w),
        .I_serial_clk  (serial_clk_w),
        .I_rst         (pixel_rst_w),
        .I_tmds_channel_0   (tmds_ch0_w),
        .I_tmds_channel_1   (tmds_ch1_w),
        .I_tmds_channel_2   (tmds_ch2_w),
        .I_tmds_channel_clk (tmds_clk_w),
        .O_tmds_ch0_p       (tmds_ch0_p),
        .O_tmds_ch1_p       (tmds_ch1_p),
        .O_tmds_ch2_p       (tmds_ch2_p),
        .O_tmds_clk_p       (tmds_clk_p)
    );
    assign video_ready_w = core_ready_w;
`else
    assign video_ready_w = 1'b1;    // 仿真：ready 仅 informational（A 板语义）
    // 仿真构建无 HDMI 核/PHY：TMDS 与 DDC_SCL 恒 0，DDC_SDA 保持高阻（不驱动）。
    assign tmds_ch0_p   = 1'b0;
    assign tmds_ch1_p   = 1'b0;
    assign tmds_ch2_p   = 1'b0;
    assign tmds_clk_p   = 1'b0;
    assign tmds_ddc_scl = 1'b0;
`endif

    // ================= vendor SDRAM 控制器（板 B 派生副本）+ 硬宏 =================
    // ★ P5：实例化 Sdram_Control_4Port_B（src/5640/sdram_ctrl_4p/b_board/）——
    //   它 = 厂商原件 + P3 三处修补 + 状态输出口。原先本层用层次引用读
    //   u_sdram.IN_REQ/WR_MASK/RD_MASK/mWR_DONE/OUT_VALID/mWR，TD 不支持层次
    //   引用（最小用例实测 HDL-8007），故改为 st_* 端口；仿真与综合共用该文件。
    //   A 板仍用厂商原件，不受影响。
    wire        st_in_req_w, st_out_valid_w, st_wr_done_w, st_wr_w;
    wire [1:0]  st_wr_mask_w, st_rd_mask_w;

    Sdram_Control_4Port_B u_sdram (
        .REF_CLK(ref_clk), .RESET_N(rst_n), .CLK(clk100),
        .WR1_DATA(sc_wdata), .WR1(wr1_en), .WR1_ADDR(wr1_addr),
        // ★ P3：MAX 恒全域（双窗下 rWR1_MAX 复位锁存无法跟随窗切换——回卷
        //   由每带 LOAD 承担，窗尾溢出走 LOAD 纠偏，同 fetch v4 哲学）
        // ★ P3：MAX 恒全域（双窗下 rWR1_MAX 复位锁存无法跟随窗切换——回卷
        .WR1_MAX_ADDR(21'h1FFFFF), .WR1_LENGTH(9'd256), .WR1_LOAD(wr1_load),
        .WR1_CLK(clk100), .WR1_FULL(wr1_full_w), .WR1_USE(),
        .WR2_DATA(wr2_data_u), .WR2(wr2_en_u), .WR2_ADDR(wr2_addr_u),
        .WR2_MAX_ADDR(21'h1FFFFF), .WR2_LENGTH(wr2_len_u), .WR2_LOAD(wr2_load_u),
        .WR2_CLK(clk100), .WR2_FULL(wr2_full_w), .WR2_USE(),
        .RD1_DATA(rd1_data_w), .RD1(rd1_en_w), .RD1_ADDR(rd1_addr_w),
        .RD1_MAX_ADDR(21'h1FFFFF), .RD1_LENGTH(rd1_len_w), .RD1_LOAD(rd1_load_w),
        .RD1_CLK(rd1_clk_w), .RD1_EMPTY(rd1_empty_w), .RD1_USE(),
        .RD2_DATA(rd2_dat_w), .RD2(rd2_re_u), .RD2_ADDR(rd2_addr_u),
        .RD2_MAX_ADDR(rd2_max_u), .RD2_LENGTH(rd2_len_u), .RD2_LOAD(rd2_load_u),
        .RD2_CLK(clk100), .RD2_EMPTY(rd2_empty_w), .RD2_USE(),
        .SA(DRAM_ADDR), .BA(DRAM_BA), .CS_N(DRAM_CS_N), .CKE(DRAM_CKE),
        .RAS_N(DRAM_RAS_N), .CAS_N(DRAM_CAS_N), .WE_N(DRAM_WE_N),
        .DQ(DRAM_DQ), .DQM(DRAM_DQM), .SDR_CLK(DRAM_CLK),
        .st_in_req(st_in_req_w), .st_out_valid(st_out_valid_w),
        .st_wr_mask(st_wr_mask_w), .st_rd_mask(st_rd_mask_w),
        .st_wr_done(st_wr_done_w), .st_wr(st_wr_w),
        .test_oe()
    );

    sdram_ip u_dram (
        .clk(DRAM_CLK), .ras_n(DRAM_RAS_N), .cas_n(DRAM_CAS_N), .we_n(DRAM_WE_N),
        .addr(DRAM_ADDR), .ba(DRAM_BA), .dq(DRAM_DQ), .cs_n(DRAM_CS_N[0]),
        .dm0(DRAM_DQM[0]), .dm1(DRAM_DQM[1]), .dm2(DRAM_DQM[2]), .dm3(DRAM_DQM[3]),
        .cke(DRAM_CKE)
    );

endmodule
