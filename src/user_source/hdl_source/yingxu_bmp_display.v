`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// yingxu_bmp_display
//
//  SD (slow, ~1.5 MB/s)  ->  SDRAM scratch frame  ->  framebuffer media (fast)
//
//  The framebuffer media port expects a continuous fixed-size frame; feeding it
//  straight from SPI SD starves its swap/prefetch logic. So the BMP is first
//  decoded into RGB565 and stored in a scratch region of SDRAM, then replayed
//  at full video rate forever.
//
//  Ports used: the 4-port SDRAM controller's WR2 (write) and RD2 (read), which
//  the framebuffer leaves tied off.
//    loader  : sys_clk    (50 MHz)  -> WR2_CLK
//    player  : media_clk (100 MHz)  -> RD2_CLK
//
//  BMP assumptions: 1280x720, 24bpp, uncompressed, rows top-down (negative
//  biHeight) so the byte order is already the display order.
//------------------------------------------------------------------------------

module yingxu_bmp_display #(
    parameter integer H_ACTIVE     = 1280,
    parameter integer V_ACTIVE     = 720,
    parameter integer HEADER_BYTES = 54,
    parameter [20:0]  SCRATCH_ADDR = 21'h100000
)(
    input  wire        sys_clk,
    input  wire        media_clk,
    input  wire        rst,

    input  wire        start,
    input  wire [7:0]  sd_data,
    input  wire        sd_valid,
    output wire        sd_ready,

    // SDRAM write port 2 (sys_clk domain)
    output reg  [31:0] wr2_data,
    output reg         wr2_en,
    input  wire        wr2_full,
    output wire [20:0] wr2_addr,
    output wire [20:0] wr2_max_addr,
    output wire [8:0]  wr2_len,
    output reg         wr2_load,

    // SDRAM read port 2 (media_clk domain)
    input  wire [31:0] rd2_data,
    input  wire        rd2_empty,
    output reg         rd2_en,
    output wire [20:0] rd2_addr,
    output wire [20:0] rd2_max_addr,
    output wire [8:0]  rd2_len,
    output reg         rd2_load,

    // framebuffer media port
    output wire        media_valid,
    input  wire        media_ready,
    output wire [31:0] media_data,
    output reg         media_frame_start,
    output reg         media_frame_end,

    output reg  [19:0] words_written,
    output wire        loaded
);

    localparam integer FRAME_WORDS = (H_ACTIVE / 2) * V_ACTIVE;

    assign wr2_addr     = SCRATCH_ADDR;
    assign wr2_max_addr = SCRATCH_ADDR + FRAME_WORDS;   // words are 21-bit addressed
    assign wr2_len      = 9'd128;

    assign rd2_addr     = SCRATCH_ADDR;
    assign rd2_max_addr = SCRATCH_ADDR + FRAME_WORDS;
    assign rd2_len      = 9'd128;

    assign loaded = (words_written == FRAME_WORDS);

    // ------------------------------------------------------------------
    // Loader (sys_clk): SD bytes -> RGB565 -> 2 pixels per SDRAM word
    // ------------------------------------------------------------------
    reg        running;
    reg [6:0]  hdr_cnt;
    reg [1:0]  byte_idx;
    reg [7:0]  b_hold, g_hold;
    reg [15:0] pix_left;
    reg        have_left;
    reg [3:0]  ld_load_cnt;

    wire [15:0] pix565_now = { sd_data[7:3], g_hold[7:2], b_hold[7:3] };
    wire        byte_take  = sd_valid && sd_ready;

    // Accept bytes only while there is room in the write FIFO.
    assign sd_ready = running && !wr2_full;

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            running       <= 1'b0;
            hdr_cnt       <= 7'd0;
            byte_idx      <= 2'd0;
            b_hold        <= 8'd0;
            g_hold        <= 8'd0;
            pix_left      <= 16'd0;
            have_left     <= 1'b0;
            wr2_data      <= 32'd0;
            wr2_en        <= 1'b0;
            words_written <= 20'd0;
            ld_load_cnt   <= 4'd0;
            wr2_load      <= 1'b1;      // reset the write pointer
        end
        else begin
            wr2_en <= 1'b0;

            // Pulse LOAD for a few cycles at reset / at start.
            if (ld_load_cnt < 4'd8) begin
                ld_load_cnt <= ld_load_cnt + 4'd1;
                wr2_load    <= 1'b1;
            end
            else begin
                wr2_load <= 1'b0;
            end

            if (!running) begin
                if (start && ld_load_cnt >= 4'd8) begin
                    running       <= 1'b1;
                    hdr_cnt       <= 7'd0;
                    byte_idx      <= 2'd0;
                    have_left     <= 1'b0;
                    words_written <= 20'd0;
                end
            end
            else if (byte_take) begin
                if (hdr_cnt < HEADER_BYTES) begin
                    hdr_cnt <= hdr_cnt + 7'd1;
                end
                else if (words_written >= FRAME_WORDS) begin
                    byte_idx  <= 2'd0;
                    have_left <= 1'b0;      // drain the rest of the sector
                end
                else begin
                    case (byte_idx)
                        2'd0: begin b_hold   <= sd_data; byte_idx <= 2'd1; end
                        2'd1: begin g_hold   <= sd_data; byte_idx <= 2'd2; end
                        default: begin
                            byte_idx <= 2'd0;
                            if (!have_left) begin
                                pix_left  <= pix565_now;
                                have_left <= 1'b1;
                            end
                            else begin
                                wr2_data      <= { pix_left, pix565_now };
                                wr2_en        <= 1'b1;
                                have_left     <= 1'b0;
                                words_written <= words_written + 20'd1;
                            end
                        end
                    endcase
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Player (media_clk): replay the stored frame at full video rate
    // ------------------------------------------------------------------
    reg [18:0] out_cnt;
    reg        reload;
    reg [2:0]  reload_cnt;

    assign media_valid = !rd2_empty && !reload;
    assign media_data  = rd2_data;

    wire media_fire = media_valid && media_ready;

    always @(posedge media_clk or posedge rst) begin
        if (rst) begin
            out_cnt          <= 19'd0;
            reload           <= 1'b1;
            reload_cnt       <= 3'd0;
            rd2_en           <= 1'b0;
            rd2_load         <= 1'b1;
            media_frame_start <= 1'b0;
            media_frame_end   <= 1'b0;
        end
        else begin
            rd2_en <= 1'b0;

            if (reload) begin
                rd2_load <= 1'b1;
                if (reload_cnt == 3'd7) begin
                    reload     <= 1'b0;
                    reload_cnt <= 3'd0;
                    rd2_load   <= 1'b0;
                    out_cnt    <= 19'd0;
                end
                else begin
                    reload_cnt <= reload_cnt + 3'd1;
                end
            end
            else if (media_fire) begin
                rd2_en <= 1'b1;

                media_frame_start <= (out_cnt == 19'd0);
                media_frame_end   <= (out_cnt == FRAME_WORDS - 1);

                if (out_cnt == FRAME_WORDS - 1) begin
                    out_cnt <= 19'd0;
                    reload  <= 1'b1;
                end
                else begin
                    out_cnt <= out_cnt + 19'd1;
                end
            end
            else begin
                media_frame_start <= 1'b0;
                media_frame_end   <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
