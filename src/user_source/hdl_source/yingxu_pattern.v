`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// 项目名称 : 映序 YingXu
// 文件名称 : yingxu_pattern.v
// 模块名称 : yingxu_pattern
// 版本     : V0.2A
//
// 功能说明 :
//   独立的视频内容发生器。
//   输入当前像素坐标和有效区标志，输出 RGB888 像素。
//   本版本严格复现 V0.1 PASS 的 8 彩条 + 中央白十字。
//
// 设计约束 :
//   本模块只负责“画什么”，不得产生或修改 HDMI 时序。
//   后续可以直接替换/扩展为矩形、OSD、Sprite、Framebuffer 等内容层。
//------------------------------------------------------------------------------

module yingxu_pattern #(
    parameter       H_ACTIVE     = 1280, // 有效显示宽度。
    parameter       V_ACTIVE     = 720   // 有效显示高度。
) (
    input   wire    [  10: 0]       pixel_x,       // 当前水平像素坐标。
    input   wire    [   9: 0]       pixel_y,       // 当前垂直像素坐标。
    input   wire                    pixel_active,  // 当前像素位于有效显示区。
    input   wire                    frame_tick,    // 每帧起始脉冲，V0.2A 暂不使用。
    output  reg     [  23: 0]       rgb_out        // 当前像素 RGB888 输出。
);

    localparam [23:0] C_WHITE   = 24'hFFFFFF; // 白色。
    localparam [23:0] C_YELLOW  = 24'hFFFF00; // 黄色。
    localparam [23:0] C_CYAN    = 24'h00FFFF; // 青色。
    localparam [23:0] C_GREEN   = 24'h00FF00; // 绿色。
    localparam [23:0] C_MAGENTA = 24'hFF00FF; // 品红色。
    localparam [23:0] C_RED     = 24'hFF0000; // 红色。
    localparam [23:0] C_BLUE    = 24'h0000FF; // 蓝色。
    localparam [23:0] C_BLACK   = 24'h000000; // 黑色。

    // ---- rgb_out: combinational pattern generation ----
    // 活动区外固定输出黑色；活动区内按 x 坐标产生 8 条等宽彩条，
    // 最后叠加中央白色十字，用于验证坐标、方向和图案层覆盖关系。
    always @(*) begin
        rgb_out = C_BLACK; // 默认黑色，同时覆盖 blanking 区。

        if (pixel_active) begin
            if      (pixel_x < 11'd160)
                rgb_out = C_WHITE;   // 第 1 条：白。
            else if (pixel_x < 11'd320)
                rgb_out = C_YELLOW;  // 第 2 条：黄。
            else if (pixel_x < 11'd480)
                rgb_out = C_CYAN;    // 第 3 条：青。
            else if (pixel_x < 11'd640)
                rgb_out = C_GREEN;   // 第 4 条：绿。
            else if (pixel_x < 11'd800)
                rgb_out = C_MAGENTA; // 第 5 条：品红。
            else if (pixel_x < 11'd960)
                rgb_out = C_RED;     // 第 6 条：红。
            else if (pixel_x < 11'd1120)
                rgb_out = C_BLUE;    // 第 7 条：蓝。
            else
                rgb_out = C_BLACK;   // 第 8 条：黑。

            if (((pixel_x >= 11'd637) && (pixel_x <= 11'd643)) ||
                ((pixel_y >= 10'd357) && (pixel_y <= 10'd363)))
                rgb_out = C_WHITE;   // 中央横纵十字优先覆盖彩条。
        end
    end

    // V0.2A 暂不使用 frame_tick；保留接口给 V0.2B 动画模块。
    wire _unused_frame_tick = frame_tick;

    // 参数引用用于明确本模块设计目标尺寸。
    wire [21:0] _unused_active_size = H_ACTIVE * V_ACTIVE;

endmodule

`default_nettype wire
