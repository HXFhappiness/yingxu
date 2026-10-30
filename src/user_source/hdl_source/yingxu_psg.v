`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// yingxu_psg  -  tiny square-wave sound generator
//
// Produces 48 kHz samples by fractional accumulation of the pixel clock, then
// square waves for four events. The samples replace the I2S input while in game
// mode, so the sound travels over HDMI exactly like normal audio.
//
// 48 kHz from 73.33 MHz: add 48000 every cycle; when the accumulator passes
// 73_333_333 a sample is due. Average rate is exact, the jitter is one clock.
//------------------------------------------------------------------------------
module yingxu_psg #(
    parameter integer CLK_HZ   = 73_333_333,
    parameter integer SAMPLE_HZ = 48_000
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        ev_hit,      // brick / enemy destroyed
    input  wire        ev_paddle,   // paddle bounce
    input  wire        ev_lose,
    input  wire        ev_win,
    input  wire        enable,      // game mode

    output reg         audio_valid,
    output reg  [23:0] audio_left,
    output reg  [23:0] audio_right
);

    // ---- 48 kHz sample strobe ----------------------------------------------
    reg [31:0] acc;
    reg        sample_tick;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc         <= 32'd0;
            sample_tick <= 1'b0;
        end
        else begin
            if (acc >= CLK_HZ - SAMPLE_HZ) begin
                acc         <= acc - (CLK_HZ - SAMPLE_HZ);
                sample_tick <= 1'b1;
            end
            else begin
                acc         <= acc + SAMPLE_HZ;
                sample_tick <= 1'b0;
            end
        end
    end

    // ---- tone table ---------------------------------------------------------
    // phase increment = f * 2^24 / 48000
    localparam [23:0] INC_HIT    = 24'd307_200;   //  ~880 Hz
    localparam [23:0] INC_PADDLE = 24'd153_600;   //  ~440 Hz
    localparam [23:0] INC_LOSE   = 24'd76_800;    //  ~220 Hz
    localparam [23:0] INC_WIN    = 24'd460_800;   // ~1320 Hz

    localparam [15:0] DUR_HIT    = 16'd5_760;     // 120 ms
    localparam [15:0] DUR_PADDLE = 16'd2_880;     //  60 ms
    localparam [15:0] DUR_LOSE   = 16'd24_000;    // 500 ms
    localparam [15:0] DUR_WIN    = 16'd19_200;    // 400 ms

    reg [23:0] inc;
    // DIAG: continuous 440 Hz tone so the HDMI audio path can be tested without
    // relying on game events.
    reg cont_tone;
    reg [15:0] remain;          // samples left in the current tone
    reg [23:0] phase;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            inc    <= 24'd0;
            remain <= 16'd0;
            phase  <= 24'd0;
        end
        else if (ev_win) begin
            inc    <= INC_WIN;
            remain <= DUR_WIN;
        end
        else if (ev_lose) begin
            inc    <= INC_LOSE;
            remain <= DUR_LOSE;
        end
        else if (ev_hit) begin
            inc    <= INC_HIT;
            remain <= DUR_HIT;
        end
        else if (ev_paddle) begin
            inc    <= INC_PADDLE;
            remain <= DUR_PADDLE;
        end
        else if (sample_tick && (remain != 16'd0 || cont_tone)) begin
            remain <= remain - 16'd1;
            phase  <= phase + inc;
        end
        else if (sample_tick) begin
            phase <= 24'd0;
        end
    end

    // ---- output -------------------------------------------------------------
    wire        square = phase[23];
    // G6: 只有音符在播时才输出方波；空闲输出真正的数字静音。
    // 原实现在无音时 phase=0 → 恒定 0xE00000（-0.25 FS 直流偏置），
    // 实测录到 -12dB 纯直流（扬声器听不出，但污染混音并在录音里显形）。
    wire        psg_on = (remain != 16'd0);
    // G6: 宿舍音量 — 幅度 1/8（±0.03125 FS）。要大音量改回 200000/E00000。
    // G6: 音量 1/32（±0.0078125 FS）。调音量表：FF0000/010000=1/32，FC0000/040000=1/8，E00000/200000=1/4
    wire [23:0] sample = psg_on ? (square ? 24'h010000 : 24'hFF0000) : 24'h000000;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            audio_valid <= 1'b0;
            audio_left  <= 24'h000000;
            audio_right <= 24'h000000;
        end
        else begin
            audio_valid <= sample_tick && enable;
            if (sample_tick && enable) begin
                audio_left  <= sample;
                audio_right <= sample;
            end
        end
    end

endmodule

`default_nettype wire
