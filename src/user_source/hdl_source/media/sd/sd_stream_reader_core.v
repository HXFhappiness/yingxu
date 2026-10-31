`timescale 1ns / 1ps
`default_nettype none
// P1 experiment B: diagnostic source only; not an accepted firmware.

//------------------------------------------------------------------------------
// 项目名称 : 映序 YingXu
// 文件名称 : sd_stream_reader_core.v
// 模块名称 : sd_stream_reader_core
// 功能说明 : 在原厂单 Sector SD 控制器之上增加连续多 Sector 调度，
//            将多个 512 Byte Sector 转换成按文件顺序连续的 Byte Stream。
//            本模块不重写 SPI/SD 协议，只负责：初始化、逐扇区调度、
//            RD_RAM 地址读取、跨 Sector 连续 byte_offset、ready/valid 握手。
// 时钟说明 : clk
// 复位说明 : rst，高有效
// 版本      : V0.4A-A R1
//------------------------------------------------------------------------------
//
// 控制器抽象接口约定：
//   ctrl_mode = 0 : SD 初始化
//   ctrl_mode = 2 : 读取一个 Sector 到控制器内部 RD_RAM
//   ctrl_start     : 单周期启动脉冲
//   ctrl_done      : 当前控制器事务完成脉冲
//
// 数据流：
//   Sector N[0..511] -> Sector N+1[0..511] -> ...
//
// RD_RAM 为同 clk 的一拍同步读。DRAIN_1CYC=1 时 SET 只预取首字节，
// GET 成功握手的同一边沿预读下一地址，随后每拍吐一字节。
// ready=0 时读地址回到当前字节，RAM 重读同址，输出数据/元数据保持；
// 不存在额外未接收的预读返回，因此无需修改厂商 RAM 或增加 skid FIFO。
// DRAIN_1CYC=0 保留原 SET/GET 两拍路径，便于逐字节 A/B 回归。
//------------------------------------------------------------------------------

module sd_stream_reader_core #(
    parameter integer DRAIN_1CYC = 1
)(
    input  wire         clk,
    input  wire         rst,

    // 上层事务控制
    input  wire         start,
    input  wire [27:0]  start_sector,
    input  wire [15:0]  sector_count,

    // 对原厂 sd_card_control 的抽象控制接口
    output reg          ctrl_start,
    output reg  [1:0]   ctrl_mode,
    output reg  [27:0]  ctrl_sector_addr,
    input  wire         ctrl_done,
    output wire [8:0]   ctrl_rd_ram_addr,
    input  wire [7:0]   ctrl_rd_ram_data,

    // 连续 Byte Stream
    output wire [7:0]   stream_data,
    output wire         stream_valid,
    input  wire         stream_ready,
    output wire         stream_first,
    output wire         stream_last,
    output wire [31:0]  stream_byte_offset,
    output wire [27:0]  stream_sector_addr,
    output wire [8:0]   stream_sector_byte_addr,

    // 状态
    output reg          init_done,
    output reg          busy,
    output reg          done
);

    localparam [3:0] ST_INIT_START = 4'd0;
    localparam [3:0] ST_INIT_WAIT  = 4'd1;
    localparam [3:0] ST_IDLE       = 4'd2;
    localparam [3:0] ST_READ_START = 4'd3;
    localparam [3:0] ST_READ_WAIT  = 4'd4;
    localparam [3:0] ST_DRAIN_SET  = 4'd5;
    localparam [3:0] ST_DRAIN_GET  = 4'd6;

    reg [3:0]  state;
    reg [27:0] current_sector;
    reg [15:0] sectors_left;
    reg [8:0]  drain_addr;
    reg [31:0] byte_count;

    // drain_addr 始终是当前输出字节号。只有本拍真的接受该字节时，
    // 才将下一地址送到同步 RAM，使下一拍数据与递增后的 drain_addr 对齐。
    // stall 时地址不自增；511 不回绕预读，防止末字节被地址 0 覆盖。
    wire drain_advance = (DRAIN_1CYC != 0) &&
                         (state == ST_DRAIN_GET) && stream_ready &&
                         (drain_addr != 9'd511);
    assign ctrl_rd_ram_addr = drain_advance ? (drain_addr + 9'd1) : drain_addr;

    // stream_valid 只有在同步 RAM 数据已经准备好的 GET 状态有效。
    assign stream_valid           = (state == ST_DRAIN_GET);
    assign stream_data            = ctrl_rd_ram_data;
    assign stream_byte_offset     = byte_count;
    assign stream_sector_addr     = current_sector;
    assign stream_sector_byte_addr= drain_addr;
    assign stream_first           = stream_valid && (byte_count == 32'd0);
    assign stream_last            = stream_valid &&
                                    (sectors_left == 16'd1) &&
                                    (drain_addr == 9'd511);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= ST_INIT_START;
            ctrl_start       <= 1'b0;
            ctrl_mode        <= 2'd0;
            ctrl_sector_addr <= 28'd0;
            current_sector   <= 28'd0;
            sectors_left     <= 16'd0;
            drain_addr       <= 9'd0;
            byte_count       <= 32'd0;
            init_done        <= 1'b0;
            busy             <= 1'b1;
            done             <= 1'b0;
        end
        else begin
            // 脉冲型输出默认拉低，只在对应状态拉高一个周期。
            ctrl_start <= 1'b0;
            done       <= 1'b0;

            case (state)
                ST_INIT_START: begin
                    busy             <= 1'b1;
                    ctrl_mode        <= 2'd0;
                    ctrl_sector_addr <= 28'd0;
                    ctrl_start       <= 1'b1;
                    state            <= ST_INIT_WAIT;
                end

                ST_INIT_WAIT: begin
                    if (ctrl_done) begin
                        init_done <= 1'b1;
                        busy      <= 1'b0;
                        state     <= ST_IDLE;
                    end
                end

                ST_IDLE: begin
                    busy <= 1'b0;

                    // sector_count=0 视为无效请求，不启动任何 SD 事务。
                    if (start && (sector_count != 16'd0)) begin
                        current_sector   <= start_sector;
                        ctrl_sector_addr <= start_sector;
                        sectors_left     <= sector_count;
                        drain_addr       <= 9'd0;
                        byte_count       <= 32'd0;
                        busy             <= 1'b1;
                        state            <= ST_READ_START;
                    end
                end

                ST_READ_START: begin
                    // 每次只要求原厂控制器读取一个 Sector。
                    ctrl_mode        <= 2'd2;
                    ctrl_sector_addr <= current_sector;
                    ctrl_start       <= 1'b1;
                    state            <= ST_READ_WAIT;
                end

                ST_READ_WAIT: begin
                    // 单 Sector 已经完整进入原厂 RD_RAM 后再开始向上层吐数据。
                    if (ctrl_done) begin
                        drain_addr <= 9'd0;
                        state      <= ST_DRAIN_SET;
                    end
                end

                ST_DRAIN_SET: begin
                    // 原厂 RD_RAM 是同步读：本拍给地址，下一拍 GET 数据。
                    state <= ST_DRAIN_GET;
                end

                ST_DRAIN_GET: begin
                    // 标准 ready/valid：未 ready 时保持当前地址和数据，不丢 Byte。
                    if (stream_ready) begin
                        if (drain_addr == 9'd511) begin
                            if (sectors_left == 16'd1) begin
                                // 最后一个 Sector 的最后一个 Byte 被成功接收。
                                byte_count   <= byte_count + 32'd1;
                                sectors_left <= 16'd0;
                                busy         <= 1'b0;
                                done         <= 1'b1;
                                state        <= ST_IDLE;
                            end
                            else begin
                                // 当前 Sector 完成，切换到下一个连续 Sector。
                                byte_count       <= byte_count + 32'd1;
                                current_sector   <= current_sector + 28'd1;
                                ctrl_sector_addr <= current_sector + 28'd1;
                                sectors_left     <= sectors_left - 16'd1;
                                drain_addr       <= 9'd0;
                                state            <= ST_READ_START;
                            end
                        end
                        else begin
                            // 当前 Byte 接收完成，准备下一个 RAM 地址。
                            byte_count <= byte_count + 32'd1;
                            drain_addr <= drain_addr + 9'd1;
                            state      <= ST_DRAIN_SET;
                        end
                    end
                end

                default: begin
                    state      <= ST_INIT_START;
                    init_done  <= 1'b0;
                    busy       <= 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
