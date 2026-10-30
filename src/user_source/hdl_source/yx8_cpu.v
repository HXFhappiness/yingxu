// =============================================================================
// yx8_cpu.v — YX-8 自研 8 位处理器（映序，工程代号 YX-8）
// 单周期数据通路；JMP/JSR 双字双周期；WFI 挂起至 frame_tick。
//
// 指令集与 tools/yxem.py（模拟器）逐条对齐（v1.1.2 冻结规范）：
//   - 定长 24 位 [op][A][B]；R0-R7（X=R3 变址）
//   - CMP/CMPI 只更新 Z/N/C，绝不写回寄存器
//   - SHL/SHR/ROL/ROR 移位量取 v2[2:0]（RR 类=寄存器值，立即数类=B）；C=最后
//     移出位；ROL/ROR 为 8 位循环（C 不参与循环）
//   - SUB/SBC/CMP 的 C=1 表示无借位（dst>=src）
//   - 分支目标 = 本指令地址+1+sext(B)；全程序空间 mod 2^PW
//
// 总线约定：
//   instr   — 程序存储器同步读输出。顶层：always @(posedge clk)
//             instr_r <= prom[next_pc[PW-1:0]]；本核同时钟沿 pc_r<=next_pc 掩码，
//             instr 与 pc_r 恒对齐（每拍执行一条）。
//   数据侧为异步总线（数据 RAM 用 LUTRAM 实现，保持单周期）。
//
// 仿真：定义 COSIM 宏暴露 dbg_* 逐指令退休观测（供共生验证）。综合不定义，零开销。
// =============================================================================
`timescale 1ns / 1ps

module yx8_cpu #(
    parameter PW = 10,                      // 程序空间 2^PW 字
    parameter integer WAIT_CYCLES = 1       // S_WAIT 停留的拍数（匹配 BRAM 读延迟）
)(
    input  wire        clk,
    input  wire        rst,                 // 同步高有效
    input  wire [9:0]  entry,               // 复位启动 PC（G3：入口由加载器给）

    input  wire [23:0] instr,
    output wire [15:0] next_pc,

    output wire [7:0]  daddr,
    output wire [7:0]  dwdata,
    output wire        dwe,
    input  wire [7:0]  drdata,              // 异步读

    input  wire        frame_tick,
    output wire        halted,
    output wire        retire,
    output wire [15:0] pc_out
);

    // ---- 状态 ------------------------------------------------------------
    localparam [1:0] S_WAIT = 2'd3,
                 S_RUN = 2'd0, S_F2 = 2'd1, S_WFI = 2'd2;
    reg [1:0]  state;
    reg [15:0] pc_r;
    reg        halted_r;
    reg [7:0]  lo_r;
    reg        jsr_r;                       // 译码拍记住 JSR（F2 拍 instr 已是第二字）
    reg        jmp_r;                       // G4: JMP/JSR 先经 S_WAIT 再进 F2——
                                            // 保证第二字走完两拍取指（复位后首条
                                            // JSR 的 F2 曾重读第一字，npc={A,lo} 跳飞）

    // ---- 寄存器堆 / 标志 / 硬件栈 ----------------------------------------
    reg [7:0]  regs [0:7];
    reg        flag_z, flag_c, flag_n;
    reg [15:0] stack [0:63];
    reg [5:0]  sp;
    reg [1:0]  wait_cnt;

    // ---- 指令字段 ---------------------------------------------------------
    wire [7:0] op = instr[23:16];
    wire [7:0] A  = instr[15:8];
    wire [7:0] B  = instr[7:0];

    // ---- 类别译码 ---------------------------------------------------------
    wire is_imm_cls = (op[7:4] == 4'h2) && ((op[3:0] < 4'hA) || (op == 8'h2C));
    wire is_jmp_jsr = (op == 8'h50) || (op == 8'h51);
    wire is_str     = (op == 8'h32) || (op == 8'h33);
    wire is_ldr     = (op == 8'h30) || (op == 8'h31);
    wire is_rts     = (op == 8'h04);
    wire is_wfi     = (op == 8'h03);
    wire is_hlt     = (op == 8'h05);
    wire is_clc     = (op == 8'h01);
    wire is_sec     = (op == 8'h02);

    // ---- ALU 操作数 -------------------------------------------------------
    wire [7:0] v1 = regs[A[2:0]];
    wire [7:0] v2 = is_imm_cls ? B : regs[B[2:0]];
    wire [2:0] sh = v2[2:0];

    wire [8:0] sum9 = {1'b0, v1} + {1'b0, v2};
    wire [8:0] adc9 = {1'b0, v1} + {1'b0, v2} + {8'b0, flag_c};
    wire [8:0] dif9 = {1'b0, v1} - {1'b0, v2};
    wire [8:0] sbc9 = {1'b0, v1} - {1'b0, v2} - {8'b0, ~flag_c};
    wire [8:0] neg9 = 9'd0 - {1'b0, v1};

    // ---- 显式移位器（不用动态 << / >>，避免综合后失效）----
    // shl9 = {搬出位, 结果[7:0]}；shr9 同理。sh=0 时不动、搬出位为 0。
    reg  [8:0] shl9, shr9;
    always @(*) begin
        case (sh)
        3'd0: shl9 = {1'b0, v1};
        3'd1: shl9 = {v1[7], v1[6:0], 1'b0};
        3'd2: shl9 = {v1[6], v1[5:0], 2'b00};
        3'd3: shl9 = {v1[5], v1[4:0], 3'b000};
        3'd4: shl9 = {v1[4], v1[3:0], 4'b0000};
        3'd5: shl9 = {v1[3], v1[2:0], 5'b00000};
        3'd6: shl9 = {v1[2], v1[1:0], 6'b000000};
        default: shl9 = {v1[1], v1[0], 7'b0000000};
        endcase
        case (sh)
        3'd0: shr9 = {1'b0, 1'b0, v1};
        3'd1: shr9 = {v1[0], 1'b0, v1[7:1]};
        3'd2: shr9 = {v1[1], 2'b00, v1[7:2]};
        3'd3: shr9 = {v1[2], 3'b000, v1[7:3]};
        3'd4: shr9 = {v1[3], 4'b0000, v1[7:4]};
        3'd5: shr9 = {v1[4], 5'b00000, v1[7:5]};
        3'd6: shr9 = {v1[5], 6'b000000, v1[7:6]};
        default: shr9 = {v1[6], 7'b0000000, v1[7]};
        endcase
    end

    wire [7:0] sh_l = shl9[7:0];
    wire [7:0] sh_r = shr9[7:0];
    wire       shr_c = shr9[8];

    // ---- ALU / 标志 / 写回（组合） ----------------------------------------
    reg  [7:0] alu_r;
    reg        fz, fn, fc;
    reg        we_reg;

    always @(*) begin
        alu_r  = v1;
        fz     = flag_z;  fn = flag_n;  fc = flag_c;
        we_reg = 1'b0;
        case (op)
        // ---- 寄存器-寄存器 ----
        8'h10: begin alu_r = sum9[7:0]; fz = (alu_r==8'h00); fn = alu_r[7]; fc = sum9[8];  we_reg=1; end
        8'h11: begin alu_r = adc9[7:0]; fz = (alu_r==8'h00); fn = alu_r[7]; fc = adc9[8];  we_reg=1; end
        8'h12: begin alu_r = dif9[7:0]; fz = (alu_r==8'h00); fn = alu_r[7]; fc = ~dif9[8]; we_reg=1; end
        8'h13: begin alu_r = sbc9[7:0]; fz = (alu_r==8'h00); fn = alu_r[7]; fc = ~sbc9[8]; we_reg=1; end
        8'h14: begin alu_r = v1 & v2;   fz = (alu_r==8'h00); fn = alu_r[7]; we_reg=1; end
        8'h15: begin alu_r = v1 | v2;   fz = (alu_r==8'h00); fn = alu_r[7]; we_reg=1; end
        8'h16: begin alu_r = v1 ^ v2;   fz = (alu_r==8'h00); fn = alu_r[7]; we_reg=1; end
        8'h17: begin                    fz = (dif9[7:0]==8'h00); fn = dif9[7]; fc = ~dif9[8]; end
        8'h18: begin alu_r = sh_l;      fz = (alu_r==8'h00); fn = alu_r[7]; fc = sh ? shl9[8] : flag_c; we_reg=1; end
        8'h19: begin alu_r = sh_r;      fz = (alu_r==8'h00); fn = alu_r[7]; fc = sh ? shr_c : flag_c;   we_reg=1; end
        8'h1A: begin alu_r = sh_l;      fz=(alu_r==8'h00); fn=alu_r[7]; fc = flag_c; we_reg=1; end
        8'h1B: begin alu_r = sh_r;      fz=(alu_r==8'h00); fn=alu_r[7]; fc = flag_c; we_reg=1; end
        8'h1C: begin alu_r = v2;        fz = (alu_r==8'h00); fn = alu_r[7]; we_reg=1; end
        8'h1D: begin alu_r = v1 + 8'd1; fz = (alu_r==8'h00); fn = alu_r[7]; we_reg=1; end
        8'h1E: begin alu_r = v1 - 8'd1; fz = (alu_r==8'h00); fn = alu_r[7]; we_reg=1; end
        8'h1F: begin alu_r = neg9[7:0]; fz = (alu_r==8'h00); fn = alu_r[7]; we_reg=1; end
        // ---- 立即数 ----
        8'h20: begin alu_r = sum9[7:0]; fz = (alu_r==8'h00); fn = alu_r[7]; fc = sum9[8];  we_reg=1; end
        8'h21: begin alu_r = adc9[7:0]; fz = (alu_r==8'h00); fn = alu_r[7]; fc = adc9[8];  we_reg=1; end
        8'h22: begin alu_r = dif9[7:0]; fz = (alu_r==8'h00); fn = alu_r[7]; fc = ~dif9[8]; we_reg=1; end
        8'h23: begin alu_r = sbc9[7:0]; fz = (alu_r==8'h00); fn = alu_r[7]; fc = ~sbc9[8]; we_reg=1; end
        8'h24: begin alu_r = v1 & v2;   fz = (alu_r==8'h00); fn = alu_r[7]; we_reg=1; end
        8'h25: begin alu_r = v1 | v2;   fz = (alu_r==8'h00); fn = alu_r[7]; we_reg=1; end
        8'h26: begin alu_r = v1 ^ v2;   fz = (alu_r==8'h00); fn = alu_r[7]; we_reg=1; end
        8'h27: begin                    fz = (dif9[7:0]==8'h00); fn = dif9[7]; fc = ~dif9[8]; end
        8'h28: begin alu_r = sh_l;      fz = (alu_r==8'h00); fn = alu_r[7]; fc = sh ? shl9[8] : flag_c; we_reg=1; end
        8'h29: begin alu_r = sh_r;      fz = (alu_r==8'h00); fn = alu_r[7]; fc = sh ? shr_c : flag_c; we_reg=1; end
        8'h2C: begin alu_r = B;         fz = (alu_r==8'h00); fn = alu_r[7]; we_reg=1; end
        // ---- 杂项 ----
        8'h01: fc = 1'b0;                                                      // CLC
        8'h02: fc = 1'b1;                                                      // SEC
        default: ;                                                             // NOP/访存/分支/控制流：标志保持
        endcase
    end

    wire [7:0] wb_data = is_ldr ? drdata : alu_r;
    wire       we_regs = we_reg || is_ldr;

    // ---- 数据总线 ---------------------------------------------------------
    assign daddr  = (op[0] && (op[7:4] == 4'h3)) ? (B + regs[3]) : B;  // 0x31/0x33 变址
    assign dwdata = v1;
    assign dwe    = is_str;

    // ---- 分支 -------------------------------------------------------------
    wire br_take = (op == 8'h40 && flag_z) || (op == 8'h41 && !flag_z) ||
                   (op == 8'h42 && flag_c) || (op == 8'h43 && !flag_c) ||
                   (op == 8'h44 && flag_n) || (op == 8'h45 && !flag_n) ||
                   (op == 8'h46);
    wire [15:0] sext_b = {{7{B[7]}}, B};
    wire [5:0]  sp_m1  = sp - 6'd1;

    // ---- 下一 PC（组合；赋值处统一掩码到 PW 位） ---------------------------
    reg [15:0] npc;
    always @(*) begin
        npc = pc_r + 16'd1;
        case (state)
        S_RUN: begin
            if (is_hlt)                    npc = pc_r;
            else if (is_rts)               npc = stack[sp_m1];
            else if (br_take)              npc = pc_r + 16'd1 + sext_b;
            // JMP/JSR/WFI/default：pc+1（JMP/JSR 由 F2 拍改道）
        end
        S_F2:  npc = {instr[15:8], lo_r};
        S_WFI: npc = pc_r;
        S_WAIT: npc = pc_r + 16'd1;
        default: npc = pc_r + 16'd1;
        endcase
    end
    // 复位期 next_pc=entry：程序 RAM 预取 prom[entry]，与 pc_r 对齐（读口不带
    // 复位 mux，保 BRAM 推断）
    assign next_pc = rst ? {6'b0, entry} : npc;

    wire retire_i = !halted_r && ((state == S_RUN && !is_jmp_jsr) || (state == S_F2));
    assign retire = retire_i;
    assign pc_out = pc_r;

    // ---- 时序 -------------------------------------------------------------
    integer i;
    // G4 修复：S_WAIT 等待拍里取指已就位、ALU 组合逻辑一直在算——寄存器/标志
    // 写回必须只在执行拍发生，否则非幂等指令（移位/加减/INC/DEC）会被等待拍
    // 提前写一次、执行拍再写一次，等效双执行（板上 4<<2 得 16 的根源）。
    wire exec_cyc = (state == S_RUN) || (state == S_F2);
    always @(posedge clk) begin
        if (rst) begin
            state    <= S_RUN;
            pc_r     <= {6'b0, entry};
            halted_r <= 1'b0;
            sp       <= 6'd0;
            wait_cnt <= 2'd0;
            jsr_r    <= 1'b0;
            jmp_r    <= 1'b0;
            flag_z   <= 1'b0;
            flag_c   <= 1'b0;
            flag_n   <= 1'b0;
            lo_r     <= 8'd0;
            for (i = 0; i < 8; i = i + 1) regs[i] <= 8'd0;
        end
        else begin
            if (exec_cyc) begin
                flag_z <= fz;
                flag_c <= fc;
                flag_n <= fn;

                if (we_regs) regs[A[2:0]] <= wb_data;
            end

            case (state)
            S_RUN: begin
                if (is_hlt) begin
                    halted_r <= 1'b1;
                    pc_r     <= pc_r & 16'h03FF;
                end
                else if (is_wfi) begin
                    state <= S_WFI;
                    pc_r  <= (pc_r + 16'd1) & 16'h03FF;
                end
                else if (is_jmp_jsr) begin
                    state <= S_WAIT;         // G4: 先经 S_WAIT，第二字才到 instr
                    lo_r  <= A;
                    jsr_r <= (op == 8'h51);
                    jmp_r <= 1'b1;
                    pc_r  <= (pc_r + 16'd1) & 16'h03FF;
                end
                else begin
                    pc_r <= npc & 16'h03FF;
                    state <= S_WAIT;   // 等一拍取指（RAM 两拍读）      // 顺序/分支/RTS
                    if (is_rts) sp <= sp_m1;
                end
            end
            S_F2: begin
                pc_r <= npc & 16'h03FF;          // 目标地址
                if (jsr_r) begin                 // JSR：压栈返回地址（标志来自译码拍）
                    stack[sp] <= (pc_r + 16'd1) & 16'h03FF;
                    sp        <= sp + 6'd1;
                end
                state <= S_WAIT;
            end
            S_WAIT: begin
                if (wait_cnt + 2'd1 >= WAIT_CYCLES[1:0]) begin
                    wait_cnt <= 2'd0;
                    state    <= jmp_r ? S_F2 : S_RUN;  // G4: JMP/JSR 二段取指
                    jmp_r    <= 1'b0;
                end
                else begin
                    wait_cnt <= wait_cnt + 2'd1;
                end
            end
            S_WFI: begin
                if (frame_tick) state <= S_WAIT;  // pc 已在 WFI 译码拍前移
            end
            default: state <= S_RUN;
            endcase
        end
    end

    assign halted = halted_r;

`ifdef COSIM
    // ---- 共生验证观测（逐指令退休后全状态；综合时不存在） -------------------
    integer ci;
    reg        dbg_valid;
    reg [15:0] dbg_pc;
    reg [7:0]  dbg_op, dbg_a, dbg_b;
    reg [7:0]  dbg_regs [0:7];
    reg        dbg_z, dbg_c, dbg_n;
    reg [8:0]  dbg_wa;      // 9'h1FF = 无写
    reg [7:0]  dbg_wv;
    reg [7:0]  hold_op, hold_a, hold_b;
    reg [15:0] hold_pc;
    reg        in_f2;

    always @(posedge clk) begin
        if (rst) begin
            dbg_valid <= 1'b0;
            in_f2     <= 1'b0;
        end
        else begin
            if (state == S_RUN && is_jmp_jsr && !halted_r) begin
                hold_op <= op;  hold_a <= A;  hold_b <= B;  hold_pc <= pc_r;
            end
            in_f2 <= (state == S_F2);
            dbg_valid <= retire;
            if (retire) begin
                if (state == S_F2) begin
                    dbg_pc <= hold_pc;  dbg_op <= hold_op;
                    dbg_a  <= hold_a;   dbg_b  <= hold_b;
                end
                else begin
                    dbg_pc <= pc_r;  dbg_op <= op;  dbg_a <= A;  dbg_b <= B;
                end
                for (ci = 0; ci < 8; ci = ci + 1)
                    dbg_regs[ci] <= (we_regs && (ci[2:0] == A[2:0])) ? wb_data : regs[ci];
                dbg_z <= fz;  dbg_c <= fc;  dbg_n <= fn;
                dbg_wa <= dwe ? {1'b0, daddr} : 9'h1FF;
                dbg_wv <= dwe ? dwdata       : 8'h00;
            end
        end
    end
`endif

endmodule
