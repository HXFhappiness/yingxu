`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// yingxu_tile_layer  -  scrolling tile background
//
// 40 x 24 tiles of 32 x 32 pixels, which covers 1280 x 768 with wrapping. The
// map lives in BRAM (960 x 8 bit) and is filled from a small state machine at
// reset, so later a level can be loaded from the card instead without changing
// anything else.
//
// Patterns are generated from the tile index (no pattern ROM):
//   0  empty / transparent
//   1  dark starfield plate
//   2  single star
//   3  grid line
//   4  nebula block
//
// The module is evaluated on the render side of the sprite engine (once per
// pixel, writing the line buffer), never on the display path.
//------------------------------------------------------------------------------
module yingxu_tile_layer #(
    parameter integer H_ACTIVE = 1280,
    parameter integer V_ACTIVE = 720,
    parameter integer COLS     = 40,
    parameter integer ROWS     = 24
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [10:0] px,            // current pixel x
    input  wire [ 9:0] py,            // line being rendered (next line)
    input  wire [ 5:0] scroll_x,
    input  wire [ 5:0] scroll_y,

    output reg  [23:0] rgb            // 0x000000 = transparent
);

    // ---- tile map -----------------------------------------------------------
    reg [7:0] tmap [0:COLS*ROWS-1];

    reg [10:0] init_cnt;
    reg        init_done;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            init_cnt  <= 11'd0;
            init_done <= 1'b0;
        end
        else if (!init_done) begin
            // Sparse starfield. Bit tests instead of modulo: a modulo here
            // synthesises a divider and its delay broke the frame update path.
            tmap[init_cnt] <= (init_cnt[3:0] == 4'd3) ? 8'd2 :
                              (init_cnt[5:0] == 6'd21) ? 8'd4 : 8'd0;
            if (init_cnt == COLS*ROWS-1)
                init_done <= 1'b1;
            init_cnt <= init_cnt + 11'd1;
        end
    end

    // ---- scrolled world coordinates ----------------------------------------
    wire [11:0] wx = {1'b0, px} + {6'd0, scroll_x};
    wire [11:0] wy = {2'b00, py} + {6'd0, scroll_y};

    wire [5:0]  tx = wx[11:5];
    wire [5:0]  ty = wy[11:5];
    wire [4:0]  fx = wx[4:0];
    wire [4:0]  fy = wy[4:0];

    // Stage 1: wrap and register the tile coordinates. Doing the wrap, the
    // multiply and the BRAM address in one cycle was ~20 ns.
    reg [5:0] txw_r, tyw_r;
    reg [4:0] fx_r0, fy_r0;

    always @(posedge clk) begin
        txw_r <= (tx >= COLS) ? (tx - COLS) : tx;
        tyw_r <= (ty >= ROWS) ? (ty - ROWS) : ty;
        fx_r0 <= fx;
        fy_r0 <= fy;
    end

    // Stage 2: map address by shifts (40 = 32 + 8, so no multiplier).
    wire [10:0] map_addr = ({5'd0, tyw_r} << 5) + ({5'd0, tyw_r} << 3) + {5'd0, txw_r};

    reg [7:0] tile;
    always @(posedge clk) begin
        tile <= tmap[map_addr];
    end

    // ---- pattern generation (one cycle behind the map read) ----------------
    reg [4:0] fx_d, fy_d;
    always @(posedge clk) begin
        fx_d <= fx_r0;
        fy_d <= fy_r0;
    end

    always @(*) begin
        case (tile)
            8'd1: rgb = 24'h001030;                                  // plate
            8'd2: rgb = ((fx_d == 5'd16) && (fy_d == 5'd16)) ? 24'hFFFFFF : 24'h000000;
            8'd3: rgb = ((fx_d == 5'd0) || (fy_d == 5'd0)) ? 24'h205080 : 24'h000000;
            8'd4: rgb = ((fx_d[4:3] == 2'b00) && (fy_d[4:3] == 2'b00)) ? 24'h301040 : 24'h100020;
            default: rgb = 24'h000000;
        endcase
    end

endmodule

`default_nettype wire
