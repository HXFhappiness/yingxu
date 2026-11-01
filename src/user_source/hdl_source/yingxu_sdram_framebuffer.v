`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// YingXu V0.4C-P1: SDRAM scratch core (was: double framebuffer)
//
// The V0.3C-A double framebuffer (media-stream sink, front/back A-B swap FSM,
// pixel-domain reader, RGB565->RGB888 replay) has been dead since V0.4A-B,
// when the still-image path moved to "SD -> WR2 scratch -> RD2 pixel replay".
// The media inputs were tied off, the FSM parked in C_PREFILL_A forever, and
// only two things in this module still worked: the vendor 4-port controller
// (with its internal Sdram_PLL) and the sdram_ip wrapper around the
// EG_PHY_SDRAM_2M_32 board macro. The parked FSM also held WR1/RD1 LOAD
// asserted at boot, which needed the boot_cnt workaround so the arbiter
// would ever reach WR2 (see REPORT_MATERIALS case 1/2).
//
// This rewrite keeps the module name and port list, and contains exactly
// what is used: controller + PHY + the WR2/RD2 scratch ports.
//
//   WR1/RD1: unused. EN=0 and LOAD=0 park them safely AFTER the power-on reset
//   pulse below has run (see P1-R2):
//     - write port: the arbiter only services a write FIFO that holds data,
//       so an empty WR1 is skipped (wr1_aempty_w stays high).
//     - read port: the reset pulse makes the controller load LENGTH=128 into
//       every port; RD1 then issues one 128-word burst, its FIFO reports
//       almost-full, and the port is skipped forever. Without the pulse
//       rRD1_LENGTH would stay 0 and the read arbiter (which, unlike the
//       write side, has no LENGTH==0 guard) would spin on zero-length RD1
//       services and starve RD2/WR2 completely.
//     - LOAD must never be held high: it gates the whole scheduler.
//   WR2 (load): driven by yingxu_bmp_loader in the sys_clk (50 MHz) domain.
//   RD2 (play): driven by yingxu_sdram_video_player in the pixel-clock domain.
//
// The EG_PHY_SDRAM_2M_32 macro pins are fixed by the device library; they do
// not appear in the top-level port list, and nothing else needs constraining.
//------------------------------------------------------------------------------

module yingxu_sdram_framebuffer #(
    parameter integer ENABLE_MJPEG = 0,
    parameter integer H_TOTAL  = 1650,
    parameter integer H_ACTIVE = 1280,
    parameter integer V_TOTAL  = 750,
    parameter integer V_ACTIVE = 720
)(
    input  wire          sys_clk,
    input  wire          pixel_clk,
    input  wire          rst,

    input  wire [10:0]   pixel_x,
    input  wire [ 9:0]   pixel_y,
    input  wire          pixel_active,

    // Unified media-stream interface (dead since V0.4A-B, kept for ports).
    output wire          media_clk,
    input  wire          media_valid,
    output wire          media_ready,
    input  wire [31:0]   media_data,
    input  wire          media_frame_start,
    input  wire          media_frame_end,

    output wire [23:0]   rgb_out,
    output wire          fb_ready,
    output wire          fb_underflow,

    // Diagnostics.
    output wire [4:0]    o_c_state,
    output wire          o_wr1_full,
    output wire          o_media_ready,

    // Scratch-buffer ports (BMP display): the two controller ports in use.
    input  wire [31:0]   i_wr2_data,
    input  wire          i_wr2_en,
    input  wire [20:0]   i_wr2_addr,
    input  wire [20:0]   i_wr2_max_addr,
    input  wire [8:0]    i_wr2_len,
    input  wire          i_wr2_load,
    output wire          o_wr2_full,

    input  wire          i_rd2_en,
    input  wire [20:0]   i_rd2_addr,
    input  wire [20:0]   i_rd2_max_addr,
    input  wire [8:0]    i_rd2_len,
    input  wire          i_rd2_load,
    output wire [31:0]   o_rd2_data,
    output wire          o_rd2_empty,
    output wire          o_mem_clk,o_mem_ready,
    input wire           i_mj_active,i_mj_valid,i_mj_write,
    input wire [20:0]    i_mj_addr,input wire [3:0] i_mj_words,
    output wire          o_mj_ready,
    input wire           i_mj_wvalid,i_mj_wlast,input wire [31:0] i_mj_wdata,
    output wire          o_mj_wready,o_mj_rvalid,o_mj_rlast,
    output wire [31:0]   o_mj_rdata,input wire i_mj_rready,
    output wire [6:0]    o_mj_debug_write,
    output wire          o_mj_done,o_mj_error,o_mj_idle
);

    // Dead-since-V0.4A-B media path: report "not ready, never accepted".
    assign media_clk     = 1'b0;
    assign media_ready   = 1'b0;
    assign rgb_out       = 24'h000000;
    assign fb_ready      = 1'b0;
    assign fb_underflow  = 1'b0;
    assign o_c_state     = 5'd0;
    // o_wr1_full is wired straight from the controller (empty FIFO -> 0).
    assign o_media_ready = 1'b0;

    wire unused_media = media_valid | media_data[0] | media_frame_start |
                        media_frame_end | pixel_active |
                        pixel_x[0] | pixel_y[0] | rst;

    // -------------------------------------------------------------------------
    // SDRAM physical wires (the EG_PHY_SDRAM_2M_32 macro pins are fixed by the
    // device library; they never reach a top-level port).
    // -------------------------------------------------------------------------
    wire        sdram_ctrl_clk;   // controller CLK output (its internal PLL)
    wire        sdram_sdr_clk;
    wire [10:0] sdram_sa;
    wire [ 1:0] sdram_ba;
    wire        sdram_cs_n;
    wire        sdram_cke;
    wire        sdram_ras_n;
    wire        sdram_cas_n;
    wire        sdram_we_n;
    wire [31:0] sdram_dq;
    wire [ 3:0] sdram_dqm;

    // -------------------------------------------------------------------------
    // P1-R2 board fix (2026-10-25): the first P1 revision tied RESET_N high
    // permanently and photo mode came up black. Root cause, from the vendor
    // RTL: the port-register block loads its reset-time values (ALL FOUR port
    // LENGTHs = 128) only while RESET_N is low, and the READ side of the
    // arbiter has no LENGTH==0 guard (the write side does). Without a reset
    // pulse rRD1_LENGTH powers up at 0, and the arbiter spins on zero-length
    // RD1 services forever - RD2 and WR2 are never scheduled, the player sees
    // rd2_empty forever and the photo path stays black (games are unaffected,
    // they never touch SDRAM). The R85 double-framebuffer produced this pulse
    // incidentally via its C_RESET_A state. Restore it: hold the controller in
    // reset ~10 ms, then release forever. After release RD1 issues one
    // 128-word burst, its FIFO reports almost-full and the port parks - the
    // exact post-reset state R85 ran in.
    // -------------------------------------------------------------------------
    reg [19:0] por_cnt;
    always @(posedge sdram_ctrl_clk) begin
        if (por_cnt != 20'd999_999)
            por_cnt <= por_cnt + 20'd1;
    end
    wire ctrl_reset_n = (por_cnt == 20'd999_999) && !(ENABLE_MJPEG && rst);   // ~10 ms @ 100 MHz

    // -------------------------------------------------------------------------
    // Vendor 4-port controller (contains Sdram_PLL: 50 MHz -> 100 MHz CTRL +
    // phase-shifted SDR_CLK). WR1/RD1 parked as described in the header.
    // -------------------------------------------------------------------------
    assign o_mem_clk=sdram_ctrl_clk;assign o_mem_ready=ctrl_reset_n;
    yingxu_sdram_control_4port #(.MJPEG_PORT(ENABLE_MJPEG)) U_sdram_ctrl (
        .MJ_ACTIVE(i_mj_active),.MJ_VALID(i_mj_valid),.MJ_READY(o_mj_ready),.MJ_WRITE(i_mj_write),
        .MJ_ADDR(i_mj_addr),.MJ_WORDS(i_mj_words),.MJ_WVALID(i_mj_wvalid),.MJ_WREADY(o_mj_wready),
        .MJ_WDATA(i_mj_wdata),.MJ_WLAST(i_mj_wlast),.MJ_RVALID(o_mj_rvalid),.MJ_RREADY(i_mj_rready),
        .MJ_RDATA(o_mj_rdata),.MJ_RLAST(o_mj_rlast),.MJ_DONE(o_mj_done),.MJ_ERROR(o_mj_error),.MJ_IDLE(o_mj_idle),.MJ_DEBUG_WRITE(o_mj_debug_write),
        .REF_CLK      (sys_clk),
        .RESET_N      (ctrl_reset_n),
        .CLK          (sdram_ctrl_clk),

        .WR1_DATA     (32'd0),
        .WR1          (1'b0),
        .WR1_ADDR     (21'd0),
        .WR1_MAX_ADDR (21'd0),
        .WR1_LENGTH   (9'd0),
        .WR1_LOAD     (1'b0),
        .WR1_CLK      (sdram_ctrl_clk),
        .WR1_FULL     (o_wr1_full),
        .WR1_USE      (),

        .WR2_DATA     (i_wr2_data),
        .WR2          (i_wr2_en),
        .WR2_ADDR     (i_wr2_addr),
        .WR2_MAX_ADDR (i_wr2_max_addr),
        .WR2_LENGTH   (i_wr2_len),
        .WR2_LOAD     (i_wr2_load),
        .WR2_CLK      (sys_clk),
        .WR2_FULL     (o_wr2_full),
        .WR2_USE      (),

        .RD1_DATA     (),
        .RD1          (1'b0),
        .RD1_ADDR     (21'd0),
        .RD1_MAX_ADDR (21'd0),
        .RD1_LENGTH   (9'd0),
        .RD1_LOAD     (1'b0),
        .RD1_CLK      (pixel_clk),
        .RD1_EMPTY    (),
        .RD1_USE      (),

        .RD2_DATA     (o_rd2_data),
        .RD2          (i_rd2_en),
        .RD2_ADDR     (i_rd2_addr),
        .RD2_MAX_ADDR (i_rd2_max_addr),
        .RD2_LENGTH   (i_rd2_len),
        .RD2_LOAD     (i_rd2_load),
        .RD2_CLK      (pixel_clk),
        .RD2_EMPTY    (o_rd2_empty),
        .RD2_USE      (),

        .SA           (sdram_sa),
        .BA           (sdram_ba),
        .CS_N         (sdram_cs_n),
        .CKE          (sdram_cke),
        .RAS_N        (sdram_ras_n),
        .CAS_N        (sdram_cas_n),
        .WE_N         (sdram_we_n),
        .DQ           (sdram_dq),
        .DQM          (sdram_dqm),
        .SDR_CLK      (sdram_sdr_clk),
        .test_oe      ()
    );

    sdram_ip U_sdram_ip (
        .clk   (sdram_sdr_clk),
        .ras_n (sdram_ras_n),
        .cas_n (sdram_cas_n),
        .we_n  (sdram_we_n),
        .addr  (sdram_sa),
        .ba    (sdram_ba),
        .dq    (sdram_dq),
        .cs_n  (sdram_cs_n),
        .dm0   (ENABLE_MJPEG ? sdram_dqm[0]:1'b0),
        .dm1   (ENABLE_MJPEG ? sdram_dqm[1]:1'b0),
        .dm2   (ENABLE_MJPEG ? sdram_dqm[2]:1'b0),
        .dm3   (ENABLE_MJPEG ? sdram_dqm[3]:1'b0),
        .cke   (sdram_cke)
    );

    // H_TOTAL/V_TOTAL/V_ACTIVE parametrize the old reader; they only size the
    // (now removed) logic. Keep a reference so tools do not warn.
    wire [31:0] _unused_params = H_TOTAL + H_ACTIVE + V_TOTAL + V_ACTIVE;

endmodule

`default_nettype wire
