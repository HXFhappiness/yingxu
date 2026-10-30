`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// 项目名称 : 映序 YingXu
// 文件名称 : sd_stream_reader.v
// 模块名称 : sd_stream_reader
// 功能说明 : V0.4A-A 硬件包装层。
//            复用原厂 sd_card_control，并接入 sd_stream_reader_core，
//            对外直接输出连续多 Sector Byte Stream。
// 版本      : V0.4A-A R1
//------------------------------------------------------------------------------

module sd_stream_reader #(
    parameter CLOCK_FREQ    = 50_000_000,
    parameter SPI_LOWFREQ   = 400_000,
    parameter SPI_HIGHFREQ  = 25_000_000,
    parameter SPI_DIV_WIDTH = (CLOCK_FREQ / (SPI_LOWFREQ * 2)) > 0 ? $clog2(CLOCK_FREQ / (SPI_LOWFREQ * 2)) : 1
) (
    output wire         mosi,
    output wire         sclk,
    output wire         cs_n,
    input  wire         miso,

    input  wire         clk,
    input  wire         rst,

    input  wire         start,
    input  wire [27:0]  start_sector,
    input  wire [15:0]  sector_count,

    output wire [7:0]   stream_data,
    output wire         stream_valid,
    input  wire         stream_ready,
    output wire         stream_first,
    output wire         stream_last,
    output wire [31:0]  stream_byte_offset,
    output wire [27:0]  stream_sector_addr,
    output wire [8:0]   stream_sector_byte_addr,

    output wire         init_done,
    output wire         busy,
    output wire         done,

    // Debug-only signals exported from the original SD/SPI controller.
    output wire                         dbg_spi_clk,
    output wire [SPI_DIV_WIDTH-1:0]     dbg_spi_div_value,
    output wire [SPI_DIV_WIDTH-1:0]     dbg_spi_div_counter,
    output wire [2:0]                   dbg_ctrl_state,
    output wire [1:0]                   dbg_select_num,
    output wire                         dbg_spi_start,
    output wire                         dbg_spi_next,
    output wire                         dbg_spi_done,
    output wire [3:0]                   dbg_init_state,
    output wire [39:0]                  dbg_init_response,
    output wire                         dbg_spi_driver_state,
    output wire [3:0]                   dbg_spi_driver_count,
    output wire [2:0]                   dbg_read_state,
    output wire [7:0]                   dbg_read_spi_rec_data,
    output wire                         dbg_read_addr_done,
    output wire                         dbg_read_data_done
);

    wire        ctrl_start;
    wire [1:0]  ctrl_mode;
    wire [27:0] ctrl_sector_addr;
    wire        ctrl_done;
    wire [8:0]  ctrl_rd_ram_addr;
    wire [7:0]  ctrl_rd_ram_data;

    // 连续 Sector 调度核心：只负责事务调度和 Byte Stream 语义。
    sd_stream_reader_core U_STREAM_CORE (
        .clk                    (clk),
        .rst                    (rst),

        .start                  (start),
        .start_sector           (start_sector),
        .sector_count           (sector_count),

        .ctrl_start             (ctrl_start),
        .ctrl_mode              (ctrl_mode),
        .ctrl_sector_addr       (ctrl_sector_addr),
        .ctrl_done              (ctrl_done),
        .ctrl_rd_ram_addr       (ctrl_rd_ram_addr),
        .ctrl_rd_ram_data       (ctrl_rd_ram_data),

        .stream_data            (stream_data),
        .stream_valid           (stream_valid),
        .stream_ready           (stream_ready),
        .stream_first           (stream_first),
        .stream_last            (stream_last),
        .stream_byte_offset     (stream_byte_offset),
        .stream_sector_addr     (stream_sector_addr),
        .stream_sector_byte_addr(stream_sector_byte_addr),

        .init_done              (init_done),
        .busy                   (busy),
        .done                   (done)
    );

    // 原厂 SD 控制器保持不改。mode=0 初始化，mode=2 单 Sector 读取。
    sd_card_control #(
        .clock_freq  (CLOCK_FREQ),
        .spi_lowfreq (SPI_LOWFREQ),
        .spi_highfreq(SPI_HIGHFREQ),
        .spi_div_width(SPI_DIV_WIDTH)
    ) U_SD_CTRL (
        .mosi        (mosi),
        .sclk        (sclk),
        .cs_n        (cs_n),
        .idle        (),
        .done        (ctrl_done),

        .rd_ram_dout (ctrl_rd_ram_data),
        .rd_ram_addr (ctrl_rd_ram_addr),

        .wr_ram_din  (8'd0),
        .wr_ram_addr (9'd0),
        .wr_ram_wea  (1'b0),

        .sector_addr (ctrl_sector_addr),
        .miso        (miso),
        .start       (ctrl_start),
        .mode        (ctrl_mode),
        .clk         (clk),
        .rst         (rst),
        .dbg_spi_clk          (dbg_spi_clk),
        .dbg_spi_div_value    (dbg_spi_div_value),
        .dbg_spi_div_counter  (dbg_spi_div_counter),
        .dbg_ctrl_state       (dbg_ctrl_state),
        .dbg_select_num       (dbg_select_num),
        .dbg_spi_start        (dbg_spi_start),
        .dbg_spi_next         (dbg_spi_next),
        .dbg_spi_done         (dbg_spi_done),
        .dbg_init_state       (dbg_init_state),
        .dbg_init_response    (dbg_init_response),
        .dbg_spi_driver_state (dbg_spi_driver_state),
        .dbg_spi_driver_count (dbg_spi_driver_count),
        .dbg_read_state       (dbg_read_state),
        .dbg_read_spi_rec_data(dbg_read_spi_rec_data),
        .dbg_read_addr_done   (dbg_read_addr_done),
        .dbg_read_data_done   (dbg_read_data_done)
    );

endmodule

`default_nettype wire
