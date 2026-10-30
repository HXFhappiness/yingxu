`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// yingxu_bmp_loader
//   SD byte stream (50 MHz) -> RGB565 pairs -> SDRAM scratch via WR2.
//   One frame = (H_ACTIVE/2)*V_ACTIVE 32-bit words, 2 pixels per word.
//   BMP must be 24bpp uncompressed with rows already top-down.
//------------------------------------------------------------------------------
module yingxu_bmp_loader #(
    parameter integer TEST_PATTERN = 0,
    parameter integer H_ACTIVE     = 1280,
    parameter integer V_ACTIVE     = 720,
    parameter integer HEADER_BYTES = 54,
    parameter [20:0]  SCRATCH_ADDR = 21'h100000
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [7:0]  sd_data,
    input  wire        sd_valid,
    output wire        sd_ready,

    output reg  [31:0] wr2_data,
    output reg         wr2_en,
    input  wire        wr2_full,
    input  wire [20:0] i_base,          // frame buffer base (double buffering)
    output wire [20:0] wr2_addr,
    output wire [20:0] wr2_max_addr,
    output wire [8:0]  wr2_len,
    output reg         wr2_load,

    output reg  [19:0] words_written,
    output wire        loaded
);

    localparam integer FRAME_WORDS = (H_ACTIVE / 2) * V_ACTIVE;

    assign wr2_addr     = i_base;
    assign wr2_max_addr = i_base + FRAME_WORDS;
    assign wr2_len      = 9'd128;
    assign loaded       = (words_written == FRAME_WORDS);

    reg        running;
    reg [6:0]  hdr_cnt;
    reg [1:0]  byte_idx;
    reg [7:0]  b_hold, g_hold;
    reg [15:0] pix_left;
    reg        have_left;
    reg [3:0]  load_cnt;

    wire [15:0] pix565_now = { sd_data[7:3], g_hold[7:2], b_hold[7:3] };
    wire        byte_take  = sd_valid && sd_ready;

    // Match the known-good original design exactly: the SD stream sink is
    // never stalled. SPI delivers ~0.26 M words/s while WR2 can absorb
    // ~100 M words/s, so the write FIFO cannot realistically back up.
    assign sd_ready = 1'b1;

    always @(posedge clk or posedge rst) begin
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
            load_cnt      <= 4'd8;
            wr2_load      <= 1'b0;
        end
        else begin
            wr2_en <= 1'b0;

            // Latch base/max/length of the scratch region. This MUST happen
            // well after the SDRAM controller leaves reset: the controller
            // holds ctrl_reset_n low for ~10k cycles after power-up, and a LOAD
            // pulse during that window is lost, leaving rWR2_LENGTH = 0, which
            // permanently disables the port in the arbiter.
            if (running && (load_cnt < 4'd8)) begin
                load_cnt <= load_cnt + 4'd1;
                wr2_load <= 1'b1;
            end
            else begin
                wr2_load <= 1'b0;
            end

            if (!running) begin
                if (start) begin
                    running       <= 1'b1;
                    load_cnt      <= 4'd0;   // re-arm the LOAD pulse
                    hdr_cnt       <= 7'd0;
                    byte_idx      <= 2'd0;
                    have_left     <= 1'b0;
                    words_written <= 20'd0;
                end
            end
            else if (load_cnt < 4'd8) begin
                // still latching the port configuration; drop input meanwhile
                byte_idx  <= 2'd0;
                have_left <= 1'b0;
            end
            else if (byte_take) begin
                if (hdr_cnt < HEADER_BYTES) begin
                    hdr_cnt <= hdr_cnt + 7'd1;
                end
                else if (words_written >= FRAME_WORDS) begin
                    byte_idx  <= 2'd0;
                    have_left <= 1'b0;
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
                                wr2_data      <= TEST_PATTERN ? 
                                                 { words_written[4:0], words_written[9:5], words_written[14:10],
                                                   words_written[19:15], words_written[4:0], words_written[9:5] } :
                                                 { pix_left, pix565_now };
                                wr2_en        <= 1'b1;
                                have_left     <= 1'b0;
                                words_written <= words_written + 20'd1;
                                // Release the loader so the next start re-arms it.
                                if (words_written == FRAME_WORDS - 1)
                                    running <= 1'b0;
                            end
                        end
                    endcase
                end
            end
        end
    end

endmodule

`default_nettype wire
