`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// ???? : ?? YingXu
// ???? : yingxu_sd_integration_probe.v
// ???? : yingxu_sd_integration_probe
// ??      : V0.4A-A R1 Integration
// ???? : V0.3 ????? V0.4A-A ?? Sector Reader ??????????
//            ?? BMP??? SDRAM ?????? SD ??????? Sector ???
//            SW6 ? 0 ?? 1 ???? BMP ?? Sector?LBA 32672?? 512 Byte ????? Header Parser ??? 54 Byte?
//            ?? Byte ?????? ready ?????? offset ????
//------------------------------------------------------------------------------

module yingxu_sd_integration_probe #(
    parameter CLOCK_FREQ   = 50_000_000,
    parameter START_SECTOR = 28'd32672, // default only
    parameter DYNAMIC_COUNT = 0,
    parameter SECTOR_COUNT = 16'd1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        trigger_sw,
    input  wire [27:0] start_sector,
    input  wire        restart,
    input wire legacy_inhibit, // D4c: cancel queued starts, never interrupt a busy sector
    input wire dynamic_enable,
    input wire [15:0] dynamic_count,
    output wire transaction_done,


    // Byte stream export for the SD->SDRAM->HDMI display path.
    output wire [7:0]  out_stream_data,
    output wire        out_stream_valid,
    input  wire        out_stream_ready,

    input  wire        sd_miso,
    output wire        sd_mosi,
    output wire        sd_sclk,
    output wire        sd_cs_n,

    output wire        dbg_init_done,
    output wire        dbg_busy,
    output reg         dbg_done_latched,
    output reg         dbg_error_latched,
    output reg [21:0]  dbg_accept_count,
    output reg [7:0]   dbg_byte_510,
    output reg [7:0]   dbg_byte_511,
    output reg [7:0]   dbg_byte_512,
    output reg [7:0]   dbg_byte_513,
    output wire        dbg_bmp_header_valid,
    output reg         dbg_bmp_header_done_latched,
    output wire        dbg_bmp_format_ok,
    output wire [31:0] dbg_bmp_width,
    output wire [31:0] dbg_bmp_height,
    output wire [15:0] dbg_bmp_bpp,
    output wire [31:0] dbg_bmp_pixel_offset,
    output wire [7:0]  dbg_stream_data,
    output wire        dbg_stream_valid,
    output wire [31:0] dbg_stream_offset,
    output wire [27:0] dbg_stream_sector,
    output wire [8:0]  dbg_stream_sector_byte,

    // Low-level SD/SPI debug taps exported to the project top.
    output wire        dbg_spi_clk,
    output wire [5:0]  dbg_spi_div_value,
    output wire [5:0]  dbg_spi_div_counter,
    output wire [2:0]  dbg_ctrl_state,
    output wire [1:0]  dbg_select_num,
    output wire        dbg_spi_start,
    output wire        dbg_spi_next,
    output wire        dbg_spi_done,
    output wire [3:0]  dbg_init_state,
    output wire [39:0] dbg_init_response,
    output wire        dbg_spi_driver_state,
    output wire [3:0]  dbg_spi_driver_count,
    output wire [2:0]   dbg_read_state,
    output wire [7:0]   dbg_read_spi_rec_data,
    output reg          dbg_addr_done_seen,
    output reg          dbg_data_done_seen
);

    reg  sw_meta;
    reg  sw_sync;
    reg  sw_prev;
    reg  auto_trig_done;   // DEBUG ONLY: one-shot auto trigger

    wire trigger_rise;
    wire reader_start;
    wire reader_done;
    assign transaction_done=reader_done;
    wire stream_first;
    wire stream_last;
    wire read_addr_done_pulse;
    wire read_data_done_pulse;
    wire [2:0] read_state_spi;
    wire [7:0] read_spi_rec_data_spi;
    reg  [2:0] read_state_meta, read_state_sync;
    reg  [7:0] read_spi_rec_data_meta, read_spi_rec_data_sync;
    reg  read_addr_done_meta, read_addr_done_sync;
    reg  read_data_done_meta, read_data_done_sync;

    assign dbg_read_state        = read_state_sync;
    assign dbg_read_spi_rec_data = read_spi_rec_data_sync;

    // Export the raw byte stream so the framebuffer path can consume it.
    assign out_stream_data  = dbg_stream_data;
    assign out_stream_valid = dbg_stream_valid;

    // SW6 ?????????????????????? init_done ???????
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sw_meta <= 1'b0;
            sw_sync <= 1'b0;
            sw_prev <= 1'b0;
        end
        else begin
            sw_meta <= trigger_sw;
            sw_sync <= sw_meta;
            sw_prev <= sw_sync;
        end
    end

    // Original behaviour: SW6 rising edge only. No auto trigger.
    // SW6: either edge triggers. The switch position is inverted w.r.t. the pin
    // level on this board, so an edge-only detector avoids polarity confusion.
    // A ~21 ms lockout swallows mechanical bounce.
    wire sw_edge = sw_sync ^ sw_prev;
    reg [19:0] sw_lock;
    always @(posedge clk or posedge rst) begin
        if (rst)                   sw_lock <= 20'd0;
        else if (sw_edge)          sw_lock <= 20'hFFFFF;
        else if (sw_lock != 20'd0) sw_lock <= sw_lock - 20'd1;
    end

    // Restart latch: cart restart_pend is a 1-cycle pulse that races with the
    // photo carousel's load_start (both fire ~4 s after boot when sd_seen rises).
    // When they merge, the cart's L_IDLE transition consumes restart_pend while
    // the core was busy -> the pulse is lost and the cart stalls in L_IDLE forever.
    // Holding restart until reader_start actually fires fixes it for all sources.
    reg restart_hold;
    always @(posedge clk or posedge rst) begin
        if (rst)                restart_hold <= 1'b0;
        else if (DYNAMIC_COUNT && legacy_inhibit) restart_hold <= 1'b0;
        else if (restart)       restart_hold <= 1'b1;
        else if (reader_start)  restart_hold <= 1'b0;
    end

    assign trigger_rise  = (sw_edge & (sw_lock == 20'd0)) | restart_hold;
    // init_done is automatic power-on initialization; reader_done/DNE is a
    // separate read terminal. Handoff blocks/cancels starts, never init clocks.
    assign reader_start = trigger_rise & dbg_init_done & ~dbg_busy &
                          ~(DYNAMIC_COUNT && legacy_inhibit);

    // ??? Sector Reader????? SD/SPI ????????????? 50 MHz?
    sd_stream_reader #(
        .CLOCK_FREQ   (CLOCK_FREQ),
        .SPI_LOWFREQ  (400_000),
        // ?? clk_div_var ? one_allow=0 ????? div=1?
        // 50 MHz ????? 25 MHz ??? spi_high_div=1 ???? SPI ?????
        // R1 Integration ??? 12.5 MHz SCLK??????? RTL ?????
        .SPI_HIGHFREQ (12_500_000) // Board accepted: 12.5MHz, legacy two-cycle drain
    ) U_SD_STREAM (
        .mosi                   (sd_mosi),
        .sclk                   (sd_sclk),
        .cs_n                   (sd_cs_n),
        .miso                   (sd_miso),
        .clk                    (clk),
        .rst                    (rst),
        .start                  (reader_start),
        .start_sector           (start_sector),
        .sector_count           ((DYNAMIC_COUNT && dynamic_enable) ? dynamic_count:SECTOR_COUNT),
        .stream_data            (dbg_stream_data),
        .stream_valid           (dbg_stream_valid),
        .stream_ready           (out_stream_ready),
        .stream_first           (stream_first),
        .stream_last            (stream_last),
        .stream_byte_offset     (dbg_stream_offset),
        .stream_sector_addr     (dbg_stream_sector),
        .stream_sector_byte_addr(dbg_stream_sector_byte),
        .init_done              (dbg_init_done),
        .busy                   (dbg_busy),
        .done                   (reader_done),
        .dbg_spi_clk            (dbg_spi_clk),
        .dbg_spi_div_value      (dbg_spi_div_value),
        .dbg_spi_div_counter    (dbg_spi_div_counter),
        .dbg_ctrl_state         (dbg_ctrl_state),
        .dbg_select_num         (dbg_select_num),
        .dbg_spi_start          (dbg_spi_start),
        .dbg_spi_next           (dbg_spi_next),
        .dbg_spi_done           (dbg_spi_done),
        .dbg_init_state         (dbg_init_state),
        .dbg_init_response      (dbg_init_response),
        .dbg_spi_driver_state   (dbg_spi_driver_state),
        .dbg_spi_driver_count   (dbg_spi_driver_count),
        .dbg_read_state         (read_state_spi),
        .dbg_read_spi_rec_data  (read_spi_rec_data_spi),
        .dbg_read_addr_done     (read_addr_done_pulse),
        .dbg_read_data_done     (read_data_done_pulse)
    );

    // BMP Header Parser: reader_start is asserted well before the first stream
    // byte appears (the SD sector must be fetched into RD_RAM first).
    // The parser observes the same complete file-order stream as the byte probes.
    wire bmp_header_valid_pulse;
    bmp_header_parser U_BMP_HEADER_PARSER (
        .clk          (clk),
        .rst_n        (~rst),
        .data         (dbg_stream_data),
        .valid        (dbg_stream_valid),
        .start        (reader_start),
        .width        (dbg_bmp_width),
        .height       (dbg_bmp_height),
        .bpp          (dbg_bmp_bpp),
        .pixel_offset (dbg_bmp_pixel_offset),
        .header_valid (bmp_header_valid_pulse),
        .format_ok    (dbg_bmp_format_ok)
    );
    assign dbg_bmp_header_valid = bmp_header_valid_pulse;

    always @(posedge clk or posedge rst) begin
        if (rst)
            dbg_bmp_header_done_latched <= 1'b0;
        else if (reader_start)
            dbg_bmp_header_done_latched <= 1'b0;
        else if (bmp_header_valid_pulse)
            dbg_bmp_header_done_latched <= 1'b1;
    end

    // Synchronize the read-state/RX bus and one-cycle done pulses from the divided SPI clock domain.
    // Sticky flags are cleared on each SW6-triggered read transaction.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            read_state_meta          <= 3'd0;
            read_state_sync          <= 3'd0;
            read_spi_rec_data_meta   <= 8'hFF;
            read_spi_rec_data_sync   <= 8'hFF;
            read_addr_done_meta      <= 1'b0;
            read_addr_done_sync      <= 1'b0;
            read_data_done_meta      <= 1'b0;
            read_data_done_sync      <= 1'b0;
            dbg_addr_done_seen       <= 1'b0;
            dbg_data_done_seen  <= 1'b0;
        end
        else begin
            read_state_meta        <= read_state_spi;
            read_state_sync        <= read_state_meta;
            read_spi_rec_data_meta <= read_spi_rec_data_spi;
            read_spi_rec_data_sync <= read_spi_rec_data_meta;
            read_addr_done_meta    <= read_addr_done_pulse;
            read_addr_done_sync    <= read_addr_done_meta;
            read_data_done_meta    <= read_data_done_pulse;
            read_data_done_sync    <= read_data_done_meta;

            if (reader_start) begin
                dbg_addr_done_seen <= 1'b0;
                dbg_data_done_seen <= 1'b0;
            end
            else begin
                if (read_addr_done_sync) dbg_addr_done_seen <= 1'b1;
                if (read_data_done_sync) dbg_data_done_seen <= 1'b1;
            end
        end
    end

    // ????????????? Byte???? Sector ???? 4 Byte?
    // ??????????? 512 Byte?offset ?? 0~511?
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dbg_done_latched  <= 1'b0;
            dbg_error_latched <= 1'b0;
            dbg_accept_count  <= 22'd0;
            dbg_byte_510      <= 8'd0;
            dbg_byte_511      <= 8'd0;
            dbg_byte_512      <= 8'd0;
            dbg_byte_513      <= 8'd0;
        end
        else begin
            if (reader_start) begin
                dbg_done_latched  <= 1'b0;
                dbg_error_latched <= 1'b0;
                dbg_accept_count  <= 22'd0;
                dbg_byte_510      <= 8'd0;
                dbg_byte_511      <= 8'd0;
                dbg_byte_512      <= 8'd0;
                dbg_byte_513      <= 8'd0;
            end

            if (dbg_stream_valid) begin
                // byte_offset ??????????????????? Sector ????/????
                if (dbg_stream_offset != {21'd0, dbg_accept_count})
                    dbg_error_latched <= 1'b1;

                if (dbg_stream_offset == 32'd0)
                    dbg_byte_510 <= dbg_stream_data; // BMP byte 0: 'B'
                if (dbg_stream_offset == 32'd1)
                    dbg_byte_511 <= dbg_stream_data; // BMP byte 1: 'M'
                if (dbg_stream_offset == 32'd2)
                    dbg_byte_512 <= dbg_stream_data; // BMP byte 2
                if (dbg_stream_offset == 32'd3)
                    dbg_byte_513 <= dbg_stream_data; // BMP byte 3

                // ?????? Sector ?????? 512 Byte?
                if (dbg_accept_count < (SECTOR_COUNT * 512))
                    dbg_accept_count <= dbg_accept_count + 22'd1;
                else
                    dbg_error_latched <= 1'b1;

                if (stream_last && (dbg_stream_offset != (SECTOR_COUNT * 512 - 1)))
                    dbg_error_latched <= 1'b1;
            end

            // reader_done ????? Byte ?????????? count ???? 512?
            if (reader_done) begin
                dbg_done_latched <= 1'b1;
                if (dbg_accept_count != (SECTOR_COUNT * 512))
                    dbg_error_latched <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire