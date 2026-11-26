`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// yx_b_scanout — 板 B HDMI 扫出（P3，720p59.3 双窗）
//
// 三段拼装（设计见 docs/YX_BBOARD_P3_DISPLAY_20261121.md §4/§5）：
//   1. video_source_test（A 板文件零改动复用）：720p 时序计数 + AXI-Stream 生成
//      （valid=活跃、user=帧首、last=行尾、ready 仅 informational）；
//   2. yx_b_scanout_play（A 板取数核复制+冲洗手术）：vblank LOAD 保持至排空
//      （换窗冲洗），每奇数 x 消费 1 字，RGB565→RGB888；
//   3. 双窗基址：win_show_req（100M 域"最后完成窗号"）双拍同步入像素域，
//      vblank 更新 i_base = FB_WIN0 + win*FB_TOTAL；
//
// 撕裂免疫：渲染帧 k 写帧窗 k%2，显示读"最后完成窗"（恒异窗）——写读窗
// 互斥恒成立（TB 断言）。首窗完成前：loaded=0 → 取数核停在 !loaded 分支
// （RD1 上仅 boot 预取垃圾，首个 vblank 冲洗排掉），rgb_out=0（黑屏）。
//------------------------------------------------------------------------------
module yx_b_scanout #(
    parameter [20:0] FB_WIN0  = 21'd115200,   // 帧窗 0 基址（= 2×NB）
    parameter [20:0] FB_TOTAL = 21'd460800,   // 每帧窗字数（720×640）
    parameter integer PIX_DLY = 0             // ★ 取数核坐标延迟拍数（0=直连=A板原样）
                                              //   使 AXIS 每行吞 2 拍——延迟取数坐标
                                              //   对齐显示位置；YX6 实测校准）
)(
    // ---- 100M 域输入 ----
    input  wire        rst_n,          // 100M 域复位（低有效；win_show_req 的域标注）
    input  wire        win_show_req,   // 最后完成窗号（帧尾 band179 scan_done 更新）
    input  wire        first_win_done, // 首窗完成（显示启动；1 位，像素域双拍同步）
    // ---- 像素域 ----
    input  wire        pixel_clk,
    input  wire        pixel_rst,      // 高有效（顶层由 rst_n+extlock 同步生成）
    // ---- RD1 口（控制器）----
    output wire [20:0] rd1_addr,
    output wire        rd1_load,
    output wire [8:0]  rd1_len,
    output wire        rd1_en,
    input  wire [31:0] rd1_data,
    input  wire        rd1_empty,
    input  wire        rd1_we,         // OUT_VALID&RD_MASK[0]（顶层给，冲洗/观测）
    input  wire        rd1_bmask0,     // RD_MASK[0]（顶层给）
    output wire        rd1_clk,        // = pixel_clk（RD1 FIFO 读域）
    // ---- AXI-Stream 视频输出（TD=加密核；仿真=TB 对拍边界）----
    output wire        video_user,
    output wire        video_valid,
    output wire        video_last,
    output wire [23:0] video_data,
    input  wire        video_ready,    // TD=核 ready；仿真绑 1（informational）
    // ---- 遥测（像素域）----
    output reg  [15:0] disp_pass,      // 显示遍计数（每帧首 +1）
    output wire        win_show,       // 当前显示窗号
    output reg  [15:0] disp_stall      // pair 保持事件（RD1 供数不足观测）
);

    assign rd1_clk = pixel_clk;

    // ---- 跨域同步（1 位信号双拍；窗号只翻转、首完成只置位，逃逸窗口无害）----
    reg [1:0] win_sync;
    reg [1:0] fwin_sync;
    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst) begin
            win_sync  <= 2'b00;
            fwin_sync <= 2'b00;
        end else begin
            win_sync  <= {win_sync[0],  win_show_req};
            fwin_sync <= {fwin_sync[0], first_win_done};
        end
    end
    wire win_show_w = win_sync[1];
    wire loaded_w   = fwin_sync[1];

    // 源时序坐标与 AXIS 原始三元组（u_vsrc 输出；先声明后引用）
    wire [10:0] px_w;
    wire [9:0]  py_w;
    wire        pa_w;
    wire        vsrc_user_w, vsrc_valid_w, vsrc_last_w;

    // ---- 显示窗基址：vblank 更新（与取数核的 vb_start LOAD 同沿对齐）----
    reg [20:0] i_base_r;
    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst)
            i_base_r <= FB_WIN0;
        else if (loaded_w && (px_w == 11'd0) && (py_w == 10'd720))
            i_base_r <= FB_WIN0 + (win_show_w ? FB_TOTAL : 21'd0);
    end
    // ★ win_show 必须反映"当前实际显示的窗"= i_base 指向的窗，而不是实时的
    //   win_show_req。否则写窗闸门（顶层 win_free_w）会用错误的窗号判断互斥：
    //   req 已翻到窗 0 时显示仍在读窗 1 → 闸门放行对窗 1 的写 → 写读同窗
    //   （YX6 实测 sc_win=1 与 base=576000 并存的撕裂）。
    assign win_show = (i_base_r >= (FB_WIN0 + FB_TOTAL)) ? 1'b1 : 1'b0;

    // ---- 遥测 ----
    wire        frame_tick = (px_w == 11'd0) && (py_w == 10'd0);
    wire        pair_adv   = pa_w && px_w[0];
    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst) begin
            disp_pass  <= 16'd0;
            disp_stall <= 16'd0;
        end else begin
            if (frame_tick)
                disp_pass <= disp_pass + 16'd1;
            if (pair_adv && rd1_empty)
                disp_stall <= disp_stall + 16'd1;
        end
    end

    // ---- 时序 + AXI-Stream（A 板文件零改动复用）----
    // ★ P4：首窗完成（loaded）可能落在显示帧**中间**。此时 RD1 还没有做过任何
    //   生效的 LOAD（复位期的 boot LOAD 落在 Sdram 控制器 POR 窗被丢弃，
    //   control_interface: INIT_PER+200 内 LOAD_MODE 强制 0），取数核从陈旧
    //   ADDR（=0，索引区）预取 → 该半帧像素无效（P4 实测 ax_errs=1024，
    //   恰为首个 RD1 FIFO 深度 512 字=1024 像素的垃圾）。
    //   语义修正：显示只在"首窗完成后的第一个帧边界"才对外出图——armed 之前
    //   屏蔽 AXIS 三元组（HDMI 表现为首帧黑屏，与 A 板同语义）。armed 之后
    //   的每个帧都由 vblank LOAD 重新对齐，判据无需任何放宽。
    reg vb_seen;
    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst)
            vb_seen <= 1'b0;
        else if (!loaded_w)
            vb_seen <= 1'b0;
        else if ((px_w == 11'd0) && (py_w == 10'd720))   // 首个 vblank = LOAD 拍
            vb_seen <= 1'b1;
    end
    wire armed_w = vb_seen;

    wire [23:0] fb_rgb;
    video_source_test #(
        .HTOTAL  (1650),
        .HACTIVE (1280),
        .HFP     (110),
        .HSA     (40),
        .HBP     (220),
        .VTOTAL  (750),
        .VACTIVE (720),
        .VFP     (5),
        .VSA     (5),
        .VBP     (20)
    ) u_vsrc (
        .I_clk          (pixel_clk),
        .I_rst          (pixel_rst),
        .O_video_user   (vsrc_user_w),
        .O_video_valid  (vsrc_valid_w),
        .O_video_last   (vsrc_last_w),
        .O_video_data   (video_data),
        .I_video_ready  (video_ready),
        .O_pixel_x      (px_w),
        .O_pixel_y      (py_w),
        .O_pixel_active (pa_w),
        .I_fb_rgb       (fb_rgb)
    );

    // ★ A1（YX6）：AXIS 三元组（user/valid/last）由我们统一延迟生成，与数据
    //   逐拍对齐。数据通路 pair→video_data 共 8 级（play 4 级 r5_d/r5_c/r5_o/
    //   rgb_out + 源 2 级 P/Q + mux/组合折算），实测 VDLY=7（=8 级）时逐像素
    //   零误差、零相位偏移（tb_scanout: best_sh=0 errs=0 ALL PASS）。
    //   源自带 valid 会在行末多出 2 拍（落进消隐）→ 按拍计数被当成下一行前
    //   2 像素 → 每行首字重复；此处从根上消除。
    reg [7:0] vad, vud, vld;
    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst) begin
            vad <= 8'd0; vud <= 8'd0; vld <= 8'd0;
        end else begin
            vad <= {vad[6:0], pa_w};
            vud <= {vud[6:0], vsrc_user_w};
            vld <= {vld[6:0], vsrc_last_w};
        end
    end
`ifdef VDLY
    assign video_valid = vad[`VDLY] && armed_w;
`else
    assign video_valid = vad[7] && armed_w;
`endif
    // ★★ 2026-11-25 结构性修复：user/last 改走与 valid **同一条移位寄存器**，
    //   只少 2 级（`VDLY-2`），不再"保持源输出相位"。
    //
    //   为什么原来不行：三个移位寄存器的**输入深度不同**——
    //     vad <= pa_w          （O_pixel_active = S_active，源内 **0 级**）
    //     vud <= vsrc_user_w   （O_video_user  = Q_user，  源内 **2 级**）
    //     vld <= vsrc_last_w   （O_video_last  = Q_last，  源内 **2 级**）
    //   而 valid 取 vad[VDLY]（延迟 8）、user/last 直接取源（延迟 0）→ 两条路径
    //   深度差 8。旧注释说"与 valid 同时延迟会引入 4 拍错位"正是这个源内 2 级差
    //   在 8 级路径上的表现。旧做法（保持源相位）让 user 相对数据的落点依赖
    //   `armed_w`(=vb_seen，渲染侧给的) → **相位随码流内容漂移**。
    //   实测证据：book32（渲染提速）后，合成流 AX_OFF=0→2 可修好、真实流却修不好
    //   ——没有单一常量能同时满足两种流，证明不是标定偏差而是结构缺陷。
    //
    //   修法：源域里 user/last 比 active **早 2 级**，所以对齐到数据时只需
    //   `VDLY-2` 级延迟。这样三者同源、同机制，相位与工作负载无关。
    //   （源域同相性见 video_source_test.v:91/129-131：S_active 与 S_frame_tick
    //     同拍组合产生，同走 P/Q 两级流水。）
`ifdef VDLY
    assign video_user  = vud[`VDLY-2] && armed_w;
    assign video_last  = vld[`VDLY-2] && armed_w;
`else
    assign video_user  = vud[5] && armed_w;
    assign video_last  = vld[5] && armed_w;
`endif

    // ★ 取数核坐标延迟（PIX_DLY 级移位寄存器）：源 2 级流水使 AXIS 流每行
    //   吞首 2 拍——延迟取数坐标使弹出的字对准显示位置。
    reg [10:0] pxd [0:15];
    reg [9:0]  pyd [0:15];
    reg [15:0] pad [0:15];
    integer di;
    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst) begin
            for (di = 0; di < 16; di = di + 1) begin
                pxd[di] <= 11'd0; pyd[di] <= 10'd0; pad[di] <= 1'b0;
            end
        end else begin
            pxd[0] <= px_w; pyd[0] <= py_w; pad[0] <= pa_w;
            for (di = 1; di < 16; di = di + 1) begin
                pxd[di] <= pxd[di-1]; pyd[di] <= pyd[di-1]; pad[di] <= pad[di-1];
            end
        end
    end
    // PIX_DLY=0 → 直连（A 板原始接法）；PIX_DLY=n → 延迟 n 拍
    localparam integer PD = (PIX_DLY == 0) ? 0 : (PIX_DLY - 1);
    wire [10:0] pxd_sel = (PIX_DLY == 0) ? px_w : pxd[PD];
    wire [9:0]  pyd_sel = (PIX_DLY == 0) ? py_w : pyd[PD];
    wire        pad_sel = (PIX_DLY == 0) ? pa_w : pad[PD];

    // ---- 取数核（A 板复制 + 冲洗手术；特效绑 0 = 直通）----
    wire [23:0] play_rgb;
    yx_b_scanout_play #(
        .H_ACTIVE (1280),
        .V_ACTIVE (720)
    ) u_play (
        .pixel_clk    (pixel_clk),
        .rst          (pixel_rst),
        .pixel_x      (pxd_sel),
        .pixel_y      (pyd_sel),
        .pixel_active (pad_sel),
        .loaded       (loaded_w),
        .rd1_data     (rd1_data),
        .rd1_empty    (rd1_empty),
        .rd1_we       (rd1_we),
        .rd1_bmask0   (rd1_bmask0),
        .rd1_en       (rd1_en),
        .rd1_addr     (rd1_addr),
        .rd1_load     (rd1_load),
        .rd1_len      (rd1_len),
        .fade_dark    (4'd0),
        .bright_en    (1'b0),
        .contrast_en  (1'b0),
        .i_base       (i_base_r),
        .rgb_out      (play_rgb)
    );
    assign fb_rgb = play_rgb;

endmodule

`default_nettype wire
