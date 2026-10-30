`timescale 1ns / 1ps
`default_nettype none

module yingxu_overlay #(
    parameter H_ACTIVE = 1280,
    parameter V_ACTIVE = 720
) (
    input  wire          clk,
    input  wire          rst,
    input  wire [10:0]   pixel_x,
    input  wire [ 9:0]   pixel_y,
    input  wire          pixel_active,
    input  wire          frame_tick,
    input  wire [23:0]   bg_rgb,

    input  wire          key0_press,
    input  wire          key1_press,
    input  wire          key2_press,

    output wire [10:0]   status_box_x,
    output wire [ 9:0]   status_box_y,
    output wire          status_mode_vertical,
    output reg  [23:0]   rgb_out
);

    localparam [23:0] C_ORANGE = 24'hFF8000;
    localparam [23:0] C_CYAN   = 24'h00FFFF;
    localparam [23:0] C_YELLOW = 24'hFFFF00;
    localparam [23:0] C_WHITE  = 24'hFFFFFF;
    localparam [23:0] C_BLACK  = 24'h000000;

    localparam [10:0] SOLID_X0 = 11'd40;
    localparam [ 9:0] SOLID_Y0 = 10'd40;
    localparam [10:0] SOLID_W  = 11'd180;
    localparam [ 9:0] SOLID_H  = 10'd80;

    localparam [10:0] FRAME_X0 = 11'd1020;
    localparam [ 9:0] FRAME_Y0 = 10'd40;
    localparam [10:0] FRAME_W  = 11'd220;
    localparam [ 9:0] FRAME_H  = 10'd100;
    localparam [ 5:0] FRAME_T  = 6'd6;

    localparam [10:0] BOX_SIZE  = 11'd50;
    localparam [10:0] BOX_STEP  = 11'd24;
    localparam [10:0] BOX_MIN_X = 11'd20;
    localparam [10:0] BOX_MAX_X = 11'd1210;
    localparam [ 9:0] BOX_MIN_Y = 10'd180;
    localparam [ 9:0] BOX_MAX_Y = 10'd650;

    (* mark_debug = "true" *) reg [10:0] box_x;
    (* mark_debug = "true" *) reg [ 9:0] box_y;
    (* mark_debug = "true" *) reg        mode_vertical;

    reg pending_key0;
    reg pending_key1;
    reg pending_key2;

    wire solid_hit;
    wire frame_outer;
    wire frame_inner;
    wire frame_hit;
    wire box_outer_hit;
    wire box_inner_hit;
    wire [23:0] mode_frame_color;

    assign mode_frame_color = mode_vertical ? C_YELLOW : C_CYAN;

    // V0.2D-R2：只读状态输出，供 OSD 使用；不改变交互控制行为。
    assign status_box_x         = box_x;
    assign status_box_y         = box_y;
    assign status_mode_vertical = mode_vertical;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            box_x         <= 11'd615;
            box_y         <= 10'd540;
            mode_vertical <= 1'b0;
            pending_key0  <= 1'b0;
            pending_key1  <= 1'b0;
            pending_key2  <= 1'b0;
        end else begin
            if (key0_press) pending_key0 <= 1'b1;
            if (key1_press) pending_key1 <= 1'b1;
            if (key2_press) pending_key2 <= 1'b1;

            if (frame_tick) begin
                if (pending_key2 || key2_press)
                    mode_vertical <= ~mode_vertical;

                if ((pending_key0 || key0_press) ^ (pending_key1 || key1_press)) begin
                    if (!mode_vertical) begin
                        if (pending_key0 || key0_press) begin
                            if (box_x <= BOX_MIN_X + BOX_STEP)
                                box_x <= BOX_MIN_X;
                            else
                                box_x <= box_x - BOX_STEP;
                        end else begin
                            if (box_x >= BOX_MAX_X - BOX_STEP)
                                box_x <= BOX_MAX_X;
                            else
                                box_x <= box_x + BOX_STEP;
                        end
                    end else begin
                        if (pending_key0 || key0_press) begin
                            if (box_y <= BOX_MIN_Y + 10'd24)
                                box_y <= BOX_MIN_Y;
                            else
                                box_y <= box_y - 10'd24;
                        end else begin
                            if (box_y >= BOX_MAX_Y - 10'd24)
                                box_y <= BOX_MAX_Y;
                            else
                                box_y <= box_y + 10'd24;
                        end
                    end
                end

                pending_key0 <= 1'b0;
                pending_key1 <= 1'b0;
                pending_key2 <= 1'b0;
            end
        end
    end

    assign solid_hit =
        pixel_active &&
        (pixel_x >= SOLID_X0) &&
        (pixel_x <  SOLID_X0 + SOLID_W) &&
        (pixel_y >= SOLID_Y0) &&
        (pixel_y <  SOLID_Y0 + SOLID_H);

    assign frame_outer =
        pixel_active &&
        (pixel_x >= FRAME_X0) &&
        (pixel_x <  FRAME_X0 + FRAME_W) &&
        (pixel_y >= FRAME_Y0) &&
        (pixel_y <  FRAME_Y0 + FRAME_H);

    assign frame_inner =
        pixel_active &&
        (pixel_x >= FRAME_X0 + FRAME_T) &&
        (pixel_x <  FRAME_X0 + FRAME_W - FRAME_T) &&
        (pixel_y >= FRAME_Y0 + FRAME_T) &&
        (pixel_y <  FRAME_Y0 + FRAME_H - FRAME_T);

    assign frame_hit = frame_outer && !frame_inner;

    assign box_outer_hit =
        pixel_active &&
        (pixel_x >= box_x) &&
        (pixel_x <  box_x + BOX_SIZE) &&
        (pixel_y >= box_y) &&
        (pixel_y <  box_y + 10'd50);

    assign box_inner_hit =
        pixel_active &&
        (pixel_x >= box_x + 11'd4) &&
        (pixel_x <  box_x + BOX_SIZE - 11'd4) &&
        (pixel_y >= box_y + 10'd4) &&
        (pixel_y <  box_y + 10'd46);

    always @(*) begin
        rgb_out = bg_rgb;

        if (solid_hit)
            rgb_out = C_ORANGE;

        if (frame_hit)
            rgb_out = mode_frame_color;

        if (box_outer_hit)
            rgb_out = C_BLACK;

        if (box_inner_hit)
            rgb_out = C_WHITE;
    end

endmodule

`default_nettype wire
