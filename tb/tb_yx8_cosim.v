// =============================================================================
// tb_yx8_cosim.v — YX-8 共生验证测试台
// 与 tools/yxem.py --cosim --goldtrace 逐指令比对：
//   RTL 与模拟器执行同一 .yxc，每条退休指令打印一行全状态
//   (pc op a b r0..r7 z c n wa wv)，diff 两份文件即验证。
//
// 用法: vvp sim.vvp +prog=prog.hex +data=data.hex +trace=rtl.txt
//            +maxret=50000 +maxcyc=400000 [+debug]
// prog.hex: 1024 行 6 位十六进制（$readmemh 灌程序 RAM）
// data.hex: 224 行 2 位十六进制（含 DATA 段按装载地址摆放的完整 RAM 镜像）
//
// I/O 语义与 yxem --cosim 严格一致：
//   KEYS(0xF2)=普通 io（WFI 唤醒拍清 0）/ FRM(0xF3)=WFI 计数 / RAND(0xF4)=硬件
//   LFSR（0xAC 起，读后推进）/ SYS(0xF6) 读 0x80、写 bit7 停机 / 其余普通 io
// =============================================================================
`timescale 1ns / 1ps

module tb_yx8_cosim;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;

    // ---- 程序存储器（同步读，与 CPU 的 next_pc/pc_r 对齐协议） -------------
    reg [23:0] prom [0:1023];
    wire [15:0] next_pc;
    reg  [23:0] instr_r;
    // 对齐由 CPU 复位期 next_pc=0 保证（prom 预取 prom[0]）
    always @(posedge clk) instr_r <= prom[next_pc[9:0]];

    // ---- 数据侧模型（与模拟器同语义） --------------------------------------
    reg [7:0] ram [0:223];                  // 0x00-0xDF
    reg [7:0] ior [0:31];                   // 0xE0-0xFF

    wire [7:0] daddr, dwdata, drdata;
    wire       dwe, halted;
    reg        frame_tick;

    // 硬件随机数（与模拟器 cosim 模式同一 LFSR）
    reg [7:0] lfsr = 8'hAC;
    wire lfsr_fb = lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[4];
    wire [7:0] lfsr_nx = {lfsr[6:0], lfsr_fb};

    // WFI 帧计数
    reg [15:0] wfi_cnt = 0;
    reg        sys_halt = 0;

    assign drdata = (daddr < 8'hE0) ? ram[daddr[7:0]] :
                    (daddr == 8'hF3) ? wfi_cnt[7:0] :
                    (daddr == 8'hF4) ? lfsr :
                    (daddr == 8'hF6) ? 8'h80 :
                    ior[daddr[4:0]];

    // ---- DUT ----------------------------------------------------------------
    yx8_cpu dut (
        .clk(clk), .rst(rst),
        .entry(10'd0),
        .instr(instr_r), .next_pc(next_pc),
        .daddr(daddr), .dwdata(dwdata), .dwe(dwe), .drdata(drdata),
        .frame_tick(frame_tick), .halted(halted)
    );

    // ---- 写侧 ---------------------------------------------------------------
    integer wi;
    always @(posedge clk) begin
        if (!rst) begin
            if (dwe) begin
                if (daddr < 8'hE0)        ram[daddr[7:0]] <= dwdata;
                else if (daddr != 8'hF6)  ior[daddr[4:0]] <= dwdata;  // SYS 写不存
                if (daddr == 8'hF6 && dwdata[7]) sys_halt <= 1'b1;    // 热重启=停机
            end
            if (dut.is_ldr && daddr == 8'hF4) lfsr <= lfsr_nx;       // 读随机数推进
            // KEYS 清 0：只在"真正唤醒 WFI"的节拍上（= 模拟器 frame() 入口）
            if (frame_tick && dut.state == 2'd2) ior[8'h12] <= 8'h00;
        end
    end

    // ---- 帧节拍：每 64 拍一脉冲 ----------------------------------------------
    reg [31:0] cyc = 0;
    always @(posedge clk) begin
        if (rst) begin cyc <= 0; frame_tick <= 1'b0; end
        else begin
            cyc <= cyc + 1;
            frame_tick <= (cyc[5:0] == 6'd63);
        end
    end

    // ---- 退休计数 / WFI 计数 --------------------------------------------------
    reg [31:0] ret = 0;
    always @(posedge clk) begin
        if (rst) begin ret <= 0; wfi_cnt <= 0; end
        else begin
            if (dut.retire) ret <= ret + 1;
            if (dut.retire && dut.state == 2'd0 && dut.op == 8'h03)
                wfi_cnt <= wfi_cnt + 1;
        end
    end

    // ---- 轨迹输出 -------------------------------------------------------------
    integer f;
    integer maxret, maxcyc;
    integer dbg_en, stall_cnt;
    reg [1023:0] progfile, datafile, tracefile;
    integer have_data;

    wire done = sys_halt || halted || (ret >= maxret) || (cyc >= maxcyc);

    initial begin
        if (!$value$plusargs("prog=%s", progfile))  begin $display("need +prog=");  $finish; end
        if (!$value$plusargs("trace=%s", tracefile))begin $display("need +trace="); $finish; end
        have_data = $value$plusargs("data=%s", datafile);
        if (!$value$plusargs("maxret=%d", maxret)) maxret = 50000;
        if (!$value$plusargs("maxcyc=%d", maxcyc)) maxcyc = 400000;

        for (wi = 0; wi < 1024; wi = wi + 1) prom[wi] = 24'h000000;
        for (wi = 0; wi < 224; wi = wi + 1) ram[wi] = 8'h00;
        for (wi = 0; wi < 32;  wi = wi + 1) ior[wi] = 8'h00;

        $readmemh(progfile, prom);
        if (have_data) $readmemh(datafile, ram);

        f = $fopen(tracefile, "w");
        dbg_en = 0; stall_cnt = 0;
        if ($test$plusargs("debug")) dbg_en = 1;

        rst = 1;
        repeat (4) @(posedge clk);
        rst = 0;

        wait (done);
        repeat (8) @(posedge clk);          // 冲刷最后的轨迹锁存
        $fclose(f);
        $display("TB-DONE ret=%0d cyc=%0d halted=%0d", ret, cyc, halted);
        $finish;
    end

    // 逐指令退休轨迹（与 yxem --goldtrace 同格式）
    always @(posedge clk) begin
        if (!rst && dut.dbg_valid)
            $fdisplay(f, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                dut.dbg_pc, dut.dbg_op, dut.dbg_a, dut.dbg_b,
                dut.dbg_regs[0], dut.dbg_regs[1], dut.dbg_regs[2], dut.dbg_regs[3],
                dut.dbg_regs[4], dut.dbg_regs[5], dut.dbg_regs[6], dut.dbg_regs[7],
                dut.dbg_z, dut.dbg_c, dut.dbg_n, dut.dbg_wa, dut.dbg_wv);
    end

    // ---- 调试探针（+debug） ---------------------------------------------------
    always @(dut.state) if (dbg_en)
        $display("[%0t] state=%0d pc=%0d cyc=%0d", $time, dut.state, dut.pc_r, cyc);

    // 冻结窗口逐拍全信号
    always @(posedge clk)
        if (dbg_en && cyc >= 78 && cyc <= 92)
            $display("[win %0t] cyc=%0d state=%0d pc=%0d instr=%h retire=%b valid=%b halted=%b sp=%0d npc=%0d",
                     $time, cyc, dut.state, dut.pc_r, instr_r, dut.retire,
                     dut.dbg_valid, dut.halted_r, dut.sp, dut.npc);

    always @(posedge clk)
        if (dbg_en && !rst && dut.state == 2'd0 && !dut.retire) begin
            if (stall_cnt < 6)
                $display("[stall %0t] pc=%0d op=%h A=%h B=%h npc=%0d halted=%b sp=%0d instr=%h",
                         $time, dut.pc_r, dut.op, dut.A, dut.B, dut.npc,
                         dut.halted_r, dut.sp, instr_r);
            stall_cnt = stall_cnt + 1;
        end

endmodule
