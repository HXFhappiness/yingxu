// =============================================================================
// tb_cart_soc.v — yx8_cart_soc_v2 全链路冒烟测试
//
// 用真实 .yxc 文件喂 SD 字节流模型，验证：
//   SD 流 → 加载器(头/码/数据段打包) → loaded 跨域 → 数据段解包 →
//   CPU 从 entry 执行 → I/O 窗口 → 精灵提交脉冲(slot/x/y/w/h/color)。
//
// 期望（pong 首帧）：
//   slot0: en=1 x=16   y=176 w=8 h=64 c=00FF00（左板，ly=44×4）
//   slot1: en=1 x=1208 y=176 w=8 h=64 c=00FF00（右板）
//   slot2: en=1 x=128  y=360 w=8 h=8  c=FFFFFF（球，bx=32×4, by=90×4）
//
// 编译：iverilog -g2005 -DCARTFILE=\"pong.yxc\" tb_cart_soc.v yx8_cart_soc.v yx8_cpu.v
// =============================================================================
`timescale 1ns / 1ps

module tb_cart_soc;

    reg sys_clk = 1'b0;
    reg pix_clk = 1'b0;
    always #10    sys_clk = ~sys_clk;    // 50 MHz
    always #6.818 pix_clk = ~pix_clk;    // ~73.3 MHz

    reg pix_rst = 1'b1, sys_rst = 1'b1;
    reg en = 1'b0, sd_ready = 1'b0;
    reg [7:0] sd_data = 8'h00;
    reg       sd_valid = 1'b0;
    reg key0_n = 1'b1, key1_n = 1'b1;
    reg pix_frame_tick = 1'b0;

    wire        cart_restart, cart_busy, cart_hb;
    wire        spr_we, spr_en;
    wire [3:0]  spr_slot;
    wire [10:0] spr_x;
    wire [9:0]  spr_y;
    wire [6:0]  spr_w;
    wire [5:0]  spr_h;
    wire [23:0] spr_color;
    wire [59:0] brick_mask;
    wire ev_hit, ev_paddle, ev_lose, ev_win;
    wire [7:0]  cart_score;

    yx8_cart_soc_v2 dut (
        .sys_clk(sys_clk), .pix_clk(pix_clk),
        .pix_rst(pix_rst), .sys_rst(sys_rst),
        .en(en), .sd_ready(sd_ready),
        .sd_data(sd_data), .sd_valid(sd_valid),
        .key0_n(key0_n), .key1_n(key1_n),
        .pix_frame_tick(pix_frame_tick),
        .cart_restart(cart_restart), .cart_busy(cart_busy), .cart_hb(cart_hb),
        .spr_we(spr_we), .spr_slot(spr_slot), .spr_en(spr_en),
        .spr_x(spr_x), .spr_y(spr_y), .spr_w(spr_w), .spr_h(spr_h),
        .spr_color(spr_color), .brick_mask(brick_mask),
        .ev_hit(ev_hit), .ev_paddle(ev_paddle), .ev_lose(ev_lose), .ev_win(ev_win),
        .cart_score(cart_score)
    );

    // ---- SD 字节流模型：cart_restart 触发后按节奏吐 .yxc --------------------
    reg [7:0] cart_bytes [0:65535];
    integer nbytes, byte_idx, pace;
    reg streaming = 1'b0;
    integer fd;

    initial begin
        fd = $fopen(`CARTFILE, "rb");
        if (fd == 0) begin
            $display("FATAL: cannot open `CARTFILE");
            $finish;
        end
        nbytes = $fread(cart_bytes, fd);
        $display("[TB] cart file: %0d bytes", nbytes);
    end

    always @(posedge cart_restart) begin
        streaming <= 1'b1;
        byte_idx  <= 0;
        pace      <= 0;
        $display("[TB] SD stream start");
    end

    always @(posedge sys_clk) begin
        sd_valid <= 1'b0;
        if (streaming && byte_idx < nbytes) begin
            if (pace == 0) begin
                sd_data  <= cart_bytes[byte_idx];
                sd_valid <= 1'b1;
                byte_idx <= byte_idx + 1;
                pace     <= 3;
            end
            else pace <= pace - 1;
        end
    end

    // ---- 假帧脉冲（每 ~10us 一帧，CPU 只需要 WFI 唤醒） ----------------------
    initial begin
        forever begin
            #10000;
            pix_frame_tick = 1'b1;
            #6.818;
            pix_frame_tick = 1'b0;
        end
    end

    // ---- 精灵提交监视 + 首三提交核对（同一块内，无竞态） --------------------
    integer commits = 0;
    integer errs = 0;
    always @(posedge pix_clk) begin
        if (spr_we) begin
            commits = commits + 1;
            $display("[%0t] COMMIT %0d: slot=%0d en=%0d x=%0d y=%0d w=%0d h=%0d c=%06h",
                     $time, commits, spr_slot, spr_en, spr_x, spr_y, spr_w, spr_h, spr_color);
            `ifdef CHECK_PONG
            case (commits)
            1: if (spr_slot != 4'd0 || spr_en != 1'b1 || spr_x != 11'd16 ||
                   spr_y != 10'd176 || spr_w != 7'd8 || spr_h != 6'd63 ||
                   spr_color != 24'h00FF00) begin
                   $display("[TB] FAIL commit1 mismatch"); errs = errs + 1;
               end
            2: if (spr_slot != 4'd1 || spr_en != 1'b1 || spr_x != 11'd1208 ||
                   spr_y != 10'd176 || spr_w != 7'd8 || spr_h != 6'd63 ||
                   spr_color != 24'h00FF00) begin
                   $display("[TB] FAIL commit2 mismatch"); errs = errs + 1;
               end
            3: if (spr_slot != 4'd2 || spr_en != 1'b1 || spr_x != 11'd128 ||
                   spr_y != 10'd360 || spr_w != 7'd8 || spr_h != 6'd8 ||
                   spr_color != 24'hFFFFFF) begin
                   $display("[TB] FAIL commit3 mismatch"); errs = errs + 1;
               end
            endcase
            `endif
        end
    end

    // ---- 主流程 --------------------------------------------------------------
    integer updone_shown = 0;
    initial begin
        #100  sys_rst = 1'b0;
        #37   pix_rst = 1'b0;
        #200  en = 1'b1;
        #500  sd_ready = 1'b1;
    end

    // 解包完成打点
    always @(posedge pix_clk) begin
        if (dut.up_done && !updone_shown) begin
            updone_shown = 1;
            $display("[%0t] unpack done, dram[0x50..0x53] = %02h %02h %02h %02h",
                     $time, dut.dram[8'h50], dut.dram[8'h51],
                            dut.dram[8'h52], dut.dram[8'h53]);
        end
    end

    // ---- CPU 内部探针 --------------------------------------------------------
    integer dbg_i = 0;
    always @(posedge pix_clk) begin
        if (!dut.cpu_rst && dbg_i < 40) begin
            dbg_i = dbg_i + 1;
            $display("[%0t] DBG pc=%03h st=%0d instr=%06h dwe=%0b da=%02h dw=%02h iowe=%0b",
                     $time, dut.u_cpu.pc_r, dut.u_cpu.state, dut.instr_r,
                     dut.cpu_dwe, dut.cpu_daddr, dut.cpu_dwdata, dut.io_we);
        end
    end

    // 加载器状态迁移探针（蛇卡 L_CODE 问题的观测口）
    always @(dut.lstate or dut.wcnt)
        $display("[%0t] LD lstate=%0d wcnt=%0d words_r=%0d bph=%0d byte_idx=%0d/%0d",
                 $time, dut.lstate, dut.wcnt, dut.words_r, dut.bph, byte_idx, nbytes);

    initial begin
        #4_000_000;   // 4 ms 仿真上限
        $display("[TB] commits=%0d loaded=%0d up_done=%0d lstate=%0d magic=%h",
                 commits, dut.loaded_p, dut.up_done, dut.lstate, dut.magic_r);
        `ifdef CHECK_PONG
        if (commits >= 3 && errs == 0) $display("[TB] PONG PASS");
        else                           $display("[TB] PONG FAIL");
        `else
        // 蛇：数据段解包 + 食物精灵提交 + 身体走砖块位图（mask 非零）
        if (commits >= 1 && dut.brick_mask != 60'd0 && dut.dram[8'h50] == 8'h01)
            $display("[TB] SNAKE PASS");
        else
            $display("[TB] SNAKE FAIL commits=%0d mask=%b d50=%h",
                     commits, dut.brick_mask, dut.dram[8'h50]);
        `endif
        $finish;
    end

endmodule
