`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// 映序 V0.2D-R2：低频状态 BCD 转换器
//
// 目的：
//   把 box_x / box_y 转成 4 位十进制数字，但绝不在逐像素组合路径里
//   使用 /1000、/100、/10 这类除法。
// 
// 方法：
//   每帧开始后延迟 1 个像素时钟采样最新 box_x / box_y，
//   用 Double-Dabble（Shift + Add-3）算法，每个时钟处理 1 bit。
//   11 个像素时钟后得到 4 位 BCD。
// 
// 由于 OSD 位于 y=124 附近，BCD 计算在一帧真正扫描到 OSD 前早已结束。
//------------------------------------------------------------------------------

module yingxu_status_bcd (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_tick,

    input  wire [10:0] box_x,
    input  wire [ 9:0] box_y,

    output reg  [3:0]  x_thousands,
    output reg  [3:0]  x_hundreds,
    output reg  [3:0]  x_tens,
    output reg  [3:0]  x_ones,

    output reg  [3:0]  y_thousands,
    output reg  [3:0]  y_hundreds,
    output reg  [3:0]  y_tens,
    output reg  [3:0]  y_ones
);

    reg        frame_tick_d;
    reg        busy;
    reg [3:0]  step_count;

    reg [26:0] x_shift;
    reg [26:0] y_shift;

    wire [26:0] x_adjusted;
    wire [26:0] y_adjusted;
    wire [26:0] x_next;
    wire [26:0] y_next;

    // 对 4 个 BCD nibble 分别执行 Add-3。
    function [26:0] add3_adjust;
        input [26:0] value;
        reg   [26:0] temp;
        begin
            temp = value;

            if (temp[14:11] >= 4'd5)
                temp[14:11] = temp[14:11] + 4'd3;

            if (temp[18:15] >= 4'd5)
                temp[18:15] = temp[18:15] + 4'd3;

            if (temp[22:19] >= 4'd5)
                temp[22:19] = temp[22:19] + 4'd3;

            if (temp[26:23] >= 4'd5)
                temp[26:23] = temp[26:23] + 4'd3;

            add3_adjust = temp;
        end
    endfunction

    assign x_adjusted = add3_adjust(x_shift);
    assign y_adjusted = add3_adjust(y_shift);

    assign x_next = x_adjusted << 1;
    assign y_next = y_adjusted << 1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            frame_tick_d <= 1'b0;
            busy         <= 1'b0;
            step_count   <= 4'd0;

            x_shift      <= 27'd0;
            y_shift      <= 27'd0;

            // V0.2C 初始方块坐标为 (615, 540)。
            x_thousands  <= 4'd0;
            x_hundreds   <= 4'd6;
            x_tens       <= 4'd1;
            x_ones       <= 4'd5;

            y_thousands  <= 4'd0;
            y_hundreds   <= 4'd5;
            y_tens       <= 4'd4;
            y_ones       <= 4'd0;
        end
        else begin
            frame_tick_d <= frame_tick;

            // 延迟 1 拍采样，让 Overlay 在 frame_tick 那一拍先完成坐标更新。
            if (!busy && frame_tick_d) begin
                x_shift    <= {16'd0, box_x};
                y_shift    <= {16'd0, 1'b0, box_y};
                step_count <= 4'd0;
                busy       <= 1'b1;
            end
            else if (busy) begin
                x_shift <= x_next;
                y_shift <= y_next;

                if (step_count == 4'd10) begin
                    // 第 11 次 shift 后，BCD 位于 [26:11]。
                    x_thousands <= x_next[26:23];
                    x_hundreds  <= x_next[22:19];
                    x_tens      <= x_next[18:15];
                    x_ones      <= x_next[14:11];

                    y_thousands <= y_next[26:23];
                    y_hundreds  <= y_next[22:19];
                    y_tens      <= y_next[18:15];
                    y_ones      <= y_next[14:11];

                    busy <= 1'b0;
                end
                else begin
                    step_count <= step_count + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
