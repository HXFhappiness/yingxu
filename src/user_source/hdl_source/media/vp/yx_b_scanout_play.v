`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// yx_b_scanout_play — 板 B 显示取数核（P3）
//
// 自 A 板 yingxu_sdram_video_player.v 逐字复制（RD2→RD1 改名），管线深度与
// 取数节奏是显示对齐的一部分，特效级（fade/contrast/brightness）原样保留、
// 由 yx_b_scanout 实例化时绑 0（综合折叠为直通）。
//
// ★ B 板手术 1（vblank 冲洗）：A 板显示对单一区域连续循环，MAX 回绕使 FIFO
//   残留恰好是下一遍头部，无需冲洗；B 板双窗换窗时残留 = 旧窗过读垃圾
//   （vendor Sdram_RD_FIFO 的 LOAD 不清 FIFO——wrapper 内 .rst(!RESET_N)，
//   //(RD1_LOAD) 注释即证据），故 vblank 的 LOAD 改为"保持至 FIFO 排空且
//   无在途突发"（LOAD 冻结全部通道调度，弹空只在排残留；实测复用 fetch
//   v5 CP_LOAD 同款机制）。LOAD 保持期 ~残存量（≤128+突发），落在消隐期。
// ★ B 板手术 2（loaded 语义）：A 板 loaded= 装载器让位；B 板 loaded = 首窗
//   已完成（yx_b_scanout 同步）——首窗完成前机器停在 !loaded 分支（RD1 上
//   只有 boot LOAD 预取的垃圾，首个 vblank 冲洗排掉），显示输出黑。
//
// 其余逐字保留 A 板语义（含两条硬件教训注释）：每奇数 x 消费 1 字且取数
// 永不跳位（FIFO 空时保持 pair，不可采垃圾）；1 字 = 2 像素 [31:16]/[15:0]。
//------------------------------------------------------------------------------
module yx_b_scanout_play #(
    parameter integer H_ACTIVE     = 1280,
    parameter integer V_ACTIVE     = 720
)(
    input  wire        pixel_clk,
    input  wire        rst,             // 像素域复位（高有效）

    input  wire [10:0] pixel_x,
    input  wire [ 9:0] pixel_y,
    input  wire        pixel_active,
    input  wire        loaded,          // B 板 = 首窗已完成（像素域同步后）

    input  wire [31:0] rd1_data,
    input  wire        rd1_empty,
    input  wire        rd1_we,          // 控制器推数脉冲（OUT_VALID&RD_MASK[0]，顶层给）
    input  wire        rd1_bmask0,      // RD_MASK[0]：RD1 突发在途标志（顶层给）
    output reg         rd1_en,
    output wire [20:0] rd1_addr,
    output reg         rd1_load,
    output wire [8:0]  rd1_len,

    input  wire [ 3:0] fade_dark,       // B 板绑 0
    input  wire        bright_en,       // B 板绑 0
    input  wire        contrast_en,     // B 板绑 0
    input  wire [20:0] i_base,          // 显示窗基址（像素域，vblank 更新）
    output reg  [23:0] rgb_out
);
    assign rd1_addr = i_base;
    // ★ B 板：突发 256 字（=整行，256 对齐无跨行——YX6 教训）。WR1 扫描突发
    //   256 拍期间显示耗 ~174 字，128 字/轮补充 < 消耗 → 结构性下溢移相；
    //   256 字/轮 > 消耗，占用振荡 126..382 恒正（YX6 实测调参）。
    assign rd1_len  = 9'd256;

    reg [31:0] pair;
    reg [23:0] fade_rgb;
    reg [4:0]  r5_d, b5_d;
    reg [5:0]  g6_d;
    reg [4:0]  r5_o, b5_o;
    reg [5:0]  g6_o;
    reg signed [8:0] r5_c, b5_c;
    reg signed [9:0] g6_c;

    // signed brightness offset, -24..+24
    wire signed [6:0] off8 = bright_en ? 7'sd24 : 7'sd0;

    function [4:0] clamp5(input signed [8:0] v);
        begin
            if (v < 0) clamp5 = 5'd0;
            else if (v > 9'sd31) clamp5 = 5'd31;
            else clamp5 = v[4:0];
        end
    endfunction

    function [5:0] clamp6(input signed [9:0] v);
        begin
            if (v < 0) clamp6 = 6'd0;
            else if (v > 10'sd63) clamp6 = 6'd63;
            else clamp6 = v[5:0];
        end
    endfunction

    // Contrast gain by shift-add: one bit selects x1 or x1.5. No multiplier.
    wire signed [8:0]  r5_g = contrast_en ? ($signed({4'd0, r5_d}) + $signed({5'd0, r5_d[4:1]})) : $signed({4'd0, r5_d});
    wire signed [8:0]  b5_g = contrast_en ? ($signed({4'd0, b5_d}) + $signed({5'd0, b5_d[4:1]})) : $signed({4'd0, b5_d});
    wire signed [9:0]  g6_g = contrast_en ? ($signed({4'd0, g6_d}) + $signed({5'd0, g6_d[5:1]})) : $signed({4'd0, g6_d});
    reg        primed;
    // ---- skid 预取缓冲（4 深；do 为 pop 沿寄存 → 在途 1 拍）----
    reg [31:0] sk_mem [0:3];
    reg [1:0]  sk_wp = 2'd0, sk_rp = 2'd0;
    reg [2:0]  sk_cnt = 3'd0;           // 已存字数（不含在途）
    reg        sk_cap = 1'b0;           // 上一拍已发 pop，本拍 do 有效
    wire       sk_empty = (sk_cnt == 3'd0);
    wire       sk_room  = (sk_cnt <= 3'd2);      // 留 1 位给在途
    wire [31:0] sk_head = sk_mem[sk_rp];
    reg        loading;
    reg        refwait;                 // ★ B 板：冲洗后回灌等待（防遍首下溢）
    wire       pair_advance;            // 赋值见下方 vb_start 处
    // 取数条件（组合，避免阻塞赋值顺序问题）
    wire       sk_take  = loaded && !loading && !refwait && !sk_empty &&
                          (!primed || pair_advance);
    reg [15:0] refwait_cnt;
    reg [2:0]  load_cnt;
    reg [3:0]  boot_cnt;

    localparam integer REFWAIT_CYC = 600; // 像素拍：控制器灌 128 字突发 ~136 拍 + 裕量
                                          // （消隐预算 49.5K 拍，余量充足）

    wire vb_start     = (pixel_x == 11'd0) && (pixel_y == V_ACTIVE);
    // 取数推进与像素选择用绝对 x 奇偶（A 板原样）。曾试"连续有效像素计数器"
    // 方案（pcnt），实测反而使 pair 冻结更久，已回退——行首 4 像素现象作为
    // 已知限制记录（见 docs/YX_BBOARD_P3_DISPLAY_20261121.md §8.5）。
    assign pair_advance = pixel_active && pixel_x[0];
    wire sel_high     = pixel_x[0];

    // ★ B 板布局适配：扫描写端打包 {奇像素,偶像素}（[31:16]=奇/[15:0]=偶，
    //   与 A1 金标 expw={ln[2k+1],ln[2k]} 一致）——mux 相对 A 板翻转：
    //   偶数 x → [15:0]（偶像素）、奇数 x → [31:16]（奇像素）。
    wire [15:0] pix = sel_high ? pair[31:16] : pair[15:0];
    wire [7:0]  r8  = { pix[15:11], pix[15:13] };
    wire [7:0]  g8  = { pix[10:5],  pix[10:9]  };
    wire [7:0]  b8  = { pix[4:0],   pix[4:2]   };
    // Fade runs on the 5/6-bit source fields, before expansion: narrower
    // subtracters than doing it on the 8-bit channels.
    wire [5:0]  dark6 = { fade_dark[3:0], 2'b00 };          // 0..60
    wire [4:0]  dark5 = { fade_dark[3:0], 1'b0 };          // 0..30

    // Fade and brightness are both additive, so they share one saturating
    // add: (pixel - dark) + bright. Doing them in separate stages cost a
    // pipeline register and pushed the pixel domain to zero slack.
    wire signed [9:0] r5f_s = $signed({5'd0, pix[15:11]}) - $signed({5'd0, dark5[4:0]}) + off8;
    wire signed [10:0] g6f_s = $signed({5'd0, pix[10:5]}) - $signed({5'd0, dark6[5:0]}) + off8;
    wire signed [9:0] b5f_s = $signed({5'd0, pix[4:0]}) - $signed({5'd0, dark5[4:0]}) + off8;

    wire [4:0] r5f = (r5f_s < 0) ? 5'd0 : (r5f_s > 10'sd31) ? 5'd31 : r5f_s[4:0];
    wire [5:0] g6f = (g6f_s < 0) ? 6'd0 : (g6f_s > 11'sd63) ? 6'd63 : g6f_s[5:0];
    wire [4:0] b5f = (b5f_s < 0) ? 5'd0 : (b5f_s > 10'sd31) ? 5'd31 : b5f_s[4:0];

    always @(posedge pixel_clk or posedge rst) begin
        if (rst) begin
            pair     <= 32'd0;
            primed   <= 1'b0;
            loading  <= 1'b0;
            refwait  <= 1'b0;
            refwait_cnt <= 16'd0;
            load_cnt <= 3'd0;
            rd1_en   <= 1'b0;
            rd1_load <= 1'b1;
            boot_cnt <= 4'd8;
            sk_wp <= 2'd0; sk_rp <= 2'd0; sk_cnt <= 3'd0; sk_cap <= 1'b0;
            rgb_out  <= 24'h000000;
        fade_rgb <= 24'h000000;
        r5_d <= 5'd0; g6_d <= 6'd0; b5_d <= 5'd0;
        r5_o <= 5'd0; g6_o <= 6'd0; b5_o <= 5'd0;
        r5_c <= 9'sd0; g6_c <= 10'sd0; b5_c <= 9'sd0;
        end
        else begin
            rd1_en <= 1'b0;

            // ---- skid 进出（入库=上拍 pop 的 do；出库=pair 取数）----
            if (sk_cap) begin
                sk_mem[sk_wp] <= rd1_data;
                sk_wp <= sk_wp + 2'd1;
            end
            if (sk_take) begin
                sk_rp <= sk_rp + 2'd1;
                pair  <= sk_head;
                primed <= 1'b1;
            end
            sk_cnt <= sk_cnt + (sk_cap ? 3'd1 : 3'd0) - (sk_take ? 3'd1 : 3'd0);
            sk_cap <= 1'b0;
            // ---- 持续预取：LOAD 期外、有空间、源非空即拉 ----
            if (loaded && !loading && !refwait && sk_room && !rd1_empty) begin
                rd1_en <= 1'b1;
                sk_cap <= 1'b1;
            end

            if (boot_cnt != 4'd0)
                boot_cnt <= boot_cnt - 4'd1;

            if (!loaded) begin
                // Loader owns the SDRAM: stay off the read port completely, and
                // only issue the initial LOAD pulse (a held LOAD would keep the
                // read FIFO empty and starve the loader in the arbiter).
                loading  <= 1'b0;
                refwait  <= 1'b0;
                load_cnt <= 3'd0;
                rd1_load <= (boot_cnt != 4'd0);
                primed   <= 1'b0;
                sk_cnt   <= 3'd0;            // 旧窗残留作废
                // ★★ 2026-11-26 修复：清计数**必须同时复位指针**。
                //   原实现只清 sk_cnt、保留 sk_wp/sk_rp，破坏了"计数与指针一致"
                //   的不变量：帧边界后首次 push 写到沿用位置，首次 take 却从陈旧
                //   sk_rp 读 → 读到的不是刚推入的字，整帧前移 1 个字。
                //   偏移量取决于边界时刻 (sk_wp−sk_rp)，而它由预取节奏决定 →
                //   **随码流变化**（实测 book32 后合成流偏 1 字、真实流不偏，
                //   造成"同一 AX_OFF 只能修好一个流"的假象）。
                //   证据：RD1 首次 pop 的 do 两流都等于 mem[i_base]（FIFO 侧正确），
                //   而 AXIS 从 word 1 起吐 → 丢失点在 skid，不在 FIFO。
                sk_wp    <= 2'd0;
                sk_rp    <= 2'd0;
            end
            else if (vb_start) begin
                loading  <= 1'b1;
                refwait  <= 1'b0;
                rd1_load <= 1'b1;
                primed   <= 1'b0;
                sk_cnt   <= 3'd0;            // 换窗前清空 skid
                sk_wp    <= 2'd0;            // ★ 同 !loaded 分支：指针一起复位
                sk_rp    <= 2'd0;
            end
            else if (loading) begin
                // ★ B 板手术 1：LOAD 保持至 FIFO 排空且无在途突发——冲洗旧窗
                //   过读残留（LOAD 冻结调度，弹空只排残留）。排空后必须撤 LOAD
                //   （YX6 首跑死锁根因：退出分支忘了清 rd1_load → LOAD 恒高 →
                //   调度器永久冻结）。地址在保持期已连续锁存，撤销即恢复调度。
                if (rd1_empty && !rd1_bmask0) begin
                    loading  <= 1'b0;
                    refwait  <= 1'b1;        // ★ B 板手术 3：回灌等待（见下）
                    refwait_cnt <= REFWAIT_CYC;
                    rd1_load <= 1'b0;        // 撤 LOAD：调度恢复 → 控制器灌数
                end else begin
                    rd1_load <= 1'b1;
                    rd1_en   <= !rd1_empty;  // 冲洗弹空（不捕获、不动 pair）
                end
            end
            else if (refwait) begin
                // ★ B 板手术 3：遍首回灌等待——冲洗排空后 FIFO 仅 1 字可 priming，
                //   显示 0.5 字/拍 追不上灌数突发节奏 → 遍首大面积下溢（YX6 实测
                //   disp_stall≈4.5K/遍、相位断裂）。等控制器灌满首突发再 priming。
                refwait_cnt <= refwait_cnt - 16'd1;
                if (refwait_cnt == 16'd1)
                    refwait <= 1'b0;
            end
            // ★ pair 装载已由上方 sk_take 统一驱动（skid 预取），此处不再直接
            //   从 FIFO 拉数——行首断流导致的左边缘 4 像素条纹由此消除。

            // stage 1: fade (subtract), stage 2: contrast + brightness
            r5_d <= r5f;
            g6_d <= g6f;
            b5_d <= b5f;

            // stage 2: contrast gain (registered)
            r5_c <= r5_g;
            b5_c <= b5_g;
            g6_c <= g6_g;

            // stage 3: brightness offset + clamp
            r5_o <= clamp5(r5_c);
            b5_o <= clamp5(b5_c);
            g6_o <= clamp6(g6_c);

            // ★ B 板：仅用 primed 门控，不用 pixel_active——行首 2 拍 active
            //   尚未随流水线到位，若并用会把有效像素黑掉（实测行首黑 2 拍）。
            //   HDMI 核只在自己的 active 窗口取数，消隐期输出数据无害。
            rgb_out <= primed ?
                       { r5_o, r5_o[4:2], g6_o, g6_o[5:4], b5_o, b5_o[4:2] } :
                       24'h000000;
        end
    end

    wire [31:0] _unused = rd1_we;    // 预留：如需推数计数可启用（现冲洗用 bmask0/empty）
    wire [2:0]  _unused2 = load_cnt; // 8 拍计数被"排空+无在途"条件取代，保留观测名

endmodule

`default_nettype wire
