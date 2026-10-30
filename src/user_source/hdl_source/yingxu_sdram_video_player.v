`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// yingxu_sdram_video_player
//   Reads the stored RGB565 frame from SDRAM (RD2) and drives the pixel stream
//   in step with the HDMI timing, bypassing the double framebuffer.
//
//   One SDRAM word = 2 pixels: [31:16] left, [15:0] right.
//   A word is consumed at every ODD pixel_x of the active area, i.e. exactly
//   once per pixel pair. The last odd pixel of a line (x = H_ACTIVE-1) loads
//   the first pair of the next line, so the stream wraps lines naturally.
//
//   The read pointer is reloaded once per frame during vertical blanking and
//   the first word is prefetched there. Per-line re-addressing was tried and
//   rejected: the read port cannot refill during horizontal blanking and the
//   HDMI output loses lock.
//------------------------------------------------------------------------------
module yingxu_sdram_video_player #(
    parameter integer H_ACTIVE     = 1280,
    parameter integer V_ACTIVE     = 720,
    parameter integer H_TOTAL      = 1650,
    parameter integer V_TOTAL      = 750,
    parameter [20:0]  SCRATCH_ADDR = 21'h100000
)(
    input  wire        pixel_clk,
    input  wire        rst,

    input  wire [10:0] pixel_x,
    input  wire [ 9:0] pixel_y,
    input  wire        pixel_active,
    input  wire        loaded,

    input  wire [31:0] rd2_data,
    input  wire        rd2_empty,
    output reg         rd2_en,
    output wire [20:0] rd2_addr,
    output wire [20:0] rd2_max_addr,
    output wire [8:0]  rd2_len,
    output reg         rd2_load,

    input  wire [ 3:0] fade_dark,    // 0 = normal, 15 = black (fade in/out)
    input  wire        bright_en,    // 1 = add +24 to every channel
    input  wire        contrast_en,  // 1 = x1.5 contrast
    input  wire [20:0] i_base,        // frame buffer base (double buffering)
    output reg  [23:0] rgb_out,
    output wire        frame_tick
);

    localparam integer FRAME_WORDS = (H_ACTIVE / 2) * V_ACTIVE;

    assign rd2_addr     = i_base;
    assign rd2_max_addr = i_base + FRAME_WORDS;
    assign rd2_len      = 9'd128;
    assign frame_tick   = (pixel_x == 11'd0) && (pixel_y == 10'd0);

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
    reg        loading;
    reg [2:0]  load_cnt;
    reg [3:0]  boot_cnt;

    wire vb_start     = (pixel_x == 11'd0) && (pixel_y == V_ACTIVE);
    wire pair_advance = pixel_active && pixel_x[0];

    wire [15:0] pix = pixel_x[0] ? pair[15:0] : pair[31:16];
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
            load_cnt <= 3'd0;
            rd2_en   <= 1'b0;
            rd2_load <= 1'b1;
            boot_cnt <= 4'd8;
            rgb_out  <= 24'h000000;
        fade_rgb <= 24'h000000;
        r5_d <= 5'd0; g6_d <= 6'd0; b5_d <= 5'd0;
        r5_o <= 5'd0; g6_o <= 6'd0; b5_o <= 5'd0;
        r5_c <= 9'sd0; g6_c <= 10'sd0; b5_c <= 9'sd0;
        end
        else begin
            rd2_en <= 1'b0;

            if (boot_cnt != 4'd0)
                boot_cnt <= boot_cnt - 4'd1;

            if (!loaded) begin
                // Loader owns the SDRAM: stay off the read port completely, and
                // only issue the initial LOAD pulse (a held LOAD would keep the
                // read FIFO empty and starve the loader in the arbiter).
                loading  <= 1'b0;
                load_cnt <= 3'd0;
                rd2_load <= (boot_cnt != 4'd0);
                primed   <= 1'b0;
            end
            else if (vb_start) begin
                loading  <= 1'b1;
                load_cnt <= 3'd0;
                rd2_load <= 1'b1;
                primed   <= 1'b0;
            end
            else if (loading) begin
                if (load_cnt == 3'd7) begin
                    loading  <= 1'b0;
                    rd2_load <= 1'b0;
                end
                else begin
                    load_cnt <= load_cnt + 3'd1;
                end
            end
            // Fetching must never be skipped: dropping one position shifts the rest
            // of the line by two pixels until the next re-alignment, which shows up
            // as an occasional horizontal jitter.
            else if (!primed) begin
                rd2_en <= 1'b1;
                if (!rd2_empty) begin
                    pair   <= rd2_data;
                    primed <= 1'b1;
                end
            end
            else if (pair_advance) begin
                // Keep the read pointer moving so the stream never drifts, but
                // only refresh the pixel data when the FIFO really holds a word.
                // Holding the previous pair for one pixel is invisible; taking
                // garbage from an empty FIFO shows up as random coloured dots.
                rd2_en <= 1'b1;
                if (!rd2_empty)
                    pair <= rd2_data;
            end

            // Fade by a saturating subtract rather than a variable shift: a
            // 0..8 shifter is four mux levels deep and pushed the pixel domain
            // negative, while one subtract plus a clamp is only a couple of
            // levels. fade_dark * 16 gives the 0..240 range.
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

            rgb_out <= (pixel_active && primed) ?
                       { r5_o, r5_o[4:2], g6_o, g6_o[5:4], b5_o, b5_o[4:2] } :
                       24'h000000;
        end
    end

endmodule

`default_nettype wire