`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// yingxu_bmp_media_source
//
// Streams one top-down 24bpp BMP (no compression, rows already in display
// order) from the SD byte stream into the framebuffer media port.
//
//   sys_clk   : 50 MHz  - SD byte stream domain
//   media_clk : 100 MHz - framebuffer media domain
//
// Contract implemented (same as yingxu_test_media_source):
//   media_data[31:16] = left  RGB565 pixel
//   media_data[15:0]  = right RGB565 pixel
//   FRAME_WORDS = (H_ACTIVE/2) * V_ACTIVE
//   frame_start on the first accepted word, frame_end on the last
//
// Backpressure: the framebuffer may stop accepting at any time; this module
// simply holds the current word until it is taken, so a very slow source
// (SPI SD, ~1.5 MB/s) is legal - the display keeps showing the previous frame.
//
// Word handshake across domains: toggle/ack, data is held stable from the
// moment the request toggles until the acknowledge returns.
//------------------------------------------------------------------------------

module yingxu_bmp_media_source #(
    parameter integer H_ACTIVE     = 1280,
    parameter integer V_ACTIVE     = 720,
    parameter integer HEADER_BYTES = 54
)(
    input  wire        sys_clk,
    input  wire        media_clk,
    input  wire        rst,

    input  wire        start,
    input  wire [7:0]  sd_data,
    input  wire        sd_valid,
    output wire        sd_ready,

    output wire        busy,
    output wire        done,
    output wire [19:0] word_count,

    output reg         media_valid,
    input  wire        media_ready,
    output reg  [31:0] media_data,
    output reg         media_frame_start,
    output reg         media_frame_end
);

    localparam integer WORDS_PER_LINE = H_ACTIVE / 2;
    localparam integer FRAME_WORDS    = WORDS_PER_LINE * V_ACTIVE;

    // ------------------------------------------------------------------
    // sys_clk domain : bytes -> RGB565 pairs -> one 32-bit word
    // ------------------------------------------------------------------
    reg        running;
    reg [6:0]  hdr_cnt;
    reg [1:0]  byte_idx;
    reg [7:0]  b_hold, g_hold;
    reg [15:0] pix_left;
    reg        have_left;

    reg        pending;        // a word is being handed to media domain
    reg        req_tgl;
    reg        ack_s1, ack_s2; // ack synchronised into sys domain
    reg [31:0] word_hold;
    reg [18:0] words_sent;

    wire [15:0] pix565_now = { sd_data[7:3], g_hold[7:2], b_hold[7:3] };
    wire        byte_take  = sd_valid && sd_ready;
    wire        ack_tgl;       // from media domain, declared there

    // Only consume bytes while actually loading. Keeping this deasserted at
    // reset (and after the frame is complete) matches the configuration that
    // was verified to bring SD initialization up reliably.
    assign sd_ready  = (running && !pending) || done;
    assign busy      = running;
    assign done      = (words_sent == FRAME_WORDS);
    assign word_count = {1'b0, words_sent};

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            running      <= 1'b0;
            hdr_cnt      <= 7'd0;
            byte_idx     <= 2'd0;
            b_hold       <= 8'd0;
            g_hold       <= 8'd0;
            pix_left     <= 16'd0;
            have_left    <= 1'b0;
            pending      <= 1'b0;
            req_tgl      <= 1'b0;
            ack_s1       <= 1'b0;
            ack_s2       <= 1'b0;
            word_hold    <= 32'd0;
            words_sent   <= 19'd0;
        end
        else begin
            ack_s1 <= ack_tgl;
            ack_s2 <= ack_s1;

            // handshake completion
            if (pending && (ack_s2 == req_tgl))
                pending <= 1'b0;

            if (!running) begin
                if (start) begin
                    running   <= 1'b1;
                    hdr_cnt   <= 7'd0;
                    byte_idx  <= 2'd0;
                    have_left <= 1'b0;
                    words_sent <= 19'd0;
                end
            end
            else if (byte_take) begin
                if (hdr_cnt < HEADER_BYTES) begin
                    hdr_cnt <= hdr_cnt + 7'd1;
                end
                else if (!running || (words_sent >= FRAME_WORDS)) begin
                    // Frame already complete: keep draining the sector so the
                    // SD reader can finish its transaction without timing out.
                    byte_idx  <= 2'd0;
                    have_left <= 1'b0;
                end
                else begin
                    case (byte_idx)
                        2'd0: begin
                            b_hold   <= sd_data;
                            byte_idx <= 2'd1;
                        end
                        2'd1: begin
                            g_hold   <= sd_data;
                            byte_idx <= 2'd2;
                        end
                        default: begin
                            byte_idx <= 2'd0;
                            if (!have_left) begin
                                pix_left  <= pix565_now;
                                have_left <= 1'b1;
                            end
                            else if (!pending) begin
                                // complete word: left pixel was pushed first
                                word_hold <= { pix_left, pix565_now };
                                req_tgl   <= ~req_tgl;
                                pending   <= 1'b1;
                                have_left <= 1'b0;
                                if (words_sent != FRAME_WORDS)
                                    words_sent <= words_sent + 19'd1;
                                if (words_sent == FRAME_WORDS - 1)
                                    running <= 1'b0;   // frame complete
                            end
                        end
                    endcase
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // media_clk domain : hand words to the framebuffer
    // ------------------------------------------------------------------
    reg        req_m1, req_m2;
    reg        ack_tgl_r;
    reg [18:0] out_cnt;

    assign ack_tgl = ack_tgl_r;

    always @(posedge media_clk or posedge rst) begin
        if (rst) begin
            req_m1           <= 1'b0;
            req_m2           <= 1'b0;
            ack_tgl_r        <= 1'b0;
            out_cnt          <= 19'd0;
            media_valid      <= 1'b0;
            media_data       <= 32'd0;
            media_frame_start <= 1'b0;
            media_frame_end   <= 1'b0;
        end
        else begin
            req_m1 <= req_tgl;
            req_m2 <= req_m1;

            if (media_valid && media_ready) begin
                // Word accepted: only now acknowledge back to the sys domain,
                // and only now advance the frame counter. The sidebands must
                // stay asserted for as long as media_valid is asserted.
                media_valid       <= 1'b0;
                media_frame_start <= 1'b0;
                media_frame_end   <= 1'b0;
                ack_tgl_r         <= req_m2;
                if (out_cnt != FRAME_WORDS)
                    out_cnt <= out_cnt + 19'd1;
            end
            else if (!media_valid && (req_m2 != ack_tgl_r)) begin
                media_valid       <= 1'b1;
                media_data        <= word_hold;
                media_frame_start <= (out_cnt == 19'd0);
                media_frame_end   <= (out_cnt == FRAME_WORDS - 1);
            end
        end
    end

endmodule

`default_nettype wire
