`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// sd_multi_reader — 映序 SD 高速多扇区读取引擎（YX-SD v2）
//
// 与厂商 sd_card_control 并行的第二条读通路（厂商文件零改动）：
//   * 自带 spi_driver + clk_div_var(one_allow=1)；
//   * 两相位时钟：命令相位 6.25 MHz（板上已验证），数据相位 25 MHz（div=1）。
//     厂商控制器 clk_div_var one_allow=0 在 div=1 时 SCLK 恒低——那是当年
//     25 MHz 失败的 RTL 侧根因；本引擎用独立分频器绕开；
//   * 首次使用做速度探测：CMD16(512) → CMD17@fast 读首扇区 + CRC16 校验。
//     探测失败（真实卡跑不动 25 MHz）→ probe_fail（未吐任何字节），
//     请求由仲裁器交回厂商路径，fast_broken 粘滞到复位；
//   * 多扇区 CMD18 连读，块间链式不落链，CRC16 逐块校验，CMD12 停止；
//   * 512B 弹性 FIFO + 字节边界暂停：消费者反压（FIFO≥500）时在字节边界
//     停 SCLK（SPI 全静态，卡保持 MISO），水位 ≤384 自动续读——
//     不需要厂商 RD_RAM 中转。块尾 1 字节 dummy（N_EC）再动 CS，
//     CS 抬高期间 1 字节 dummy 满足 NCC≥8 clk，与厂商 515 字节计数对齐。
//
// spi_start 为组合式"按状态发射"：处于需要发起字节的状态且驱动器空闲时
// 保持为 1，驱动器在首个 ce 沿取走后自动忽略（start 仅在 IDLE 被采样），
// 因此分频切换造成的 ce 相位差不会丢启动。
//
// 流契约与 sd_stream_reader_core 完全一致。时钟：单域 clk（50 MHz）。
//
// 已知边界：CMD18 链中期的 CRC 失败在已吐出部分字节后中止（err 置位，
// 本请求作废，下游以 accept_count 校验捕获）；探测期失败则在任何字节
// 吐出前返回，由仲裁器无缝回退。
//------------------------------------------------------------------------------
module sd_multi_reader #(
    parameter CLOCK_FREQ     = 50_000_000,
    parameter SPI_CMD_FREQ   =  6_250_000,
    parameter SPI_DATA_FREQ  = 25_000_000,
    parameter DIV_CMD        = CLOCK_FREQ / (2 * SPI_CMD_FREQ),   // 4 @50M
    parameter DIV_DATA       = CLOCK_FREQ / (2 * SPI_DATA_FREQ),  // 1 @50M
    parameter TOKEN_TIMEOUT  = 1024,
    parameter R1_TIMEOUT     = 15
) (
    input  wire        clk,
    input  wire        rst,

    output wire        mosi,
    output wire        sclk,
    output reg         cs_n,
    input  wire        miso,

    input  wire        start,
    input  wire [27:0] start_sector,
    input  wire [15:0] sector_count,

    output wire [7:0]  stream_data,
    output wire        stream_valid,
    input  wire        stream_ready,
    output wire        stream_first,
    output wire        stream_last,
    output wire [31:0] stream_byte_offset,
    output wire [27:0] stream_sector_addr,
    output wire [8:0]  stream_sector_byte_addr,

    output wire        busy,
    output reg         done,          // 单周期：请求结束（成败由 err 区分）
    output reg         err,           // done 时有效：链中期失败，本请求作废
    output reg         probe_fail,    // 单周期：探测失败（未吐字节，可无缝回退）
    output wire        fast_ok,       // 探测通过且未 broken
    output wire        fast_broken,   // 探测失败/数据相失败（粘滞）

    output wire [3:0]  dbg_state,
    output wire [3:0]  dbg_div,
    output wire        dbg_paused
);

    // ---------------- 状态 ----------------
    localparam [3:0] S_IDLE     = 4'd0,
                     S_CMD      = 4'd1,   // 发 6 字节命令
                     S_R1       = 4'd2,   // 收 R1（找 bit7==0）
                     S_TOKEN    = 4'd3,   // 扫数据 token 0xFE
                     S_DATA     = 4'd4,   // 收 512 数据字节
                     S_CRC      = 4'd5,   // 收 2 字节 CRC
                     S_DUMMY    = 4'd6,   // 链尾 dummy 字节（N_EC）
                     S_CS_UP    = 4'd7,   // CS 高 + 1 dummy（NCC），随后下条命令
                     S_STOP12   = 4'd8,   // 发 CMD12（仅提前终止用）
                     S_STOP12R1 = 4'd9,   // CMD12 的 R1 + 收尾
                     S_FLUSH    = 4'd10,  // 等 FIFO 排空再报告 done
                     S_DRAIN    = 4'd11;  // 探测缓冲排水（CRC 判定后首扇区数据出流）
    localparam [1:0] K_CMD16 = 2'd0, K_CMD17 = 2'd1,
                     K_CMD18 = 2'd2, K_CMD12 = 2'd3;

    assign dbg_state = state;
    reg [3:0] state;

    // ---- 探测缓冲（512×8）：探测期字节暂存，CRC 判定后排水或弃用 ----
    // 原设计靠 512B FIFO 在判定前扣住字节（S_CRC 失败分支"FIFO 弃之不用"）；
    // 台账 #8 删 FIFO 改直推后，探测失败时首扇区 512 字节已外流，回退后
    // 消费者看到 512+8192 错位流（+crcerr 场景 DATA1 失败）。此缓冲恢复语义。
    reg [7:0]  probe_buf [0:511];
    reg [9:0]  probe_ra;
    reg        probe_drain;

    // ---------------- SPI 时钟（独立分频，one_allow=1） ----------------
    wire spi_en;
    reg  [3:0] div_value;
    assign dbg_div = div_value;

    clk_div_var #(.div_width(4), .one_allow(1)) U_DIV (
        .clk_out   (spi_en),
        .div_value (div_value),
        .clk_in    (clk),
        .rst       (rst),
        .dbg_cnt_value ()
    );

    reg spi_en_d;
    wire ce;
    always @(posedge clk or posedge rst) begin
        if (rst) spi_en_d <= 1'b0;
        else     spi_en_d <= spi_en;
    end
    // div=1 时 clk_out 组合直通 clk_in（时钟本身）：spi_en_d 每个上升沿都采到 1，
    // 边沿检测 ce 恒 0 = 驱动器冻结。数据相位（div_value==1）直接令 ce=1，
    // 每 posedge 推进一位 = 25 Mbit/s；div>1 仍用 clk_out_var 的边沿检测。
    assign ce = (div_value == 4'd1) ? 1'b1 : (spi_en & ~spi_en_d);

    // ---------------- SPI 字节引擎（厂商 spi_driver 原样复用） ----------------
    wire [7:0] rec_data;
    wire       spi_done;
    wire       spi_idle;
    reg  [7:0] send_data;
    reg        spi_next;
    wire       spi_start;

    spi_driver U_SPI (
        .rec_data  (rec_data),
        .mosi      (mosi),
        .sclk      (sclk),
        .idle      (spi_idle),
        .done      (spi_done),
        .send_data (send_data),
        .miso      (miso),
        .mode      (2'b11),
        .start     (spi_start),
        .next      (spi_next),
        .clk       (clk),
        .ce        (ce),
        .rst       (rst),
        .dbg_state (),
        .dbg_cnt_value ()
    );

    // spi_done 在 div>1 时被 ce 拉宽为多周期电平（厂商模块全部用 ce 门控 FSM，
    // 本模块 FSM 跑在 50MHz clk 上），必须取 50MHz 域的单周期脉冲，否则
    // 同一字节会被计数 4 次（r1_cnt 瞬间超时 -> 假 probe_fail）。
    reg  spi_done_d;
    always @(posedge clk or posedge rst) begin
        if (rst) spi_done_d <= 1'b1;
        else     spi_done_d <= spi_done;
    end
    wire spi_done_p = spi_done & ~spi_done_d;

    // ---------------- CRC16-CCITT（poly 0x1021, init 0, MSB first） ----------------
    function [15:0] crc16_byte;
        input [15:0] crc;
        input [7:0]  d;
        integer i;
        reg [15:0] c;
        begin
            c = crc ^ {d, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                c = c[15] ? ({c[14:0], 1'b0} ^ 16'h1021) : {c[14:0], 1'b0};
            crc16_byte = c;
        end
    endfunction

    // ---------------- 数据字节直推（无 FIFO，字节边界暂停） ----------------
    // S_DATA 的每个数据字节经 rec_data 直推 stream_valid，消费者反压时在
    // 字节边界暂停 SPI 时钟（SPI 全静态，卡保持 MISO），恢复后续读。
    // byte_pending：1 = 当前字节待消费者接收。此前用 FIFO 缓冲，跨块竞态
    // 导致 we=1 而记账不动（流输出 0 字节），删 FIFO 后该 bug 类不存在。
    reg        byte_pending;           // 1 = 当前数据字节待接收
    // ---------------- 寄存器组 ----------------
    reg [47:0] cmd_reg;
    reg [2:0]  cmd_cnt;
    reg [1:0]  cmd_kind;                 // 正在交互的命令
    reg [1:0]  next_cmd;                 // 块成功后的去向：0 收尾/1 CS_UP+CMD18/2 CMD12
    reg        r1_stop;                  // R1 命中，等 +1 字节停链
    reg [4:0]  r1_cnt;
    reg [7:0]  r1_value;
    reg [10:0] tok_cnt;
    reg [10:0] data_cnt;
    reg [15:0] crc_calc, crc_rx;
    reg [1:0]  crc_cnt;
    reg [15:0] blocks_left;              // CMD18 尚未确认的块数
    reg [27:0] cur_sector;               // CMD18 当前块扇区号
    reg [15:0] req_count;
    reg [27:0] req_sector;
    reg        probe_phase;              // 本请求第一段（探测 CMD17 块）
    reg        probe_done_r, probe_ok_r, broken_r;
    reg        out_active;
    reg  [1:0] sfl_dbg;
    reg [31:0] out_cnt;
    reg [8:0]  out_byte;
    reg [27:0] out_sector;

    // FIFO 推送/排水使能：内联在 FSM 块中（见 S_DATA 与块尾），
    // 不用独立 wire——iverilog 对前向引用的绑定曾有间歇性问题

    assign busy        = (state != S_IDLE);
    assign fast_ok     = probe_ok_r & ~broken_r;
    assign fast_broken = broken_r;

    // 发送数据：命令阶段按 cmd_cnt 出字节，其余 0xFF
    always @(*) begin
        case (cmd_cnt)
            3'd0: send_data = cmd_reg[47:40];
            3'd1: send_data = cmd_reg[39:32];
            3'd2: send_data = cmd_reg[31:24];
            3'd3: send_data = cmd_reg[23:16];
            3'd4: send_data = cmd_reg[15:8];
            3'd5: send_data = cmd_reg[7:0];
            default: send_data = 8'hFF;
        endcase
        if (state != S_CMD && state != S_STOP12) send_data = 8'hFF;
    end

    // 分频：命令/R1/STOP12/CS_UP 用 cmd 相位；token/data/crc/dummy 用 data 相位
    always @(*) begin
        case (state)
            S_TOKEN, S_DATA, S_CRC, S_DUMMY: div_value = DIV_DATA[3:0];
            default:                         div_value = DIV_CMD[3:0];
        endcase
    end

    // ---------------- 组合式字节发射器 ----------------
    // 发起字节的阶段保持 start=1；驱动器只在 IDLE 采样 start，WORK 期间
    // 忽略之，因此状态切换瞬间不会双发/漏发。R1/token 接收态也保持发射：
    // r1_stop 落链后驱动器回 IDLE，必须重启才能继续扫 token——DUT 每次
    // 时钟消耗模型队列一个字节，与协议 N_CR/N_AC 逐字节对齐。
    // 数据阶段的续发由水位自调。
    assign spi_start = (state == S_CMD)   | (state == S_STOP12) |
                       (state == S_DUMMY) | (state == S_CS_UP)  |
                       (state == S_R1)    | (state == S_TOKEN)  |
                       ((state == S_DATA) & ~byte_pending & spi_idle);
    assign dbg_paused = (state == S_DATA) & byte_pending;

    // 链终止判定（组合，前一字节 done 时已可判定 → 恰在字节边界落链）
    wire stop_at_crc2 = (crc_cnt == 2'd1) &
                        (probe_phase |
                         (cmd_kind == K_CMD17) |
                         ((cmd_kind == K_CMD18) & (blocks_left == 16'd1)));

    // 命令字节索引：复刻厂商 sd_cmd_send 的 ce 门控推进相位（板级验证）。
    // clk 率的 spi_done_p 比驱动器 shift_reg 重装沿晚一拍，曾造成
    // 首字节双发/末字节丢失（线上实测 [b0,b0,b1,b2,b3,b4]）。
    always @(posedge clk or posedge rst) begin
        if (rst) cmd_cnt <= 3'd0;
        else if (ce) begin
            if (state == S_CMD || state == S_STOP12) begin
                if (spi_done) cmd_cnt <= cmd_cnt + 3'd1;
            end
            else cmd_cnt <= 3'd0;
        end
    end

    // 数据阶段暂停请求（字节待收时字节边界生效）
    wire pause_req = (state == S_DATA) & byte_pending;

    reg next_kill;
    always @(*) begin
        case (state)
            S_CMD:     next_kill = (cmd_cnt == 3'd5);   // 第 6 字节后落链
            S_R1:      next_kill = r1_stop;             // 命中后 +1 字节停
            S_TOKEN:   next_kill = 1'b0;                // 连续扫，命中不断链
            S_DATA:    next_kill = pause_req;
            S_CRC:     next_kill = stop_at_crc2;
            S_DUMMY:   next_kill = 1'b1;                // dummy 后必停
            S_STOP12:  next_kill = (cmd_cnt == 3'd5);
            S_STOP12R1:next_kill = r1_stop;
            default:   next_kill = 1'b1;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) spi_next <= 1'b0;
        else     spi_next <= ~next_kill;
    end

    // ---------------- 主 FSM ----------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE; done <= 1'b0; err <= 1'b0; probe_fail <= 1'b0;
            probe_drain <= 1'b0; probe_ra <= 10'd0;
            cs_n <= 1'b1;
            r1_stop <= 1'b0; cmd_reg <= 48'h0;   // cmd_cnt 由下方专用 ce 门控计数块独占驱动
            cmd_kind <= 2'd0; next_cmd <= 2'd0;
            r1_cnt <= 5'd0; r1_value <= 8'hFF;
            tok_cnt <= 11'd0; data_cnt <= 11'd0;
            crc_calc <= 16'h0; crc_rx <= 16'h0; crc_cnt <= 2'd0;
            blocks_left <= 16'd0; cur_sector <= 28'd0;
            req_count <= 16'd0; req_sector <= 28'd0;
            probe_phase <= 1'b0; probe_done_r <= 1'b0; probe_ok_r <= 1'b0; broken_r <= 1'b0;
            out_active <= 1'b0;
            out_cnt <= 32'd0; out_byte <= 9'd0; out_sector <= 28'd0;
            byte_pending <= 1'b0;
        end
        else begin
            done <= 1'b0; err <= 1'b0; probe_fail <= 1'b0;

            // ---- 字节_pending 排水记账（消费者握手时推进流计数器） ----
            if (byte_pending && stream_ready) begin
                byte_pending <= 1'b0;
                out_cnt      <= out_cnt + 32'd1;
                if (out_byte == 9'd511) begin
                    out_byte   <= 9'd0;
                    out_sector <= out_sector + 28'd1;
                end else begin
                    out_byte <= out_byte + 9'd1;
                end
            end

            case (state)
            S_IDLE: begin
                if (start && sector_count != 16'd0) begin
                    if (broken_r) begin
                        done <= 1'b1;                     // 防御：不应被调度到这
                    end else begin
                        req_sector <= start_sector;
                        req_count  <= sector_count;
                        cur_sector <= start_sector;
                        out_cnt    <= 32'd0;
                        out_byte   <= 9'd0;
                        out_sector <= start_sector;
                        out_active <= 1'b0;
                        r1_stop    <= 1'b0;
                        cs_n       <= 1'b0;
                        if (!probe_done_r) begin
                            probe_phase <= 1'b1;
                            cmd_kind    <= K_CMD16;
                            cmd_reg     <= {8'h50, 32'd512, 8'hFF};   // CMD16 blocklen=512
                        end else begin
                            probe_phase <= 1'b0;
                            if (sector_count == 16'd1) begin
                                cmd_kind    <= K_CMD17;
                                cmd_reg     <= {8'h51, 4'b0000, start_sector, 8'hFF};
                                blocks_left <= 16'd1;
                            end else begin
                                cmd_kind    <= K_CMD18;
                                cmd_reg     <= {8'h52, 4'b0000, start_sector, 8'hFF};
                                blocks_left <= sector_count - 16'd1;
                            end
                        end
                        // cmd_cnt 无需清零：S_IDLE 期间专用计数块已清 0（ce 门控，见下）
                        state   <= S_CMD;
                    end
                end
            end

            // ---- 命令 6 字节（字节索引由 ce 门控计数器推进，见下） ----
            S_CMD: begin
                if (spi_done_p && cmd_cnt >= 3'd5) begin
                    r1_cnt  <= 5'd0;
                    r1_stop <= 1'b0;
                    state   <= S_R1;
                end
            end

            // ---- R1：bit7==0 即命中；+1 字节后停链 ----
            S_R1: begin
                if (spi_done_p) begin
                    if (!r1_stop) begin
                        r1_value <= rec_data;
                        r1_cnt   <= r1_cnt + 5'd1;
                        if (rec_data[7] == 1'b0)
                            r1_stop <= 1'b1;
                        else if (r1_cnt >= R1_TIMEOUT[4:0]) begin
                            if (probe_phase) begin
                                broken_r <= 1'b1; probe_done_r <= 1'b1;
                                probe_fail <= 1'b1;
                                cs_n <= 1'b1; state <= S_IDLE;
                            end else begin
                                err <= 1'b1; broken_r <= 1'b1;
                                cs_n <= 1'b1; state <= S_IDLE; done <= 1'b1;
                            end
                        end
                    end else begin
                        // +1 字节（dummy）收完，驱动器已回 IDLE
                        r1_stop <= 1'b0;
                        if (r1_value == 8'h00) begin
                            case (cmd_kind)
                            K_CMD16: begin                     // 探测第 1 步完成
                                next_cmd <= 2'd1;              // S_DUMMY → CS_UP → CMD17
                                state    <= S_DUMMY;
                            end
                            K_CMD17, K_CMD18: begin            // 进入取数
                                tok_cnt  <= 11'd0;
                                data_cnt <= 11'd0;
                                crc_calc <= 16'h0;
                                crc_cnt  <= 2'd0;
                                state    <= S_TOKEN;
                            end
                            default: begin                     // K_CMD12：收尾
                                cs_n  <= 1'b1;
                                state <= S_IDLE;
                                done  <= 1'b1;
                            end
                            endcase
                        end else begin
                            // R1 错误位（illegal/error）
                            if (probe_phase) begin
                                broken_r <= 1'b1; probe_done_r <= 1'b1;
                                probe_fail <= 1'b1;
                                cs_n <= 1'b1; state <= S_IDLE;
                            end else begin
                                err <= 1'b1; broken_r <= 1'b1;
                                cs_n <= 1'b1; state <= S_IDLE; done <= 1'b1;
                            end
                        end
                    end
                end
            end

            // ---- token 扫描（链不断，跨块连续） ----
            S_TOKEN: begin
                if (spi_done_p) begin
                    if (rec_data == 8'hFE) begin
                        data_cnt <= 11'd0;
                        crc_calc <= 16'h0;
                        out_active <= 1'b1;   // 数据字节即将到来：激活流输出
                        state    <= S_DATA;
                    end else begin
                        tok_cnt <= tok_cnt + 11'd1;
                        if (tok_cnt >= TOKEN_TIMEOUT[10:0] - 11'd1) begin
                            if (probe_phase) begin
                                broken_r <= 1'b1; probe_done_r <= 1'b1;
                                probe_fail <= 1'b1;
                                cs_n <= 1'b1; state <= S_IDLE;
                            end else begin
                                err <= 1'b1; broken_r <= 1'b1;
                                cs_n <= 1'b1; state <= S_IDLE; done <= 1'b1;
                            end
                        end
                    end
                end
            end

            // ---- 数据 512 字节 ----
            S_DATA: begin
                if (spi_done_p) begin
                    if (probe_phase) begin
                        probe_buf[data_cnt[9:0]] <= rec_data;  // 暂存：判定前不外流
                    end else begin
                        byte_pending <= 1'b1;   // 数据字节直推 stream
                    end
                    crc_calc <= crc16_byte(crc_calc, rec_data);
                    data_cnt <= data_cnt + 11'd1;
                    if (data_cnt == 11'd511) begin
                        state   <= S_CRC;
                        crc_cnt <= 2'd0;
                        crc_rx  <= 16'h0;
                    end
                end
            end

            // ---- CRC 2 字节 ----
            S_CRC: begin
                if (spi_done_p) begin
                    crc_rx <= {crc_rx[7:0], rec_data};
                    if (crc_cnt == 2'd1) begin
                        crc_cnt <= 2'd0;
                        if ({crc_rx[7:0], rec_data} != crc_calc) begin
                            if (probe_phase) begin
                                broken_r <= 1'b1; probe_done_r <= 1'b1;
                                probe_fail <= 1'b1;        // 缓冲弃之不用，核心重读
                                cs_n <= 1'b1; state <= S_IDLE;
                            end else begin
                                err <= 1'b1; broken_r <= 1'b1;
                                cs_n <= 1'b1; state <= S_IDLE; done <= 1'b1;
                            end
                        end else begin
                            if (probe_phase) begin
                                // 探测读（CMD17）成功：首扇区即数据——先排水缓冲再走链尾
                                probe_phase   <= 1'b0;
                                probe_done_r  <= 1'b1;
                                probe_ok_r    <= 1'b1;
                                cur_sector    <= req_sector + 28'd1;
                                probe_drain   <= 1'b1;
                                probe_ra      <= 10'd0;
                                if (req_count == 16'd1) begin
                                    next_cmd <= 2'd0;      // 收尾
                                end else begin
                                    next_cmd <= 2'd3;      // CS_UP 后发 CMD18（余下块）
                                end
                                state <= S_DRAIN;
                            end else if (cmd_kind == K_CMD17) begin
                                // 单扇区 CMD17（探测已通过）：无 CMD12，直接收尾
                                next_cmd <= 2'd0;
                                state    <= S_DUMMY;
                            end else if (blocks_left == 16'd1) begin
                                blocks_left <= 16'd0;
                                // 末块完成：直接抬 CS 结束事务（SD 规范允许，
                                // CMD12 仅提前终止时需要）——绕开尾段计数相位竞态
                                next_cmd    <= 2'd0;
                                state       <= S_DUMMY;
                            end else begin
                                blocks_left <= blocks_left - 16'd1;
                                cur_sector  <= cur_sector + 28'd1;
                                tok_cnt     <= 11'd0;
                                state       <= S_TOKEN;        // 链继续
                            end
                        end
                    end else begin
                        crc_cnt <= crc_cnt + 2'd1;
                    end
                end
            end

            // ---- 链尾 dummy（N_EC）：本字节后驱动器回 IDLE ----
            S_DUMMY: begin
                if (spi_done_p) begin
                    case (next_cmd)
                    2'd1, 2'd3: begin cs_n <= 1'b1; state <= S_CS_UP; end
                    2'd2: begin cmd_kind <= K_CMD12;
                                cmd_reg  <= {8'h4C, 32'd0, 8'hFF};
                                state    <= S_STOP12; end
                    default: begin
                                cs_n  <= 1'b1;
                                state <= S_FLUSH; end   // 排空字节再 done
                    endcase
                end
            end

            // ---- 流排空：等消费者收完最后一个字节再报告 done ----
            S_FLUSH: begin
                if (!byte_pending) begin
                    out_active <= 1'b0;
                    state      <= S_IDLE;
                    done       <= 1'b1;
                end
            end

            // ---- CS 高 + dummy（满足 NCC），随后发探测读 / CMD18 ----
            S_CS_UP: begin
                if (spi_done_p) begin
                    cs_n <= 1'b0;
                    if (next_cmd == 2'd3) begin
                        // 探测读已完成：余下块走 CMD18
                        cmd_kind  <= K_CMD18;
                        cmd_reg   <= {8'h52, 4'b0000, cur_sector, 8'hFF};
                        blocks_left <= req_count - 16'd1;
                    end else begin
                        // CMD16 已接受：探测读首扇区（CMD17）
                        cmd_kind  <= K_CMD17;
                        cmd_reg   <= {8'h51, 4'b0000, req_sector, 8'hFF};
                        blocks_left <= 16'd1;
                    end
                    state     <= S_CMD;
                end
            end

            // ---- 探测缓冲排水：SPI 暂停（卡为时钟从机，字节边界停等安全） ----
            S_DRAIN: begin
                if (byte_pending) begin
                    if (stream_ready) begin
                        if (probe_ra == 10'd511) begin
                            probe_drain <= 1'b0;
                            state       <= S_DUMMY;   // 排空后走链尾
                        end else begin
                            probe_ra <= probe_ra + 10'd1;
                        end
                    end
                end else begin
                    byte_pending <= 1'b1;             // 装载下一缓冲字节
                end
            end

            // ---- CMD12 ----
            S_STOP12: begin
                if (spi_done_p && cmd_cnt >= 3'd5) begin
                    r1_cnt  <= 5'd0;
                    r1_stop <= 1'b0;
                    cmd_kind <= K_CMD12;
                    state   <= S_STOP12R1;
                end
            end

            // ---- CMD12 R1 + 收尾（+1 字节兼作 CS 前 dummy） ----
            S_STOP12R1: begin
                if (spi_done_p) begin
                    if (!r1_stop) begin
                        r1_value <= rec_data;
                        if (rec_data[7] == 1'b0) r1_stop <= 1'b1;
                    end else begin
                        r1_stop <= 1'b0;
                        cs_n    <= 1'b1;
                        state   <= S_IDLE;
                        done    <= 1'b1;
                    end
                end
            end

            default: begin
                cs_n  <= 1'b1;
                state <= S_IDLE;
            end
            endcase
        end
    end

    // ---------------- stream 输出（探测缓冲排水时取缓冲，其余直推 rec_data） ----------------
    assign stream_data             = probe_drain ? probe_buf[probe_ra] : rec_data;
    assign stream_valid            = out_active & byte_pending;
    assign stream_first            = stream_valid & (out_cnt == 32'd0);
    assign stream_byte_offset      = out_cnt;
    assign stream_sector_addr      = out_sector;
    assign stream_sector_byte_addr = out_byte;
    assign stream_last             = stream_valid &
                                     (out_cnt == ({req_count, 9'd0} - 32'd1));

endmodule

`default_nettype wire
