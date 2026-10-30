`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// yingxu_invaders  v3  -  three staggered squadrons flying left to right
//
// The 12 enemies are 3 squads of 4 (one per row). Each squad is one row with
// its own X origin, its own speed and its own fire interval:
//
//   squad 0 (red)    enters at wave start, 2 px/frame, fires every ~90 frames
//   squad 1 (orange) enters ~3.3 s later,  3 px/frame, ~70 frames
//   squad 2 (purple) enters ~6.6 s later,  4 px/frame, ~50 frames
//
// A squad streams in from the left edge, crosses the screen and re-enters from
// the left (wrap). Speeds and fire rates scale with the wave number. Clearing
// all 12 enemies starts the next wave. The player has 3 lives with a blinking
// invulnerability window; losing all lives or getting overrun ends the game.
//
// Slot budget (16): 0 player | 1 player bullet | 2..13 enemies (row-major)
//                   14/15 enemy bullets | 15 doubles as the game-over banner.
//------------------------------------------------------------------------------
module yingxu_invaders #(
    parameter integer H_ACTIVE  = 1280,
    parameter integer V_ACTIVE  = 720,
    parameter integer PLAYER_W  = 48,
    parameter integer PLAYER_H  = 48,
    parameter integer PLAYER_Y  = 640,
    parameter integer ENEMY_W   = 96,
    parameter integer ENEMY_H   = 48,
    parameter integer COLS      = 4,
    parameter integer ROWS      = 3,
    parameter integer SPACE_X   = 128,
    parameter integer ROW_Y0    = 120,
    parameter integer ROW_PITCH = 64,
    parameter integer ENTRY_FRAMES = 180   // ~3.0 s between squadrons
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        frame_tick,
    input  wire        enable,
    input  wire        restart,
    input  wire        key_left,
    input  wire        key_right,

    output reg         spr_we,
    output reg  [ 3:0] spr_slot,
    output reg         spr_en,
    output reg  [10:0] spr_x,
    output reg  [ 9:0] spr_y,
    output reg  [ 6:0] spr_w,
    output reg  [ 5:0] spr_h,
    output reg  [23:0] spr_c,

    output wire [ 3:0] wave,
    output wire [ 1:0] lives,

    output reg         o_ev_hit,
    output reg         o_ev_lose,
    output reg         o_ev_win,

    output wire        lost
);

    // ---- player -------------------------------------------------------------
    reg [10:0] px;
    reg [10:0] bx, bcy;         // player bullet x / centred y
    reg [ 9:0] by;
    reg        b_active;
    reg [ 1:0] lives_r;
    reg [ 6:0] inv;             // invulnerability frames after a hit
    reg [ 5:0] gun_timer;       // player fire cadence

    // ---- squads -------------------------------------------------------------
    reg signed [12:0] ex0, ex1, ex2;          // per-squad X origin
    reg [ 3:0]  sp0, sp1, sp2;                // per-squad speed (px/frame)
    reg [ 2:0]  sq_active;                    // one bit per squad
    reg [11:0]  entry_cnt;                    // frames since the wave started
    reg [11:0]  emask;                        // {row, col} alive bits
    reg [ 3:0]  wave_r;

    // per-squad fire cadence
    reg [ 7:0]  ft0, ft1, ft2;                // frames between shots
    reg [ 7:0]  ft0c, ft1c, ft2c;             // countdowns
    reg [ 1:0]  fc0, fc1, fc2;                // rotating fire column per squad

    // ---- enemy bullets (2 shared slots) -------------------------------------
    reg        e1a, e2a;
    reg [10:0] e1x, e2x;
    reg [ 9:0] e1y, e2y;

    reg        st;              // game over
    reg [7:0]  wave_dly;        // 清空后到下一波的等待帧数
    reg [ 3:0] wr_idx;

    assign wave  = wave_r;
    assign lives = lives_r;
    assign lost  = st;

    // ---- difficulty helpers -------------------------------------------------
    function [3:0] speed_add(input [3:0] w);        // +0..+3 with the wave
        begin
            speed_add = (w <= 4'd1) ? 4'd0 :
                        (w == 4'd2) ? 4'd1 :
                        (w == 4'd3) ? 4'd2 : 4'd3;
        end
    endfunction

    function [7:0] fire_iv(input [7:0] base, input [3:0] w);  // shrink, floor /2
        reg [7:0] v;
        begin
            v = base;
            if (w > 4'd1) v = base - ((w - 4'd1) << 3);
            fire_iv = (v < (base >> 1)) ? (base >> 1) : v;
        end
    endfunction

    // row Y tops (fixed lanes)
    localparam [9:0] RY0 = ROW_Y0[9:0];
    localparam [9:0] RY1 = ROW_Y0[9:0] + ROW_PITCH[9:0];
    localparam [9:0] RY2 = ROW_Y0[9:0] + 2*ROW_PITCH[9:0];

    // ---- player bullet vs enemies ------------------------------------------
    // One row band is evaluated per bullet position; bands are disjoint.
    // 子弹占 [by, by+BULLET_H)，与敌机行 [RY, RY+ENEMY_H) 有交叠即算同排
    wire [9:0] bcy_t = by;
    wire [9:0] bcy_b = by + 10'd12;

    wire in_r0 = (bcy_b > RY0) && (bcy_t < RY0 + ENEMY_H[9:0]);
    wire in_r1 = (bcy_b > RY1) && (bcy_t < RY1 + ENEMY_H[9:0]);
    wire in_r2 = (bcy_b > RY2) && (bcy_t < RY2 + ENEMY_H[9:0]);

    // ---- player bullet vs enemies ------------------------------------------
    // One row band is evaluated per bullet position; bands are disjoint.
    // P3-lite: because the bands cannot overlap, at most one squad is ever a
    // hit candidate for a given bullet y. Select that squad's X origin first
    // and run ONE subtract + range test, instead of three of each. Results are
    // bit-identical to the per-squad version (hit0/hit1/hit2 folded into
    // in_band && sq_on && in_range; hit_idx keeps the {row, d[7]} encoding).
    wire [1:0] band = in_r0 ? 2'd0 : in_r1 ? 2'd1 : 2'd2;

    wire signed [12:0] ex_band = (band == 2'd0) ? ex0 :
                                 (band == 2'd1) ? ex1 : ex2;
    wire signed [13:0] d = $signed({3'd0, bx}) - $signed(ex_band);

    wire in_band  = in_r0 || in_r1 || in_r2;
    wire sq_on    = (band == 2'd0) ? sq_active[0] :
                    (band == 2'd1) ? sq_active[1] : sq_active[2];
    wire in_range = (d >= 0) && (d < 2*SPACE_X) && (d[6:0] < ENEMY_W[6:0]);   // 每排只有 2 架

    wire [2:0] hit_idx = {band, d[7]};      // band(2)+col(1) = 3bit -> emask[0..5] (每排 2 架)
    wire       b_hit_now = b_active && in_band && sq_on && in_range && emask[hit_idx];
    wire [11:0] emask_after = emask & ~(12'd1 << hit_idx);
    wire        waveup_now = b_hit_now && (emask_after == 12'd0);

    // ---- enemy bullet vs player --------------------------------------------
    wire p1_hit = e1a && (inv == 7'd0) &&
                  (e1x + 11'd4 > px) && (e1x < px + PLAYER_W) &&
                  (e1y + 10'd12 > PLAYER_Y) && (e1y < PLAYER_Y + PLAYER_H);
    wire p2_hit = e2a && (inv == 7'd0) &&
                  (e2x + 11'd4 > px) && (e2x < px + PLAYER_W) &&
                  (e2y + 10'd12 > PLAYER_Y) && (e2y < PLAYER_Y + PLAYER_H);
    wire player_hit = p1_hit || p2_hit;

    // squad r spawn position (from its rotating column)
    wire [10:0] sx0 = ex0[10:0] + (fc0[0] << 7) + (ENEMY_W / 2);
    wire [10:0] sx1 = ex1[10:0] + (fc1[0] << 7) + (ENEMY_W / 2);
    wire [10:0] sx2 = ex2[10:0] + (fc2[0] << 7) + (ENEMY_W / 2);
    wire [ 9:0] sy0 = RY0 + (ENEMY_H / 2);
    wire [ 9:0] sy1 = RY1 + (ENEMY_H / 2);
    wire [ 9:0] sy2 = RY2 + (ENEMY_H / 2);

    // True spawn X must be on-screen: a squad wrapping at negative X would
    // otherwise fire bullets that materialise in mid-screen.
    wire signed [13:0] sx0_t = $signed(ex0) + $signed({6'd0, fc0[0], 7'd0}) + 14'sd48;
    wire signed [13:0] sx1_t = $signed(ex1) + $signed({6'd0, fc1[0], 7'd0}) + 14'sd48;
    wire signed [13:0] sx2_t = $signed(ex2) + $signed({6'd0, fc2[0], 7'd0}) + 14'sd48;
    wire spawn0_ok = (sx0_t >= 14'sd48) && (sx0_t < 14'sd1232);   // 完全在屏内才开火
    wire spawn1_ok = (sx1_t >= 14'sd48) && (sx1_t < 14'sd1232);   // 完全在屏内才开火
    wire spawn2_ok = (sx2_t >= 14'sd48) && (sx2_t < 14'sd1232);   // 完全在屏内才开火

    // Render X for the sprite push, with left-edge clipping. The old code fed
    // the wrapped low 11 bits of a negative origin to the engine, so a squad
    // was invisible for its whole re-entry window while its hitbox stayed at
    // the true position - bullets killed enemies nobody could see.
    wire [3:0]  e_i = wr_idx - 4'd2;              // enemy index 0..5 (2 per squad)
    wire signed [13:0] e_true = (e_i[2:1] == 2'd0) ? ($signed(ex0) + $signed({6'd0, e_i[0], 7'd0})) :
                                (e_i[2:1] == 2'd1) ? ($signed(ex1) + $signed({6'd0, e_i[0], 7'd0})) :
                                                     ($signed(ex2) + $signed({6'd0, e_i[0], 7'd0}));
    wire e_vis = (e_true > -14'sd96) && (e_true < 14'sd1280);
    wire [10:0] e_drawx = (e_true < 0) ? 11'd0 : e_true[10:0];
    wire signed [13:0] w_full_s = 14'sd96 + e_true;
    wire [ 6:0] e_draww = (e_true < 0) ? w_full_s[6:0] : ENEMY_W[6:0];

    task reset_game;
        begin
            px         <= 11'd600;
            b_active   <= 1'b0;
            lives_r    <= 2'd3;
            inv        <= 7'd0;
            gun_timer  <= 6'd0;
            wave_r     <= 4'd1;
            emask      <= 12'h03F;
            sq_active  <= 3'b001;
            entry_cnt  <= 12'd0;
            ex0        <= -13'sd512;
            ex1        <= -13'sd512;
            ex2        <= -13'sd512;
            sp0        <= 4'd2;
            sp1        <= 4'd3;
            sp2        <= 4'd4;
            ft0        <= 8'd90;
            ft1        <= 8'd70;
            ft2        <= 8'd50;
            ft0c       <= 8'd90;
            ft1c       <= 8'd70;
            ft2c       <= 8'd50;
            fc0        <= 2'd0;
            fc1        <= 2'd0;
            fc2        <= 2'd0;
            e1a        <= 1'b0;
            e2a        <= 1'b0;
            st         <= 1'b0;
            wave_dly   <= 8'd0;
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            spr_we   <= 1'b0;
            spr_slot <= 4'd0;
            spr_en   <= 1'b0;
            spr_x    <= 11'd0;
            spr_y    <= 10'd0;
            spr_w    <= 7'd0;
            spr_h    <= 6'd0;
            spr_c    <= 24'h000000;
            wr_idx   <= 4'd0;
            o_ev_hit <= 1'b0;
            o_ev_lose<= 1'b0;
            o_ev_win <= 1'b0;
            reset_game;
        end
        else begin
            o_ev_hit  <= 1'b0;
            o_ev_lose <= 1'b0;
            o_ev_win  <= 1'b0;

            // ---- restart: entering the game, or any key after game over ------
            if (restart || (st && (key_left || key_right))) begin
                reset_game;
            end

            // ---- one game step per frame ------------------------------------
            else if (frame_tick && enable && !st) begin
                // player movement
                if (key_left && px > 11'd0)
                    px <= px - 11'd8;
                else if (key_right && px < H_ACTIVE - PLAYER_W)
                    px <= px + 11'd8;

                // player fire cadence
                gun_timer <= (gun_timer == 6'd23) ? 6'd0 : (gun_timer + 6'd1);

                // player bullet
                if (b_active) begin
                    if (by < 10'd12)
                        b_active <= 1'b0;
                    else
                        by <= by - 10'd12;
                end
                else if (gun_timer == 6'd0) begin
                    b_active <= 1'b1;
                    bx <= px + (PLAYER_W / 2);
                    by <= PLAYER_Y - 10'd24;
                end

                // bullet vs enemy
                if (b_hit_now) begin
                    emask    <= emask_after;
                    b_active <= 1'b0;
                    o_ev_hit <= 1'b1;
                    if (waveup_now) begin
                        // wave cleared: re-stagger the three squadrons, faster
                        wave_r    <= (wave_r == 4'd15) ? 4'd15 : (wave_r + 4'd1);
                        emask     <= 12'd0;          // 先空一波
                        wave_dly  <= 8'd120;         // 2 秒后再入场
                        sq_active <= 3'b000;
                        entry_cnt <= 10'd0;
                        ex0       <= -13'sd512;
                        ex1       <= -13'sd512;
                        ex2       <= -13'sd512;
                        sp0       <= 4'd2 + speed_add(wave_r + 4'd1);
                        sp1       <= 4'd3 + speed_add(wave_r + 4'd1);
                        sp2       <= 4'd4 + speed_add(wave_r + 4'd1);
                        ft0       <= fire_iv(8'd90, wave_r + 4'd1);
                        ft1       <= fire_iv(8'd70, wave_r + 4'd1);
                        ft2       <= fire_iv(8'd50, wave_r + 4'd1);
                        ft0c      <= fire_iv(8'd90, wave_r + 4'd1);
                        ft1c      <= fire_iv(8'd70, wave_r + 4'd1);
                        ft2c      <= fire_iv(8'd50, wave_r + 4'd1);
                        e1a       <= 1'b0;
                        e2a       <= 1'b0;
                        o_ev_win  <= 1'b1;
                    end
                end

                // wave respawn delay
                if (wave_dly != 8'd0) begin
                    wave_dly <= wave_dly - 8'd1;
                    if (wave_dly == 8'd1) begin
                        emask     <= 12'h03F;
                        sq_active <= 3'b001;
                        entry_cnt <= 10'd0;
                        ex0       <= -13'sd512;
                        ex1       <= -13'sd512;
                        ex2       <= -13'sd512;
                    end
                end

                // squadron entry stagger
                if (entry_cnt < 10'd401) begin
                    entry_cnt <= entry_cnt + 10'd1;
                    if (entry_cnt == ENTRY_FRAMES - 1) begin
                        sq_active <= sq_active | 3'b010;
                        ex1       <= -13'sd512;
                        ft1c      <= ft1;
                    end
                    if (entry_cnt == 2*ENTRY_FRAMES - 1) begin
                        sq_active <= sq_active | 3'b100;
                        ex2       <= -13'sd512;
                        ft2c      <= ft2;
                    end
                end

                // squads fly left -> right and wrap
                if (sq_active[0]) begin
                    if ($signed(ex0) > 13'sd1280) ex0 <= -13'sd512;
                    else                          ex0 <= ex0 + $signed({1'b0, sp0});
                end
                if (sq_active[1]) begin
                    if ($signed(ex1) > 13'sd1280) ex1 <= -13'sd512;
                    else                          ex1 <= ex1 + $signed({1'b0, sp1});
                end
                if (sq_active[2]) begin
                    if ($signed(ex2) > 13'sd1280) ex2 <= -13'sd512;
                    else                          ex2 <= ex2 + $signed({1'b0, sp2});
                end

                // per-squad fire cadence
                if (sq_active[0]) begin
                    if (ft0c == 8'd0) begin
                        ft0c <= ft0;
                        fc0  <= fc0 + 2'd1;
                        if (emask[{2'b00, fc0[0]}] && spawn0_ok && !e1a) begin
                            e1a <= 1'b1; e1x <= sx0; e1y <= sy0;
                        end
                        else if (emask[{2'b00, fc0[0]}] && spawn0_ok && !e2a) begin
                            e2a <= 1'b1; e2x <= sx0; e2y <= sy0;
                        end
                    end
                    else ft0c <= ft0c - 8'd1;
                end
                if (sq_active[1]) begin
                    if (ft1c == 8'd0) begin
                        ft1c <= ft1;
                        fc1  <= fc1 + 2'd1;
                        if (emask[{2'b01, fc1[0]}] && spawn1_ok && !e1a) begin
                            e1a <= 1'b1; e1x <= sx1; e1y <= sy1;
                        end
                        else if (emask[{2'b01, fc1[0]}] && spawn1_ok && !e2a) begin
                            e2a <= 1'b1; e2x <= sx1; e2y <= sy1;
                        end
                    end
                    else ft1c <= ft1c - 8'd1;
                end
                if (sq_active[2]) begin
                    if (ft2c == 8'd0) begin
                        ft2c <= ft2;
                        fc2  <= fc2 + 2'd1;
                        if (emask[{2'b10, fc2[0]}] && spawn2_ok && !e1a) begin
                            e1a <= 1'b1; e1x <= sx2; e1y <= sy2;
                        end
                        else if (emask[{2'b10, fc2[0]}] && spawn2_ok && !e2a) begin
                            e2a <= 1'b1; e2x <= sx2; e2y <= sy2;
                        end
                    end
                    else ft2c <= ft2c - 8'd1;
                end

                // enemy bullets fly down
                if (e1a) begin
                    if (e1y > 10'd700) e1a <= 1'b0;
                    else               e1y <= e1y + 10'd5;
                end
                if (e2a) begin
                    if (e2y > 10'd700) e2a <= 1'b0;
                    else               e2y <= e2y + 10'd5;
                end

                // enemy bullet hits the player
                if (player_hit) begin
                    if (p1_hit) e1a <= 1'b0;
                    if (p2_hit) e2a <= 1'b0;
                    o_ev_hit    <= 1'b1;
                    if (lives_r == 2'd1) begin
                        st       <= 1'b1;
                        b_active <= 1'b0;
                        o_ev_lose<= 1'b1;
                    end
                    else begin
                        lives_r <= lives_r - 2'd1;
                        inv     <= 7'd90;      // 1.5 s of blinking mercy
                    end
                end

                // invulnerability countdown
                if (inv != 7'd0) inv <= inv - 7'd1;
            end

            // ---- push all 16 sprites, one per clock --------------------------
            wr_idx   <= (wr_idx == 4'd15) ? 4'd0 : (wr_idx + 4'd1);
            spr_we   <= enable;
            spr_slot <= wr_idx;

            if (wr_idx == 4'd0) begin
                // player blinks while invulnerable
                spr_en <= (inv == 7'd0) || !inv[3];
                spr_x  <= px;
                spr_y  <= PLAYER_Y[9:0];
                spr_w  <= PLAYER_W[6:0];
                spr_h  <= PLAYER_H[5:0];
                spr_c  <= 24'h40FF80;
            end
            else if (wr_idx == 4'd1) begin
                spr_en <= b_active;
                spr_x  <= bx;
                spr_y  <= by;
                spr_w  <= 7'd6;
                spr_h  <= 6'd18;
                spr_c  <= 24'hFFFFFF;
            end
            else if (wr_idx <= 4'd7) begin
                if (st) begin
                    // 结束态: 槽 2..5 拼成 240x120 居中红色大块
                    spr_en <= (e_i[2:1] != 2'd3);
                    spr_x  <= e_i[0] ? 11'd640 : 11'd520;
                    spr_y  <= e_i[1] ? 10'd360 : 10'd300;
                    spr_w  <= 7'd120;
                    spr_h  <= 6'd60;
                    spr_c  <= 24'hFF3030;
                end
                else begin
                    // enemies: slot 2+i, i = 0..5, row = i[2:1], col = i[0]
                    spr_en <= emask[e_i] && sq_active[e_i[2:1]] && e_vis;
                    spr_x  <= e_drawx;
                    spr_y  <= (e_i[2:1] == 2'd0) ? RY0 :
                              (e_i[2:1] == 2'd1) ? RY1 : RY2;
                    spr_w  <= e_draww;
                    spr_h  <= ENEMY_H[5:0];
                    spr_c  <= (e_i[2:1] == 2'd0) ? 24'hFF6060 :
                              (e_i[2:1] == 2'd1) ? 24'hFFC040 : 24'hC060FF;
                end
            end
            else if (wr_idx <= 4'd10) begin
                // lives: 3 red blocks bottom-left, one per remaining life
                spr_en <= (wr_idx[1:0] < lives_r);
                spr_x  <= (wr_idx[1:0] == 2'd0) ? 11'd24 :
                          (wr_idx[1:0] == 2'd1) ? 11'd64 : 11'd104;
                spr_y  <= 10'd688;
                spr_w  <= 7'd24;
                spr_h  <= 6'd16;
                spr_c  <= 24'hFF4040;
            end
            else if (wr_idx <= 4'd13) begin
                spr_en <= 1'b0;              // slots 11..13 idle
            end
            else if (wr_idx == 4'd14) begin
                spr_en <= e1a;
                spr_x  <= e1x;
                spr_y  <= e1y;
                spr_w  <= 7'd6;
                spr_h  <= 6'd18;
                spr_c  <= 24'hFFE040;
            end
            else begin
                // slot 15: second enemy bullet, or the game-over banner
                if (st) begin
                    spr_en <= 1'b0;          // 结束色块已移到槽 2..5
                end
                else begin
                    spr_en <= e2a;
                    spr_x  <= e2x;
                    spr_y  <= e2y;
                    spr_w  <= 7'd6;
                    spr_h  <= 6'd18;
                    spr_c  <= 24'hFFE040;
                end
            end
        end
    end

endmodule

`default_nettype wire