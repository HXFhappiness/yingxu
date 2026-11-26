`timescale 1ns / 1ps
//==============================================================================
// tb_sd_multi.v — YX-SD v2（sd_stream_reader 快速引擎）卡行为模型仿真
//
// 被测：sd_stream_reader（内含原厂控制器 + sd_multi_reader 快速引擎 + 仲裁）
// 模型：SPI 模式 SD 卡行为模型——在 SCLK 沿上工作，与系统时钟无耦合：
//   * init 纪律：初始化完成前 SCLK > ~526 kHz 即记 freq_violation（验证
//     "当初 25 MHz 失败=初始化时钟违反规范"假设 + 新三相位实现的纪律）；
//   * CMD0/CMD8/CMD55/ACMD41/CMD16/CMD17/CMD18/CMD12，R1 N_CR=2B，
//     数据 token 0xFE，N_AC=2B，块尾 N_EC=1B，实时 CRC16-CCITT；
//   * 数据内容 = LBA 哈希（确定性），校验器同函数逐字节比对；
//   * +crcerr：破坏探测块（CMD17@fast 的首块）CRC → 验证 probe_fail
//     → 无缝回退厂商路径 → fast_broken 粘滞；
//   * +throttle：stream_ready 伪随机断流 → 验证 FIFO 字节边界暂停/续读。
//
// 用法: vvp tb_sd_multi.vvp [+crcerr] [+throttle] [+sectors=N]
// 编译: iverilog -g2012 -o tb_sd_multi.vvp tb/tb_sd_multi.v \
//         src/user_source/hdl_source/media/sd/*.v
// 回归对照: iverilog -Ptb_sd_multi.FORCE_LEGACY=1 ... （全走厂商路径）
//==============================================================================
`default_nettype none

module tb_sd_multi #(parameter FORCE_LEGACY = 0);

    reg clk = 0;
    always #10 clk = ~clk;                 // 50 MHz

    reg rst = 1;

    // ---- DUT 连接 ----
    wire mosi, sclk, cs_n;
    reg  miso = 1'b1;
    reg  start = 0;
    reg  [27:0] start_sector = 0;
    reg  [15:0] sector_count = 0;
    reg  stream_ready = 1'b1;
    wire [7:0]  stream_data;
    wire        stream_valid, stream_first, stream_last;
    wire [31:0] stream_byte_offset;
    wire [27:0] stream_sector_addr;
    wire [8:0]  stream_sector_byte_addr;
    wire init_done, busy, done;
    wire dbg_fast_ok, dbg_fast_broken;
    wire [3:0] dbg_multi_state, dbg_multi_div;

    sd_stream_reader #(
        .CLOCK_FREQ   (50_000_000),
        .SPI_LOWFREQ  (400_000),
        .SPI_HIGHFREQ (6_250_000),
        .FORCE_LEGACY (FORCE_LEGACY)
    ) dut (
        .mosi(mosi), .sclk(sclk), .cs_n(cs_n), .miso(miso),
        .clk(clk), .rst(rst),
        .start(start), .start_sector(start_sector), .sector_count(sector_count),
        .stream_data(stream_data), .stream_valid(stream_valid),
        .stream_ready(stream_ready), .stream_first(stream_first),
        .stream_last(stream_last), .stream_byte_offset(stream_byte_offset),
        .stream_sector_addr(stream_sector_addr),
        .stream_sector_byte_addr(stream_sector_byte_addr),
        .init_done(init_done), .busy(busy), .done(done),
        .dbg_spi_clk(), .dbg_spi_div_value(), .dbg_spi_div_counter(),
        .dbg_ctrl_state(), .dbg_select_num(), .dbg_spi_start(), .dbg_spi_next(),
        .dbg_spi_done(), .dbg_init_state(), .dbg_init_response(),
        .dbg_spi_driver_state(), .dbg_spi_driver_count(),
        .dbg_read_state(), .dbg_read_spi_rec_data(),
        .dbg_read_addr_done(), .dbg_read_data_done(),
        .dbg_fast_ok(dbg_fast_ok), .dbg_fast_broken(dbg_fast_broken),
        .dbg_multi_state(dbg_multi_state), .dbg_multi_div(dbg_multi_div)
    );

    // ---- 卡模型参数 ----
    localparam [31:0] INIT_MAX_PERIOD = 2100;   // ns；超过 ~476 kHz 视为违规

    integer freq_violation = 0;
    integer crcerr     = 0;
    integer throttle   = 0;
    integer corruption_done = 0;                // 只破坏第一块一次

    // ---- 数据内容（与校验器共用） ----
    function [31:0] hash32;
        input [31:0] h;
        begin
            h = h ^ (h << 13); h = h ^ (h >> 17); h = h ^ (h << 5);
            hash32 = h;
        end
    endfunction

    function [7:0] mem_byte;
        input [27:0] lba;
        input [15:0] idx;
        reg [31:0] h;
        begin
            h = lba * 32'h9E3779B1 + idx * 32'h85EBCA6B + 32'hC2B2AE35;
            h = hash32(h); h = hash32(h);
            mem_byte = h[7:0];
        end
    endfunction

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

    // ---- 卡模型：TX 队列 ----
    reg [7:0] txq [0:4095];
    integer tx_head = 0, tx_tail = 0;
    reg [7:0] tx_shift;
    integer tx_bits = 0;

    task tx_push(input [7:0] b);
        begin
            txq[tx_tail % 4096] = b;
            tx_tail = tx_tail + 1;
        end
    endtask

    integer q_used;
    always @(*) q_used = tx_tail - tx_head;

    // ---- 卡模型：命令接收 ----
    reg [7:0]  rx_shift = 0;
    integer    rx_bits = 0;
    reg [47:0] cmd_acc;
    integer    cmd_bytes = 0;
    reg        in_cmd = 0;
    reg        initialized = 0;
    reg        acmd_armed = 0;
    integer    acmd_tries = 0;
    reg        multi_mode = 0;
    reg        blocklen_set = 0;

    // 发一块数据（token+512+CRC16）；lba 指定内容；opt_corrupt 允许破坏 CRC
    task model_send_block(input [27:0] lba, input opt_corrupt);
        reg [15:0] c;
        reg [7:0]  d;
        integer i;
        begin
            tx_push(8'hFE);
            c = 16'h0000;
            for (i = 0; i < 512; i = i + 1) begin
                d = mem_byte(lba, i[15:0]);
                c = crc16_byte(c, d);
                tx_push(d);
            end
            if (opt_corrupt) begin
                tx_push(~c[15:8]); tx_push(~c[7:0]);
            end else begin
                tx_push(c[15:8]); tx_push(c[7:0]);
            end
        end
    endtask

    // 命令译码（6 字节齐后调用）
    task model_command;
        reg [7:0] op;
        reg [27:0] arg;
        begin
            op  = cmd_acc[47:40];
            arg = cmd_acc[39:8];
            $display("[CARD t=%0t] op=%02x arg=%0d", $time, op, arg);
            case (op)
            8'h40: begin                              // CMD0 → idle
                initialized = 0;
                tx_push(8'hFF); tx_push(8'h01);
            end
            8'h48: begin                              // CMD8 → R1+echo
                tx_push(8'hFF); tx_push(8'h01);
                tx_push(8'h00); tx_push(8'h00); tx_push(8'h01); tx_push(8'hAA);
            end
            8'h77: begin                              // CMD55
                acmd_armed = 1;
                tx_push(8'hFF); tx_push(8'h01);
            end
            8'h69: begin                              // ACMD41
                if (acmd_armed) begin
                    acmd_tries = acmd_tries + 1;
                    if (acmd_tries >= 2) begin
                        initialized = 1;
                        tx_push(8'hFF); tx_push(8'h00);
                    end else begin
                        tx_push(8'hFF); tx_push(8'h01);
                    end
                end else begin
                    tx_push(8'hFF); tx_push(8'h04); // 非法
                end
                acmd_armed = 0;
            end
            8'h50: begin                              // CMD16
                blocklen_set = 1;
                tx_push(8'hFF); tx_push(8'h00);
            end
            8'h51: begin                              // CMD17 单块
                if (initialized) begin
                    tx_push(8'hFF); tx_push(8'h00);
                    tx_push(8'hFF); tx_push(8'hFF); tx_push(8'hFF); // N_CR2
                    model_send_block(arg, (crcerr && !corruption_done));
                    if (crcerr && !corruption_done) corruption_done = 1;
                    tx_push(8'hFF);                                  // N_EC
                end else begin
                    tx_push(8'hFF); tx_push(8'h04);
                end
            end
            8'h52: begin                              // CMD18 多块
                if (initialized) begin
                    multi_mode = 1;
                    tx_push(8'hFF); tx_push(8'h00);
                    tx_push(8'hFF); tx_push(8'hFF); tx_push(8'hFF); // N_CR2
                    model_send_block(arg, 0);
                end else begin
                    tx_push(8'hFF); tx_push(8'h04);
                end
            end
            8'h4C: begin                              // CMD12
                multi_mode = 0;
                tx_push(8'hFF); tx_push(8'h00);
                tx_push(8'hFF);
            end
            default: begin                            // 非法命令
                tx_push(8'hFF); tx_push(8'h04);
            end
            endcase
        end
    endtask

    // CMD18 连续供块：TX 队列将空且 multi 模式时补一块（N_AC=2B）
    reg [27:0] multi_next_lba = 0;
    always @(posedge clk) begin
        if (multi_mode && initialized && cs_n == 1'b0 &&
            ((tx_tail - tx_head) < 600)) begin
            tx_push(8'hFF); tx_push(8'hFF);
            model_send_block(multi_next_lba, 0);
            multi_next_lba = multi_next_lba + 1;
        end
    end

    // ---- 卡模型：SCLK 沿驱动（全部按 CS 门控：CS=1 时卡不收不发） ----
    integer last_rise_ns = 0;
    always @(posedge sclk) begin
        // 频率纪律：初始化完成前不得 > ~476 kHz（无论 CS 电平，时钟都算数）
        if (!initialized && last_rise_ns != 0 &&
            ($time - last_rise_ns) < INIT_MAX_PERIOD)
            freq_violation = freq_violation + 1;
        last_rise_ns = $time;

        if (cs_n == 1'b0) begin
            // 采样 MOSI（仅 CS 低）
            rx_shift = {rx_shift[6:0], mosi};
            rx_bits = rx_bits + 1;
            if (rx_bits == 8) begin
                rx_bits = 0;
                $display("[CRX t=%0t] byte=%02x (in_cmd=%b cmd_bytes=%0d)",
                         $time, rx_shift, in_cmd, cmd_bytes);
                if (!in_cmd) begin
                    if (rx_shift[7:6] == 2'b01) begin     // 0x40-0x7F：命令起始
                        in_cmd = 1; cmd_bytes = 1; cmd_acc = {rx_shift, 40'h0};
                    end
                end else begin
                    // 按槽位直写（此前用 {acc[39:0], b} 移位会把首字节 0x40 挤丢）
                    case (cmd_bytes)
                    1: cmd_acc[39:32] = rx_shift;
                    2: cmd_acc[31:24] = rx_shift;
                    3: cmd_acc[23:16] = rx_shift;
                    4: cmd_acc[15:8]  = rx_shift;
                    default: cmd_acc[7:0] = rx_shift;
                    endcase
                    cmd_bytes = cmd_bytes + 1;
                    if (cmd_bytes == 6) begin
                        in_cmd = 0; cmd_bytes = 0;
                        model_command;
                        if (multi_mode) multi_next_lba = cmd_acc[39:8] + 1;
                    end
                end
            end
        end
    end

    // CS 下降沿：字节窗口重同步（每次片选从命令首字节开始）
    always @(negedge cs_n) begin
        rx_bits = 0; rx_shift = 0; in_cmd = 0; cmd_bytes = 0;
    end

    // TX 移位输出（下降沿换位；字节装载锁相到 DUT 字节帧边界：
    // DUT 每字节 8 个上升沿，rx_bits==0 表示刚跨过字节边界，此刻装载
    // 下一字节，保证模型字节与 DUT 的 rec 捕获窗逐字节对齐）
    always @(negedge sclk) begin
        if (cs_n == 1'b0) begin
            if (tx_bits == 0) begin
                if (rx_bits == 0 && tx_head != tx_tail) begin
                    tx_shift = txq[tx_head % 4096];
                    miso = tx_shift[7];
                    tx_shift = {tx_shift[6:0], 1'b1};
                    tx_bits = 1;
                    $display("[TX t=%0t] LOAD %02x head=%0d rxbits=%0d", $time, txq[tx_head % 4096], tx_head, rx_bits);
                end else begin
                    miso = 1'b1;                      // 等待边界/队列空：释放
                end
            end else begin
                miso = tx_shift[7];
                tx_shift = {tx_shift[6:0], 1'b1};
                tx_bits = tx_bits + 1;
                if (tx_bits == 8) begin
                    tx_bits = 0;
                    tx_head = tx_head + 1;
                end
            end
        end else begin
            miso = 1'b1;                              // 未选中：高阻（上拉）
        end
    end

    always @(posedge cs_n) begin
        in_cmd = 0; cmd_bytes = 0; rx_bits = 0; tx_bits = 0;
        tx_head = 0; tx_tail = 0; multi_mode = 0;     // 片选撤销：模型复位流
    end

    // ---- 节流（+throttle）----
    reg [31:0] thr_cnt = 0;
    always @(posedge clk) begin
        if (throttle) begin
            thr_cnt = thr_cnt + 1;
            if (thr_cnt < 150)       stream_ready <= 1'b1;
            else if (thr_cnt < 350)  stream_ready <= 1'b0;  // 4 µs 断流
            else                     thr_cnt = 0;
        end else begin
            stream_ready <= 1'b1;
        end
    end

    // ---- 校验器 ----
    integer exp_idx = 0;        // 本请求已核对字节数
    integer byte_err = 0;
    integer bytes_checked = 0;
    reg     exp_first_seen = 0, exp_last_seen = 0;
    reg     chk_active = 0;
    reg [27:0] chk_lba0;
    reg [15:0] chk_cnt;
    reg [31:0] req_t0 = 0, req_cycles = 0;
    integer req_no = 0;
    reg all_ok = 1;

    always @(posedge clk) begin
        if (start) begin
            chk_lba0 = start_sector;
            chk_cnt  = sector_count;
            exp_idx = 0; byte_err = 0;
            exp_first_seen = 0; exp_last_seen = 0;
            chk_active = 1;
            req_no = req_no + 1;
            req_t0 = $time;
        end
        if (chk_active && stream_valid && stream_ready) begin
            if (stream_first) exp_first_seen = 1;
            if (stream_byte_offset != exp_idx) begin
                $display("[CHK] f%0t req%0d OFFSET MISMATCH exp=%0d got=%0d",
                         $time, req_no, exp_idx, stream_byte_offset);
                all_ok = 0;
            end
            if (stream_data !== mem_byte(chk_lba0 + (exp_idx >> 9), exp_idx % 512)) begin
                if (byte_err < 4)
                    $display("[CHK] req%0d DATA MISMATCH @%0d (lba %0d): exp=%02x got=%02x",
                             req_no, exp_idx, chk_lba0 + (exp_idx >> 9),
                             mem_byte(chk_lba0 + (exp_idx >> 9), exp_idx % 512), stream_data);
                byte_err = byte_err + 1;
            end
            exp_idx = exp_idx + 1;
            bytes_checked = bytes_checked + 1;
            if (stream_last) begin
                exp_last_seen = 1;
                chk_active = 0;
                req_cycles = $time - req_t0;
            end
        end
    end

    // 调试：抓 sclk 上升沿的 mosi 位流，还原前 32 字节
    reg [7:0] wire_bytes [0:31];
    integer wb_cnt = 0;
    reg [7:0] wb_shift = 0;
    integer wb_bits = 0;
    reg wb_printed = 0;
    always @(posedge sclk) begin
        wb_shift = {wb_shift[6:0], mosi};
        wb_bits = wb_bits + 1;
        if (wb_bits == 8 && wb_cnt < 32) begin
            wb_bits = 0;
            wire_bytes[wb_cnt] = wb_shift;
            wb_cnt = wb_cnt + 1;
            if (wb_cnt == 32 && !wb_printed) begin
                wb_printed = 1;
                for (i = 0; i < 32; i = i + 1)
                    $display("[WIRE %02d] %02x", i, wire_bytes[i]);
            end
        end
    end

    // ---- 激励 ----
    task do_read(input [27:0] lba, input [15:0] cnt);
        begin
            @(posedge clk);
            start <= 1; start_sector <= lba; sector_count <= cnt;
            @(posedge clk);
            start <= 0;
        end
    endtask

    integer i;
    initial begin
        if ($test$plusargs("crcerr"))     crcerr = 1;
        if ($test$plusargs("throttle"))   throttle = 1;
        $display("=== tb_sd_multi FORCE_LEGACY=%0d crcerr=%0d throttle=%0d ===",
                 FORCE_LEGACY, crcerr, throttle);

        repeat (10) @(posedge clk);
        rst = 0;

        wait (init_done);
        $display("[%0t ns] init_done, freq_violation=%0d", $time, freq_violation);
        if (freq_violation != 0) begin
            $display("RESULT: FAIL — init 阶段出现 %0d 次超频时钟沿", freq_violation);
            $finish;
        end
        $display("RESULT-INIT: PASS (init 全程 ≤400 kHz)");

        // 读 #1：16 扇区（探测 + CMD18 连读）
        do_read(28'd2000, 16'd16);
        wait (done);
        @(posedge clk);
        $display("[%0t ns] read#1 done: fast_ok=%b broken=%b bytes=%0d err=%0d cyc=%0d",
                 $time, dbg_fast_ok, dbg_fast_broken, exp_idx, byte_err, req_cycles);
        if (!crcerr) begin
            if (!dbg_fast_ok) $display("RESULT-FAST: FAIL (fast_ok=0)");
            else $display("RESULT-FAST: PASS");
            if (exp_idx != 16*512 || byte_err != 0 || !exp_first_seen || !exp_last_seen)
                $display("RESULT-DATA1: FAIL");
            else
                $display("RESULT-DATA1: PASS  吞吐 %.2f MB/s (含探测与初始化外全部时段)",
                         (16.0*512.0*50.0)/req_cycles);
        end else begin
            if (!dbg_fast_broken) $display("RESULT-FALLBACK: FAIL (broken 未置位)");
            else $display("RESULT-FALLBACK: PASS (探测失败→回退，粘滞置位)");
            if (exp_idx != 16*512 || byte_err != 0) $display("RESULT-DATA1: FAIL");
            else $display("RESULT-DATA1: PASS (回退路径数据完好)");
        end

        // 读 #2：单扇区
        do_read(28'd5000, 16'd1);
        wait (done);
        @(posedge clk);
        if (exp_idx != 512 || byte_err != 0) $display("RESULT-DATA2: FAIL (%0d err)", byte_err);
        else $display("RESULT-DATA2: PASS");

        // 读 #3：8 扇区（+throttle 时锻炼暂停/续读）
        do_read(28'd7000, 16'd8);
        wait (done);
        @(posedge clk);
        if (exp_idx != 8*512 || byte_err != 0) $display("RESULT-DATA3: FAIL (%0d err)", byte_err);
        else $display("RESULT-DATA3: PASS (throttle=%0d)", throttle);

        // 读 #4：5 扇区
        do_read(28'd9000, 16'd5);
        wait (done);
        @(posedge clk);
        if (exp_idx != 5*512 || byte_err != 0) $display("RESULT-DATA4: FAIL (%0d err)", byte_err);
        else $display("RESULT-DATA4: PASS");

        if (all_ok && byte_err == 0)
            $display("=== TB-SUMMARY: ALL PASS (bytes_checked=%0d) ===", bytes_checked);
        else
            $display("=== TB-SUMMARY: FAIL ===");
        $finish;
    end

    // 看门狗（+maxms=N 可调，默认 200 ms）
    integer max_ms = 200;
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("out/sd_multi.vcd");
            $dumpvars(0, tb_sd_multi);
        end
        if ($value$plusargs("maxms=%d", max_ms)) ;
        #(max_ms * 1_000_000);
        $display("=== WATCHDOG TIMEOUT ===");
        $finish;
    end

endmodule

`default_nettype wire
