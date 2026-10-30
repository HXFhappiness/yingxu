`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// 映序 V0.3D-C-R2：OSD 内部一级流水
//
// 原路径：
//   pixel_x/y
//     -> 区域判断 / 字符定位 / char_code
//     -> Font ROM
//     -> RGB mux
//     -> HDMI FIFO
//
// R2 拆分：
//   Stage A (组合)
//     区域判断 + 字符定位 + char_code/font_row/font_col
//          ↓
//   OSD PIPE REG
//          ↓
//   Stage B (组合)
//     Font ROM + font_pixel + 最终 RGB mux
//
// OSD 输出相对输入整体增加 1 个 pixel clock 延迟。
// 上层 video_source_test 同步把 valid/user/last 再延迟 1 拍。
//------------------------------------------------------------------------------
module yingxu_osd_lite (
    input  wire          clk,
    input  wire          rst,

    input  wire          pixel_active,
    input  wire [10:0]   pixel_x,
    input  wire [ 9:0]   pixel_y,
    input  wire [23:0]   bg_rgb,
    input  wire          mode_vertical,

    input  wire [3:0]    x_thousands,
    input  wire [3:0]    x_hundreds,
    input  wire [3:0]    x_tens,
    input  wire [3:0]    x_ones,

    input  wire [3:0]    y_thousands,
    input  wire [3:0]    y_hundreds,
    input  wire [3:0]    y_tens,
    input  wire [3:0]    y_ones,

    output reg  [23:0]   rgb_out
);

    localparam [23:0] C_PANEL  = 24'h101820;
    localparam [23:0] C_ORANGE = 24'hFF8000;
    localparam [23:0] C_WHITE  = 24'hFFFFFF;
    localparam [23:0] C_CYAN   = 24'h00FFFF;
    localparam [23:0] C_YELLOW = 24'hFFFF00;

    localparam [10:0] PANEL_X0 = 11'd24;
    localparam [ 9:0] PANEL_Y0 = 10'd20;
    localparam [10:0] PANEL_W  = 11'd310;
    localparam [ 9:0] PANEL_H  = 10'd166;
    localparam [ 4:0] PANEL_T  = 5'd4;

    localparam [10:0] TEXT_X   = 11'd46;
    localparam [ 9:0] LINE0_Y  = 10'd40;
    localparam [ 9:0] LINE1_Y  = 10'd82;
    localparam [ 9:0] LINE2_Y  = 10'd124;

    // -------------------------------------------------------------------------
    // Stage A: OSD decode.
    // -------------------------------------------------------------------------
    reg  [7:0]  A_char_code;
    reg  [3:0]  A_font_row;
    reg  [2:0]  A_font_col;
    reg         A_text_enable;
    reg  [23:0] A_text_color;
    reg  [5:0]  A_char_index;

    wire A_panel_outer;
    wire A_panel_inner;
    wire A_panel_border;

    assign A_panel_outer =
        pixel_active &&
        (pixel_x >= PANEL_X0) && (pixel_x < PANEL_X0 + PANEL_W) &&
        (pixel_y >= PANEL_Y0) && (pixel_y < PANEL_Y0 + PANEL_H);

    assign A_panel_inner =
        pixel_active &&
        (pixel_x >= PANEL_X0 + PANEL_T) && (pixel_x < PANEL_X0 + PANEL_W - PANEL_T) &&
        (pixel_y >= PANEL_Y0 + PANEL_T) && (pixel_y < PANEL_Y0 + PANEL_H - PANEL_T);

    assign A_panel_border = A_panel_outer && !A_panel_inner;

    always @(*) begin
        A_char_code   = 8'h20;
        A_font_row    = 4'd0;
        A_font_col    = 3'd0;
        A_text_enable = 1'b0;
        A_text_color  = C_WHITE;
        A_char_index  = 6'd0;

        // LINE 0: YINGXU
        if ((pixel_x >= TEXT_X) && (pixel_x < TEXT_X + 11'd96) &&
            (pixel_y >= LINE0_Y) && (pixel_y < LINE0_Y + 10'd32)) begin

            A_text_enable = 1'b1;
            A_char_index  = (pixel_x - TEXT_X) >> 4;
            A_font_col    = ((pixel_x - TEXT_X) >> 1) & 3'b111;
            A_font_row    = (pixel_y - LINE0_Y) >> 1;
            A_text_color  = C_ORANGE;

            case (A_char_index)
                6'd0: A_char_code = "Y";
                6'd1: A_char_code = "I";
                6'd2: A_char_code = "N";
                6'd3: A_char_code = "G";
                6'd4: A_char_code = "X";
                6'd5: A_char_code = "U";
                default: A_char_code = " ";
            endcase
        end

        // LINE 1: MODE
        else if ((pixel_x >= TEXT_X) && (pixel_x < TEXT_X + 11'd256) &&
                 (pixel_y >= LINE1_Y) && (pixel_y < LINE1_Y + 10'd32)) begin

            A_text_enable = 1'b1;
            A_char_index  = (pixel_x - TEXT_X) >> 4;
            A_font_col    = ((pixel_x - TEXT_X) >> 1) & 3'b111;
            A_font_row    = (pixel_y - LINE1_Y) >> 1;
            A_text_color  = mode_vertical ? C_YELLOW : C_CYAN;

            case (A_char_index)
                6'd0:  A_char_code = "M";
                6'd1:  A_char_code = "O";
                6'd2:  A_char_code = "D";
                6'd3:  A_char_code = "E";
                6'd4:  A_char_code = ":";
                6'd5:  A_char_code = " ";
                6'd6:  A_char_code = mode_vertical ? "V" : "H";
                6'd7:  A_char_code = mode_vertical ? "E" : "O";
                6'd8:  A_char_code = "R";
                6'd9:  A_char_code = mode_vertical ? "T" : "I";
                6'd10: A_char_code = mode_vertical ? "I" : "Z";
                6'd11: A_char_code = mode_vertical ? "C" : "O";
                6'd12: A_char_code = mode_vertical ? "A" : "N";
                6'd13: A_char_code = mode_vertical ? "L" : "T";
                6'd14: A_char_code = mode_vertical ? " " : "A";
                6'd15: A_char_code = mode_vertical ? " " : "L";
                default: A_char_code = " ";
            endcase
        end

        // LINE 2: X:0615  Y:0540
        else if ((pixel_x >= TEXT_X) && (pixel_x < TEXT_X + 11'd224) &&
                 (pixel_y >= LINE2_Y) && (pixel_y < LINE2_Y + 10'd32)) begin

            A_text_enable = 1'b1;
            A_char_index  = (pixel_x - TEXT_X) >> 4;
            A_font_col    = ((pixel_x - TEXT_X) >> 1) & 3'b111;
            A_font_row    = (pixel_y - LINE2_Y) >> 1;
            A_text_color  = C_WHITE;

            case (A_char_index)
                6'd0:  A_char_code = "X";
                6'd1:  A_char_code = ":";
                6'd2:  A_char_code = 8'h30 + x_thousands;
                6'd3:  A_char_code = 8'h30 + x_hundreds;
                6'd4:  A_char_code = 8'h30 + x_tens;
                6'd5:  A_char_code = 8'h30 + x_ones;
                6'd6:  A_char_code = " ";
                6'd7:  A_char_code = " ";
                6'd8:  A_char_code = "Y";
                6'd9:  A_char_code = ":";
                6'd10: A_char_code = 8'h30 + y_thousands;
                6'd11: A_char_code = 8'h30 + y_hundreds;
                6'd12: A_char_code = 8'h30 + y_tens;
                6'd13: A_char_code = 8'h30 + y_ones;
                default: A_char_code = " ";
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // OSD pipeline register.
    // Every Stage-B input is registered here, so pixel_x/y can no longer feed
    // the final HDMI RGB path in the same clock cycle.
    // -------------------------------------------------------------------------
    reg  [7:0]  P_char_code;
    reg  [3:0]  P_font_row;
    reg  [2:0]  P_font_col;
    reg         P_text_enable;
    reg  [23:0] P_text_color;
    reg  [23:0] P_bg_rgb;
    reg         P_panel_inner;
    reg         P_panel_border;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            P_char_code    <= 8'h20;
            P_font_row     <= 4'd0;
            P_font_col     <= 3'd0;
            P_text_enable  <= 1'b0;
            P_text_color   <= C_WHITE;
            P_bg_rgb       <= 24'h000000;
            P_panel_inner  <= 1'b0;
            P_panel_border <= 1'b0;
        end
        else begin
            P_char_code    <= A_char_code;
            P_font_row     <= A_font_row;
            P_font_col     <= A_font_col;
            P_text_enable  <= A_text_enable;
            P_text_color   <= A_text_color;
            P_bg_rgb       <= bg_rgb;
            P_panel_inner  <= A_panel_inner;
            P_panel_border <= A_panel_border;
        end
    end

    // -------------------------------------------------------------------------
    // Stage B: font lookup + final RGB mux.
    // -------------------------------------------------------------------------
    wire [7:0] P_font_bits;
    wire       P_font_pixel;

    yingxu_font8x16_lite U_font (
        .char_code(P_char_code),
        .row(P_font_row),
        .row_bits(P_font_bits)
    );

    assign P_font_pixel = P_text_enable && P_font_bits[7-P_font_col];

    always @(*) begin
        rgb_out = P_bg_rgb;

        if (P_panel_inner)
            rgb_out = C_PANEL;

        if (P_panel_border)
            rgb_out = C_ORANGE;

        if (P_font_pixel)
            rgb_out = P_text_color;
    end

endmodule

`default_nettype wire
