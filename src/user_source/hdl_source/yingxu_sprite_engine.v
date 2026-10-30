`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// yingxu_sprite_engine  -  v2 (line-buffered)
//
// v1 compared all sprites against the current pixel combinationally and muxed
// straight into the video output. That worked logically but lengthened the
// pixel path enough to disturb the SDRAM replay stream (vertical stripes and,
// in one build, no video at all).
//
// v2 keeps the pixel path shallow:
//
//   display  : BRAM read (registered inside the RAM) -> one mux -> output
//   rendering: while line Y is scanned, the sprites for line Y+1 are written
//              into the OTHER half of the buffer. All compare logic now feeds a
//              BRAM write port instead of the video output.
//
// Two line buffers live in one array addressed as {buffer, x}. Buffer 0 holds
// even lines, buffer 1 odd lines; the writer always targets the opposite of the
// line being displayed, so a line is fully rendered before it is shown.
//
// Colour 0x000000 means "transparent" (background shows through).
//------------------------------------------------------------------------------
module yingxu_sprite_engine #(
    parameter integer NSLOT   = 16,
    parameter integer H_ACTIVE = 1280,
    parameter integer H_TOTAL  = 1650,
    parameter integer V_ACTIVE = 720,
    parameter integer V_TOTAL  = 750,
    parameter integer BRICK_COLS = 10,
    parameter integer BRICK_ROWS = 6,
    parameter integer BRICK_W    = 128,
    parameter integer BRICK_H    = 32,
    parameter integer BRICK_X0   = 0,
    parameter integer BRICK_Y0   = 60
)(
    input  wire        clk,          // pixel clock
    input  wire        rst,

    input  wire [10:0] pixel_x,
    input  wire [ 9:0] pixel_y,
    input  wire        pixel_active,
    input  wire [23:0] bg_rgb,

    // Sprite table write port: one slot per write.
    input  wire        we,
    input  wire [ 3:0] slot,
    input  wire        en,
    input  wire [10:0] spr_x,
    input  wire [ 9:0] spr_y,
    input  wire [ 6:0] spr_w,
    input  wire [ 5:0] spr_h,
    input  wire [23:0] spr_color,

    // Brick layer: one bit per brick, row-major (row 0 = top).
    input  wire [59:0] brick_mask,
    input  wire [23:0] tile_rgb,        // scrolling tile background (0 = none)

    output wire [23:0] rgb_out
);

    // ---- sprite table -------------------------------------------------------
    // P2b: the right/bottom edges (x+w, y+h) are computed here, at table-write
    // time, and stored in the entry. The old layout stored {x, y, w, h} and
    // every per-pixel hit test rebuilt both sums, keeping sixteen adders
    // directly in the render path. Storing the edges removes them from the
    // per-pixel logic entirely (16 writes per frame vs 1.2M compares).
    // Widths match the original fields, so a slot whose x+w overflows 11 bits
    // wraps exactly like the original code did (no game data ever does).
    // Entry layout (67 bits): {en, x[10:0], x+w[10:0], y[9:0], y+h[9:0], color[23:0]}
    reg [66:0] spr_tab [0:NSLOT-1];

    wire [10:0] wr_xpw = spr_x + {4'd0, spr_w};
    wire [ 9:0] wr_yph = spr_y + {4'd0, spr_h};

    always @(posedge clk) begin
        if (we)
            spr_tab[slot] <= {en, spr_x, wr_xpw, spr_y, wr_yph, spr_color};
    end

    // ---- line buffers: 2 x H_ACTIVE entries of 24 bit -----------------------
    // 16-bit entries: 2 x 1280 x 16 = 40 Kbit, one BRAM block instead of three.
    // RGB565 keeps the line buffer small; it is expanded at the output mux.
    // Stride is 2048 (the {sel, x} concatenation uses bit 11 as the buffer
    // select), so the array must hold 2 x 2048 entries. Declaring it as
    // 2*H_ACTIVE = 2560 made every write with x > 512 alias into the wrong
    // place, which showed up as striped brick remnants and a corrupted
    // background in photo mode.
    reg [15:0] ovl [0:4095];

    wire wr_sel = ~pixel_y[0];      // render into the buffer not being shown
    wire rd_sel =  pixel_y[0];

    // Next line to render. Wrapping from the last total line back to line 0
    // keeps the first visible line supplied during vertical blanking.
    wire [9:0] next_y = (pixel_y == V_TOTAL - 1) ? 10'd0 : (pixel_y + 10'd1);

    // P2c: the y test is constant for a whole scan line (next_y only moves at
    // the line wrap), so it is computed one cycle ahead and registered. The
    // per-pixel path keeps only the x compares. next_y_r walks one cycle ahead
    // of the wire: it holds next_y(t+1) by incrementing itself only on the
    // cycle where pixel_y is about to wrap (pixel_x == H_TOTAL-1), which keeps
    // it locked to the raster from reset on (reset value = next_y at x=y=0).
    reg [9:0] next_y_r;

    wire [9:0] next_y_next =
        (pixel_x == H_TOTAL - 1) ?
            ((next_y_r == V_TOTAL - 1) ? 10'd0 : next_y_r + 10'd1) :
            next_y_r;

    always @(posedge clk) begin
        if (rst)
            next_y_r <= 10'd1;          // next_y when pixel_y == 0
        else
            next_y_r <= next_y_next;
    end

    // ---- render: which sprite covers (pixel_x, next_y) ----------------------
    wire [NSLOT-1:0] hit;
    reg  [NSLOT-1:0] yhit_r;

    integer yk;
    always @(posedge clk) begin
        if (rst) begin
            yhit_r <= {NSLOT{1'b0}};
        end
        else begin
            for (yk = 0; yk < NSLOT; yk = yk + 1) begin
                yhit_r[yk] <= (next_y_next >= spr_tab[yk][43:34]) &&
                              (next_y_next <  spr_tab[yk][33:24]);
            end
        end
    end

    function [95:0] bm_row_of;
        input [5:0] dy;
        begin
            case (dy)
            6'd0 : bm_row_of = 96'h000000000000000000000000;
            6'd1 : bm_row_of = 96'h000000000000000000000000;
            6'd2 : bm_row_of = 96'h000000000000000000000000;
            6'd3 : bm_row_of = 96'h000000000000000000000000;
            6'd4 : bm_row_of = 96'h000000000000000000000000;
            6'd5 : bm_row_of = 96'h000000000000000000000000;
            6'd6 : bm_row_of = 96'h000000000000000000000000;
            6'd7 : bm_row_of = 96'h000000000000000000000000;
            6'd8 : bm_row_of = 96'h000000000000000000000000;
            6'd9 : bm_row_of = 96'h0000000007E5555000000000;
            6'd10: bm_row_of = 96'h0000000007E5555000000000;
            6'd11: bm_row_of = 96'h000000000015540000000000;
            6'd12: bm_row_of = 96'h00000000017FFD0000000000;
            6'd13: bm_row_of = 96'h00000000017FFD0000000000;
            6'd14: bm_row_of = 96'h000555555555555555555000;
            6'd15: bm_row_of = 96'h005A9AAAAAAAAAAAAA96A400;
            6'd16: bm_row_of = 96'h005A9AAAAAAAAAAAAA96A400;
            6'd17: bm_row_of = 96'h005A9AAAAAAAAAAAAA96A400;
            6'd18: bm_row_of = 96'h0055556AAAAAAAAAA5555400;
            6'd19: bm_row_of = 96'h0055556AAAAAAAAAA5555400;
            6'd20: bm_row_of = 96'h005A9AAAAAAAAAAAAA96A400;
            6'd21: bm_row_of = 96'h005A9AAAAAAAAAAAAA96A400;
            6'd22: bm_row_of = 96'h005A9AAAAAAAAAAAAA96A400;
            6'd23: bm_row_of = 96'h000555555555555555555000;
            6'd24: bm_row_of = 96'h00000055017FFD0155000000;
            6'd25: bm_row_of = 96'h00000055017FFD0155000000;
            6'd26: bm_row_of = 96'h00000000557FFD5400000000;
            6'd27: bm_row_of = 96'h00000000057FFD5000000000;
            6'd28: bm_row_of = 96'h00000000057FFD5000000000;
            6'd29: bm_row_of = 96'h000000000155550000000000;
            6'd30: bm_row_of = 96'h000000000155550000000000;
            6'd31: bm_row_of = 96'h000000000155550000000000;
            6'd32: bm_row_of = 96'h00000000001FD50000000000;
            6'd33: bm_row_of = 96'h00000000001FD40000000000;
            6'd34: bm_row_of = 96'h00000000001FD40000000000;
            6'd35: bm_row_of = 96'h00000000015FD50000000000;
            6'd36: bm_row_of = 96'h00000000015FD50000000000;
            6'd37: bm_row_of = 96'h00000000015FD50000000000;
            6'd38: bm_row_of = 96'h0000000057FFFFF400000000;
            6'd39: bm_row_of = 96'h00000001FFF57FFD40000000;
            6'd40: bm_row_of = 96'h00000001FFF57FFD40000000;
            6'd41: bm_row_of = 96'h00000001FFC543FD40000000;
            6'd42: bm_row_of = 96'h000000000000000000000000;
            6'd43: bm_row_of = 96'h000000000000000000000000;
            6'd44: bm_row_of = 96'h000000000000000000000000;
            6'd45: bm_row_of = 96'h000000000000000000000000;
            6'd46: bm_row_of = 96'h000000000000000000000000;
            6'd47: bm_row_of = 96'h000000000000000000000000;
            default: bm_row_of = 96'h0;
            endcase
        end
    endfunction

    // ---- 内置 32x32 位图精灵（槽 0）-----------------------------------------
    // 槽宽高都等于 32 时，按掩码逐像素绘制（掩码 0=透明）。用于把"纯色方块"
    // 升级成真正的飞船图标；不影响挡板(120x32)、炮台(48x16)等其它尺寸。
    wire        bm_is  = (spr_tab[0][54:44] - spr_tab[0][65:55] == 11'd48) &&
                         (spr_tab[0][33:24] - spr_tab[0][43:34] == 10'd48);
    wire [9:0]  bm_dy_w = next_y_next - spr_tab[0][43:34];
    wire [95:0] bm_row_w = bm_row_of(bm_dy_w[5:0]);
    reg  [95:0] bm_row_r;
    always @(posedge clk) begin
        if (rst) bm_row_r <= 96'h0;
        else     bm_row_r <= bm_row_w;      // 与 yhit_r 同拍
    end
    wire [10:0] bm_dx = pixel_x - spr_tab[0][65:55];
    wire [1:0]  bm_px = bm_row_r[{bm_dx[5:0], 1'b0} +: 2];
    wire        bm_hit = bm_is && (bm_px != 2'b00);
    wire [23:0] bm_col = (bm_px == 2'b01) ? 24'h7A4A28 :
                         (bm_px == 2'b10) ? 24'hC89860 : 24'hFFE0A0;

    genvar i;
    generate
        for (i = 0; i < NSLOT; i = i + 1) begin : g_hit
            assign hit[i] = spr_tab[i][66] &&
                            (pixel_x >= spr_tab[i][65:55]) &&
                            (pixel_x <  spr_tab[i][54:44]) &&
                            yhit_r[i] &&
                            ((i != 0) || !bm_is || bm_hit);   // 槽0 32x32 → 按掩码
        end
    endgenerate

    // P2b: the flat grant-mask + OR tree from the first P2 attempt measured
    // 0.6 ns DEEPER on the pixel-domain render path (12 logic levels, -0.080 ns)
    // than what TD extracts from the plain priority loop, so the selection
    // stays a plain priority loop; only the edge precomputation is kept.
    // Lowest slot index still wins (the loop overwrites upwards).
    reg        found;
    reg [23:0] picked;
    integer k;

    always @(*) begin
        found  = 1'b0;
        picked = 24'h000000;
        for (k = NSLOT - 1; k >= 0; k = k - 1) begin
            if (hit[k]) begin
                found  = 1'b1;
                picked = (k == 0 && bm_is) ? bm_col : spr_tab[k][23:0];
            end
        end
    end

    // ---- brick layer --------------------------------------------------------
    // A 10x6 grid drawn procedurally: 60 bricks cost ~50 LUTs instead of 60
    // sprite slots. Colour is chosen by row so the field reads as stripes.
    wire [10:0] bdx = pixel_x - BRICK_X0;
    wire [ 9:0] bdy = next_y  - BRICK_Y0;
    wire        b_in_grid = (pixel_x >= BRICK_X0) &&
                            (bdx < BRICK_COLS * BRICK_W) &&
                            (next_y  >= BRICK_Y0) &&
                            (bdy < BRICK_ROWS * BRICK_H);
    wire [3:0]  b_col = bdx[10:7];      // 128-wide cells: shift, no divider
    wire [3:0]  b_row = bdy[9:5];       // 32-tall cells
    wire [5:0]  b_idx = {b_row, 3'b000} + {b_row, 1'b0} + b_col;   // row*10 as shifts
    wire        b_alive = b_in_grid && (b_idx < 60) && brick_mask[b_idx];

    reg [23:0] b_color;
    always @(*) begin
        case (b_row)
            4'd0: b_color = 24'hFF3030;
            4'd1: b_color = 24'hFF9020;
            4'd2: b_color = 24'hFFE020;
            4'd3: b_color = 24'h30C040;
            4'd4: b_color = 24'h3090FF;
            default: b_color = 24'hC040FF;
        endcase
    end

    // Render port: one entry per pixel clock while a line is being scanned.
    wire wr_en = (pixel_x < H_ACTIVE);

    always @(posedge clk) begin
        if (wr_en)
            // Proper RGB888 -> RGB565: taking the low 16 bits of a 24-bit
            // colour is NOT a conversion (green 0x20FF20 became 0xFF20 = yellow).
            // Sprites win over bricks; the ball and paddle must stay visible.
            // A black sprite still renders as 16'h0000 and stays transparent.
            ovl[{wr_sel, pixel_x[10:0]}] <= found     ? {picked[23:19], picked[15:10], picked[7:3]} :
                                             b_alive   ? {b_color[23:19], b_color[15:10], b_color[7:3]} :
                                             (tile_rgb != 24'h000000) ?
                                                         {tile_rgb[23:19], tile_rgb[15:10], tile_rgb[7:3]} :
                                                         16'h0000;
    end

    // ---- display port -------------------------------------------------------
    // Address x+1 so the RAM's one-cycle read latency lands on the pixel being
    // output in this cycle.
    reg [15:0] ovl_dout;

    always @(posedge clk) begin
        if (pixel_x < H_ACTIVE - 1)
            ovl_dout <= ovl[{rd_sel, pixel_x[10:0] + 11'd1}];
    end

    // One shallow mux; the pixel stream keeps its original latency.
    wire [23:0] ovl_rgb = { ovl_dout[15:11], ovl_dout[15:13], ovl_dout[10:5], ovl_dout[10:9], ovl_dout[4:0], ovl_dout[4:2] };
    assign rgb_out = (ovl_dout != 16'h0000) ? ovl_rgb : bg_rgb;

endmodule

`default_nettype wire