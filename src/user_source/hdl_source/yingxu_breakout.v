`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// yingxu_breakout  -  hardware Breakout game engine
//
// Runs once per video frame. The update is split over four short pipeline
// stages because the whole calculation in one cycle (adds, compares, brick
// index decode, sprite pushes) was ~16 ns deep and destroyed the timing budget.
// Latency is irrelevant here: one frame is 16 ms.
//
//   S_IDLE  integrate position, clamp against the walls, register the candidate
//   S_MOVE  paddle / brick / floor tests on the candidate position
//   S_TEST  commit position, velocity, brick mask; push the ball sprite
//   S_APPLY push the paddle sprite
//
// Playfield 1280x720, bricks 10x6 of 128x32 (power-of-two cells so the brick
// index is a shift, not a divider), ball 8x8, paddle 96x12 at y = 640.
//------------------------------------------------------------------------------
module yingxu_breakout #(
    parameter integer H_ACTIVE  = 1280,
    parameter integer V_ACTIVE  = 720,
    parameter integer BALL_W    = 8,
    parameter integer BALL_H    = 8,
    parameter integer PADDLE_W  = 96,
    parameter integer PADDLE_H  = 12,
    parameter integer PADDLE_Y  = 640,
    parameter integer BRICK_COLS = 10,
    parameter integer BRICK_ROWS = 6,
    parameter integer BRICK_W   = 128,
    parameter integer BRICK_H   = 32,
    parameter integer BRICK_X0  = 0,
    parameter integer BRICK_Y0  = 60
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        frame_tick,
    input  wire        enable,         // game only runs in game mode
    input  wire        key_left,
    input  wire        key_right,
    input  wire        restart,       // one pulse when entering game mode

    output reg         spr_we,
    output reg  [ 3:0] spr_slot,
    output reg         spr_en,
    output reg  [10:0] spr_x,
    output reg  [ 9:0] spr_y,
    output reg  [ 6:0] spr_w,
    output reg  [ 5:0] spr_h,
    output reg  [23:0] spr_c,

    output wire [59:0] brick_mask,
    output wire        game_over,

    // sound events (one-cycle pulses)
    output wire        o_ev_hit,
    output wire        o_ev_paddle,
    output wire        o_ev_lose,
    output wire        o_ev_win
);

    localparam integer BALL_START_X = 620;
    localparam integer BALL_START_Y = 400;

    localparam [2:0] S_IDLE = 3'd0, S_MOVE = 3'd1, S_TEST = 3'd2, S_APPLY = 3'd3,
                     S_HEART = 3'd4, S_BANNER = 3'd5;

    reg [2:0]  st;
    reg [10:0] ball_x, ball_y;
    reg signed [4:0] vx, vy;
    reg [10:0] paddle_x;
    reg [59:0] bricks;
    reg [1:0]  lives;          // 3 lives, shown as hearts at the bottom
    reg [1:0]  game_state;     // 0 = playing, 1 = lost, 2 = won
    reg [1:0]  hcnt;           // heart sprite index

    reg [10:0] nx_r, paddle_r;
    reg [9:0]  ny_r;
    reg        wall_hit_r, top_hit_r, paddle_hit_r, brick_hit_r, floor_hit_r;
    reg [5:0]  brick_idx_r;

    reg gs_d;
    always @(posedge clk or posedge rst) begin
        if (rst) gs_d <= 1'b0;
        else     gs_d <= (game_state != 2'd0);
    end

    assign o_ev_hit    = (st == S_TEST) && brick_hit_r;
    assign o_ev_paddle = (st == S_TEST) && paddle_hit_r;
    assign o_ev_win    = (game_state == 2'd2) && !gs_d;
    assign o_ev_lose   = (game_state == 2'd1) && !gs_d;

    assign brick_mask = bricks;
    assign game_over  = (bricks == 60'd0);

    wire signed [12:0] nx0 = $signed({1'b0, ball_x}) + $signed(vx);
    wire signed [12:0] ny0 = $signed({1'b0, ball_y}) + $signed(vy);

    wire [10:0] cx = nx_r + (BALL_W / 2);
    wire [9:0]  cy = ny_r + (BALL_H / 2);
    wire        in_grid = (cx >= BRICK_X0) && (cy >= BRICK_Y0) &&
                          ((cx - BRICK_X0) < BRICK_COLS * BRICK_W) &&
                          ((cy - BRICK_Y0) < BRICK_ROWS * BRICK_H);
    // row * BRICK_COLS as shifts: a literal multiply synthesised a MULT18 here
    // and this path (ny_r -> brick_idx_r) was the worst in the pixel domain.
    wire [5:0]  brow = (cy - BRICK_Y0) >> 5;
    wire [5:0]  bcol = (cx - BRICK_X0) >> 7;
    wire [5:0]  bidx = {brow, 3'b000} + {brow, 1'b0} + bcol;   // row*8 + row*2 + col

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st           <= S_IDLE;
            ball_x       <= BALL_START_X[10:0];
            ball_y       <= BALL_START_Y[9:0];
            vx           <= 5'sd4;
            vy           <= 5'sd3;
            paddle_x     <= (H_ACTIVE - PADDLE_W) / 2;
            bricks       <= {60{1'b1}};
            lives        <= 2'd3;
            game_state   <= 2'd0;
            hcnt         <= 2'd0;
            nx_r         <= 11'd0;
            ny_r         <= 10'd0;
            paddle_r     <= 11'd0;
            wall_hit_r   <= 1'b0;
            top_hit_r    <= 1'b0;
            paddle_hit_r <= 1'b0;
            brick_hit_r  <= 1'b0;
            floor_hit_r  <= 1'b0;
            brick_idx_r  <= 6'd0;
            spr_we       <= 1'b0;
            spr_slot     <= 4'd0;
            spr_en       <= 1'b0;
            spr_x        <= 11'd0;
            spr_y        <= 10'd0;
            spr_w        <= 7'd0;
            spr_h        <= 6'd0;
            spr_c        <= 24'h000000;
        end
        else begin
            spr_we <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (restart) begin
                        ball_x   <= BALL_START_X[10:0];
                        ball_y   <= BALL_START_Y[9:0];
                        vx       <= 5'sd4;
                        vy       <= 5'sd3;
                        paddle_x <= (H_ACTIVE - PADDLE_W) / 2;
                        paddle_r <= (H_ACTIVE - PADDLE_W) / 2;
                        bricks     <= {60{1'b1}};
                        lives      <= 2'd3;
                        game_state <= 2'd0;
                    end
                    else if (game_state != 2'd0 && (key_left || key_right)) begin
                        // any key restarts after a win or a loss
                        ball_x     <= BALL_START_X[10:0];
                        ball_y     <= BALL_START_Y[9:0];
                        vx         <= 5'sd4;
                        vy         <= 5'sd3;
                        paddle_x   <= (H_ACTIVE - PADDLE_W) / 2;
                        paddle_r   <= (H_ACTIVE - PADDLE_W) / 2;
                        bricks     <= {60{1'b1}};
                        lives      <= 2'd3;
                        game_state <= 2'd0;
                    end
                    else if (frame_tick && enable && game_state == 2'd0) begin
                        if (key_left && paddle_x > 11'd0)
                            paddle_r <= paddle_x - 11'd8;
                        else if (key_right && paddle_x < H_ACTIVE - PADDLE_W)
                            paddle_r <= paddle_x + 11'd8;
                        else
                            paddle_r <= paddle_x;

                        if (nx0 < 0) begin
                            nx_r       <= 11'd0;
                            wall_hit_r <= 1'b1;
                        end
                        else if (nx0 > H_ACTIVE - BALL_W) begin
                            nx_r       <= H_ACTIVE - BALL_W;
                            wall_hit_r <= 1'b1;
                        end
                        else begin
                            nx_r       <= nx0[10:0];
                            wall_hit_r <= 1'b0;
                        end

                        if (ny0 < 0) begin
                            ny_r      <= 10'd0;
                            top_hit_r <= 1'b1;
                        end
                        else begin
                            ny_r      <= ny0[9:0];
                            top_hit_r <= 1'b0;
                        end

                        floor_hit_r <= (ny0 > V_ACTIVE);
                        st <= S_MOVE;
                    end
                end

                S_MOVE: begin
                    paddle_hit_r <= (vy > 0) &&
                                    ((ny_r + BALL_H) >= PADDLE_Y) &&
                                    ((ny_r + BALL_H) <= PADDLE_Y + 6) &&
                                    ((nx_r + BALL_W) > paddle_r) &&
                                    (nx_r < (paddle_r + PADDLE_W));

                    brick_hit_r <= in_grid && bricks[bidx];
                    brick_idx_r <= in_grid ? bidx : 6'd0;
                    st <= S_TEST;
                end

                S_TEST: begin
                    paddle_x <= paddle_r;

                    if (floor_hit_r) begin
                        ball_x <= BALL_START_X[10:0];
                        ball_y <= BALL_START_Y[9:0];
                        vx     <= 5'sd4;
                        vy     <= 5'sd3;
                        if (lives == 2'd0)
                            game_state <= 2'd1;      // out of lives
                        else
                            lives <= lives - 2'd1;
                    end
                    else begin
                        ball_x <= nx_r;
                        ball_y <= ny_r;

                        if (wall_hit_r)   vx <= -vx;
                        if (top_hit_r)    vy <= -vy;
                        if (paddle_hit_r) vy <= -vy;
                        if (brick_hit_r) begin
                            vy <= -vy;
                            bricks[brick_idx_r] <= 1'b0;
                            // Win when clearing THIS brick empties the field.
                            // Comparing against a fixed pattern only worked when
                            // brick 0 happened to be the last one left.
                            if ((bricks & ~(60'd1 << brick_idx_r)) == 60'd0)
                                game_state <= 2'd2;
                        end
                    end

                    spr_we <= enable;
                    spr_slot <= 4'd0;
                    spr_en   <= 1'b1;
                    spr_x    <= floor_hit_r ? BALL_START_X[10:0] : nx_r;
                    spr_y    <= floor_hit_r ? BALL_START_Y[9:0]  : ny_r;
                    spr_w    <= BALL_W[6:0];
                    spr_h    <= BALL_H[5:0];
                    spr_c    <= 24'hFFFFFF;
                    st <= S_APPLY;
                end

                S_APPLY: begin
                    spr_we <= enable;
                    spr_slot <= 4'd1;
                    spr_en   <= 1'b1;
                    spr_x    <= paddle_r;
                    spr_y    <= PADDLE_Y[9:0];
                    spr_w    <= PADDLE_W[6:0];
                    spr_h    <= PADDLE_H[5:0];
                    spr_c    <= 24'h30FF30;
                    hcnt     <= 2'd0;
                    st <= S_HEART;
                end

                // Three life markers along the bottom edge.
                S_HEART: begin
                    spr_we <= enable;
                    spr_slot <= 4'd12 + {2'b00, hcnt};
                    spr_en   <= (hcnt < lives);
                    spr_x    <= 11'd24 + {5'd0, hcnt, 5'd0};
                    spr_y    <= 10'd688;
                    spr_w    <= 7'd24;
                    spr_h    <= 6'd16;
                    spr_c    <= 24'hFF4040;
                    if (hcnt == 2'd2) st <= S_BANNER;
                    else              hcnt <= hcnt + 2'd1;
                end

                // Full-width status banner on win or loss.
                S_BANNER: begin
                    spr_we <= enable;
                    spr_slot <= 4'd15;
                    spr_en   <= (game_state != 2'd0);
                    spr_x    <= 11'd576;
                    spr_y    <= 10'd300;
                    spr_w    <= 7'd127;
                    spr_h    <= 6'd60;
                    spr_c    <= (game_state == 2'd2) ? 24'h30FF30 : 24'hFF3030;
                    st <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire