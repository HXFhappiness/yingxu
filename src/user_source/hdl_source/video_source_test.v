`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// YingXu: video_source_test  (V0.4C-P0)
//
// Raster generator + pixel source. Produces the 1280x720 @ 59.3 Hz scan
// (HDMI user/valid/last sidebands) and multiplexes the picture coming back
// from the sprite engine (I_fb_rgb) onto the AXI-style stream.
//
// P0 cleanup (2026-10-25): the debug OSD ("YINGXU / X:xxxx Y:xxxx" panel) and
// its support blocks (yingxu_overlay, yingxu_status_bcd, yingxu_font8x16_lite
// via osd_lite, yingxu_pattern fallback) are gone. The overlay stage had been
// bypassed since V0.4C already (P_overlay_rgb <= S_base_rgb), and I_fb_enable
// was tied high at the only instantiation, so the pattern generator was dead
// logic. The two pipeline stages are kept: they hold the pixel path slack and
// keep the sidebands aligned with the data stream.
//------------------------------------------------------------------------------
module video_source_test #(
    parameter       HTOTAL      = 1650,
    parameter       HACTIVE     = 1280,
    parameter       HFP         = 110,
    parameter       HSA         = 40,
    parameter       HBP         = 220,
    parameter       VTOTAL      = 750,
    parameter       VACTIVE     = 720,
    parameter       VFP         = 5,
    parameter       VSA         = 5,
    parameter       VBP         = 20
) (
    input   wire                    I_clk,          // HDMI pixel clock
    input   wire                    I_rst,          // pixel-domain reset

    output  wire                    O_video_user,   // frame-start sideband
    output  wire                    O_video_valid,
    output  wire                    O_video_last,   // last pixel of an active line
    output  wire    [  23: 0]       O_video_data,   // RGB888 pixel
    input   wire                    I_video_ready,  // HDMI core ready (informational)

    // Export raster coordinates to the display pipeline.
    output  wire    [  10: 0]       O_pixel_x,
    output  wire    [   9: 0]       O_pixel_y,
    output  wire                    O_pixel_active,

    // Picture source (already composited: background + sprites).
    input   wire    [  23: 0]       I_fb_rgb
);

    reg   [  10: 0]       S_x;            // 0~1649
    reg   [   9: 0]       S_y;            // 0~749

    wire                            S_active;       // inside 1280x720
    wire                            S_frame_tick;   // first pixel of the frame

    // Two-stage pixel pipeline: data and sidebands take the same latency.
    reg                             P_active;
    reg                             P_user;
    reg                             P_last;
    reg [23:0]                      P_rgb;

    reg                             Q_active;
    reg                             Q_user;
    reg                             Q_last;
    reg [23:0]                      Q_rgb;

    // ---- S_x / S_y: free-running video timing counters ----
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            S_x     <= 11'd0;
            S_y     <= 10'd0;
        end
        else begin
            if (S_x == HTOTAL - 1) begin
                S_x <= 11'd0;
                if (S_y == VTOTAL - 1)
                    S_y <= 10'd0;
                else
                    S_y <= S_y + 1'b1;
            end
            else begin
                S_x <= S_x + 1'b1;
            end
        end
    end

    assign S_active     = (S_x < HACTIVE) && (S_y < VACTIVE);
    assign S_frame_tick = (S_x == 11'd0) && (S_y == 10'd0);

    assign O_pixel_x      = S_x;
    assign O_pixel_y      = S_y;
    assign O_pixel_active = S_active;

    // -------------------------------------------------------------------------
    // Pipeline stage 1.
    // -------------------------------------------------------------------------
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            P_rgb    <= 24'h000000;
            P_active <= 1'b0;
            P_user   <= 1'b0;
            P_last   <= 1'b0;
        end
        else begin
            P_rgb    <= I_fb_rgb;
            P_active <= S_active;
            P_user   <= S_frame_tick;
            P_last   <= (S_x == HACTIVE - 1) && (S_y < VACTIVE);
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline stage 2: HDMI sidebands and data leave together.
    // -------------------------------------------------------------------------
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            Q_rgb    <= 24'h000000;
            Q_active <= 1'b0;
            Q_user   <= 1'b0;
            Q_last   <= 1'b0;
        end
        else begin
            Q_rgb    <= P_rgb;
            Q_active <= P_active;
            Q_user   <= P_user;
            Q_last   <= P_last;
        end
    end

    assign O_video_valid = Q_active;
    assign O_video_user  = Q_user;
    assign O_video_last  = Q_last;
    assign O_video_data  = Q_rgb;

    // READY is a free-running acknowledgement in this design; nothing stalls.
    wire _unused_ready = I_video_ready;

    // Porch parameters are consumed via HTOTAL/VTOTAL already.
    wire [31:0] _unused_timing = HFP + HSA + HBP + VFP + VSA + VBP;

endmodule

`default_nettype wire
