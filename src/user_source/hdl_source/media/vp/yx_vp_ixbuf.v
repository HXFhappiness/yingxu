// yx_vp_ixbuf.v — YX-VP 索引缓冲管理器（方案 A：双索引缓冲 + 拷贝-补丁-翻转）
//
// ★ 板 B 专用模块。与 yx_vp_ixdec.v（补丁源）和 yx_vp_band.v（条带渲染）配对。
//
// 相态机：
//   READY    补丁直写 target（accept=1）；KEY 帧在此完成整帧
//   DRAIN    accept=0，等补丁 FIFO 排空（帧尾残留）
//   WAITFREE 等渲染器让出 target 缓冲（busy 标记）
//   SWAP     act 翻转、commit++、swap_done 脉冲；挂起的 DELTA 宣布 → COPY
//   COPY     DELTA：合并流重建 target=active+补丁——单遍扫描 cp_i 0..NB-1，
//            补丁流（块号严格递增）与拷贝流按块号对齐合并，输出恒为稠密
//            顺序流（下游 seq_wr 顺序写协议不变）；accept 保持打开，补丁
//            随到随合并（pf/skid 缓存+码流回压），补丁滞后时拷贝前沿等待；
//            完成后直接进 DRAIN。拷贝源经 cp 读口（仿真=TB 随机口模型，
//            板上=板级专用随机口方案，见体系设计文档）。
//
// 缓冲所有权：busy[i]=1 表示渲染器正在从缓冲 i 渲染（帧 k 用缓冲 k[0]，严格交替）。
// 写目标（dst = act^1）必须非 busy 才能动；渲染完成由 rendered_no 变更沿释放 busy。
// 解码器最多领先渲染器 1 帧：领先期间 accept=0，解码器 skid 吸收，流停。
module yx_vp_ixbuf #(
    parameter NB = 57600,               // 每帧块数（= 每缓冲索引字数）
    parameter AW = 17                   // 索引缓冲字地址位宽（2*NB <= 2^AW）
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 解码器补丁口 ----
    input  wire        ix_we,
    input  wire [16:0] ix_blk,
    input  wire [9:0]  ix_idx,
    output wire        ix_rdy,
    input  wire        frame_done,      // 解码器帧完成（补丁已全部发出）
    input  wire        frame_started,   // 解码器帧头首字节（宣布新帧，脉冲）
    input  wire        frame_kind,      // 0=KEY 1=DELTA（frame_started 拍有效）

    // ---- SDRAM 写口（下游节流）----
    output wire        wr_valid,
    output wire [AW-1:0] wr_addr,
    output wire [15:0] wr_data,
    input  wire        wr_gnt,

    // ---- SDRAM 拷贝读口 ----
    output wire        cp_rd,           // 电平式：等待期保持，dvld 撤销
    output reg  [AW-1:0] cp_addr,
    input  wire        cp_dvld,
    input  wire [15:0] cp_data,

    // ---- 渲染器侧 ----
    output reg         swap_done,       // 1 clk 脉冲：新帧已提交
    output reg  [15:0] commit_no,       // 已提交帧号（0 基）
    output reg  [AW-1:0] act_base,      // 当前 active 缓冲基址（渲染器锁存用）
    input  wire [15:0] rendered_no      // 渲染器最后完成帧号（0 基）
);
    localparam BUF_WORDS = NB;
    localparam PH_READY = 3'd0, PH_COPY = 3'd1, PH_DRAIN = 3'd2,
               PH_WAITFREE = 3'd3, PH_SWAP = 3'd4;

    reg [2:0]  phase;
    reg        act;                      // active 缓冲号（0/1）
    reg        busy [0:1];               // busy[i] = 渲染器正在渲染缓冲 i（帧 k 用缓冲 k[0]）
    reg        pend_v, pend_kind;        // 挂起的帧宣布（非 READY 期间锁存）
    reg [15:0] committed;                // 最后提交帧号（0 基；16'hffff = 无）
    reg [15:0] prev_rno;                 // 上次见过的渲染完成号（变更沿检测）
    wire       have_commit = (committed != 16'hffff);

    wire [AW-1:0] dst_base = act ? {AW{1'b0}} : BUF_WORDS[AW-1:0];   // 非 active
    wire [AW-1:0] src_base = act ? BUF_WORDS[AW-1:0] : {AW{1'b0}};   // active

    // ---- 补丁 FIFO（8 深 + 输出寄存器）----
    reg [26:0]  pf_mem [0:7];
    reg [2:0]  pf_wp, pf_rp;
    reg [3:0]  pf_cnt;
    reg        pf_ov;
    reg [26:0] pf_od;
    wire pf_pop;                           // 补丁消费（赋值见下方合并引擎处）
    wire pf_push = ix_we & ix_rdy & (phase == PH_READY || phase == PH_COPY);
    wire pf_load = !pf_ov && !pf_pop && (pf_cnt != 4'd0);
    wire pf_room = ((pf_cnt + {3'b0, pf_ov}) <= 4'd7);

    // ---- 拷贝引擎 v2（合并流：DELTA 帧单遍扫描，补丁与拷贝按块号对齐合并，
    //      输出恒为稠密顺序流 → 下游 seq_wr 顺序写协议不变）----
    // 推进规则（补丁流按块号严格递增，拷贝位置 cp_i 单调）：
    //   pf 头补丁 blk == cp_i → 发补丁字（该块被本帧修改，源字丢弃）
    //   pf 头 blk  > cp_i    → 读源字直发（该块未修改）
    //   pf 头 blk  < cp_i    → 协议违例（cp_err 计数告警，丢弃补丁防死锁）
    //   pf 空 且帧未完(fd=0) → 前沿等待（下一补丁可能命中 cp_i，不可越位）
    //   pf 空 且帧已完(fd=1) → 余段纯拷贝
    // 完成条件：cp_i==NB 且 pf 全空（fd 由推进规则蕴含）。COPY 期间 accept
    // 打开至本帧 frame_done（帧边界闸，见 ix_rdy 注释）：补丁随到随合并，
    // 经 pf(8)/skid(16) 缓存、码流自然回压，无需大容量缓冲。
    localparam CP_HOLD = 2'd0, CP_DEC = 2'd1, CP_RD = 2'd2, CP_GNT = 2'd3;
    reg [1:0]  cp_s;
    reg [16:0] cp_i;
    reg        cp_wv;
    reg [AW-1:0] cp_wa;
    reg [15:0] cp_wd;
    reg        cp_fd;                  // 本 DELTA 帧 frame_done 已见（补丁流终结标志）
    integer    cp_err = 16'd0;         // 补丁越位违例计数（健康运行恒 0）
    // 电平式拷贝读请求：等待期保持，dvld 到达撤销（刷新窗口不丢请求）
    assign cp_rd = (phase == PH_COPY) && (cp_s == CP_RD) && !cp_dvld;
    // 补丁消费：仅 COPY 相态由合并引擎按命中驱动（含越位丢弃）；其余相态 wr_gnt 弹出
    wire        pf_head_hit = (phase == PH_COPY) && (cp_s == CP_DEC) && pf_ov &&
                              (pf_od[26:10] <= cp_i) && !busy[act ^ 1];
    assign      pf_pop = pf_head_hit ? 1'b1 : (pf_ov & wr_gnt & (phase != PH_COPY));

    // ---- 写口呈现（COPY 相态 = 合并流写；其余 = 补丁输出寄存器；两相态互斥）----
    assign wr_valid = (phase == PH_COPY) ? cp_wv : pf_ov;
    assign wr_addr  = (phase == PH_COPY) ? cp_wa : (dst_base + pf_od[26:10]);
    assign wr_data  = (phase == PH_COPY) ? cp_wd : {6'b0, pf_od[9:0]};

    // 挂起帧宣布只在 SWAP 相态消费（act 翻转后拷贝的 src/dst 才有意义）；
    // READY 期间消费会用旧 act 启动拷贝，覆盖尚未提交的帧补丁。
    // ★ COPY 相态 accept 门控（帧边界闸）：本帧 frame_done/cp_fd 置位即关闸
    //   （含脉冲当拍，防 1 拍泄漏）。否则下一帧补丁会穿过 pf 与本帧补丁混序，
    //   被合并引擎按"越位"误弃、并堵死完成条件（实测 63K 丢补丁 + 合并
    //   每步 50~2700 拍爬行、12M 拍仅 2 帧的根因）。下一帧补丁等在
    //   skid/码流回压里，SWAP 后由下一个合并引擎接收。
    wire        ix_acc_phase = (phase == PH_READY) ||
                               (phase == PH_COPY && !cp_fd && !frame_done);
    assign ix_rdy = ix_acc_phase && pf_room && !busy[act ^ 1];

    wire [15:0] committed_new = have_commit ? committed + 16'd1 : 16'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_READY;
            act <= 1'b1;                        // 首帧补丁写 B0，维持"帧 k 在缓冲 k[0]"
            busy[0] <= 1'b0; busy[1] <= 1'b0;
            pend_v <= 1'b0; pend_kind <= 1'b0;
            committed <= 16'hffff;
            prev_rno <= 16'hffff;
            pf_wp <= 3'd0; pf_cnt <= 4'd0;
            // ★ P5：pf_ov/pf_od 的复位只保留在"补丁输出寄存器"块（下方单驱动）。
            //   同一个 reg 被两个 always 块驱动在 iverilog 里是竞态、在 TD 里直接
            //   报 "constantly driven from multiple places"。两处复位值相同，删除
            //   本块的重复复位不改变任何行为。
            cp_s <= CP_HOLD; cp_i <= 17'd0;
            cp_wv <= 1'b0; cp_wa <= {AW{1'b0}}; cp_wd <= 16'd0;
            cp_fd <= 1'b0;
            cp_addr <= {AW{1'b0}};
            swap_done <= 1'b0; commit_no <= 16'hffff;
            act_base <= {AW{1'b0}};
        end else begin
            swap_done <= 1'b0;

            // ---- 拷贝地址推进已并入合并引擎（CP_DEC 直发源读请求，电平驱动）----

            // ---- 渲染完成 → 释放该帧的缓冲（帧 k 在缓冲 k[0]）----
            if (rendered_no != prev_rno && rendered_no != 16'hffff) begin
                busy[rendered_no[0]] <= 1'b0;
                prev_rno <= rendered_no;
            end

            // ---- 补丁 FIFO 推送 ----
            if (pf_push) begin
                pf_mem[pf_wp] <= {ix_blk, ix_idx};
                pf_wp <= pf_wp + 3'd1;
            end

            case (phase)
            PH_READY: begin
                if (frame_done)
                    phase <= PH_DRAIN;
            end

            PH_COPY: begin
                if (frame_done) cp_fd <= 1'b1;  // 补丁流终结（任意子状态可达）
                if (busy[act ^ 1]) begin
                    cp_s <= CP_HOLD;            // 目标缓冲被渲染占用：整段暂停（补丁缓存于 pf/skid）
                end else begin
                    case (cp_s)
                    CP_HOLD: cp_s <= CP_DEC;
                    CP_DEC: begin
                        if (!pf_ov && pf_cnt == 4'd0 && cp_i == NB[16:0]) begin
                            phase <= PH_DRAIN;  // 整窗合并完成（补丁流已被前沿规则全部消费）
                        end else if (pf_ov && pf_od[26:10] <= cp_i) begin
                            if (pf_od[26:10] == cp_i && cp_i != NB[16:0]) begin
                                cp_wv <= 1'b1;  // 补丁命中：发补丁字（源字丢弃）
                                cp_wa <= dst_base + cp_i[16:0];
                                cp_wd <= {6'b0, pf_od[9:0]};
                                cp_i  <= cp_i + 17'd1;
                                cp_s  <= CP_GNT;
                            end else begin
                                // 越位违例（构造上不可达）：丢弃补丁防死锁 + 计数告警
                                cp_err <= cp_err + 16'd1;
                                if (cp_err < 8)
                                    $display("IXBUF-CPERR t=%0t cp_i=%0d head_blk=%0d",
                                             $time, cp_i, pf_od[26:10]);
                            end
                        end else if (pf_ov || cp_fd) begin
                            cp_addr <= src_base + cp_i[16:0];   // 源字直发（pf 头越前或帧已完）
                            cp_s    <= CP_RD;
                        end
                        // 其余：pf 空且帧未完 → 前沿等待（原地不动，等补丁到位）
                    end
                    CP_RD: if (cp_dvld) begin
                        cp_wv <= 1'b1;
                        cp_wa <= dst_base + cp_i[16:0];
                        cp_wd <= cp_data;
                        cp_i  <= cp_i + 17'd1;
                        cp_s  <= CP_GNT;
                    end
                    CP_GNT: if (wr_gnt && cp_wv) begin
                        cp_wv <= 1'b0;
                        cp_s  <= CP_DEC;
                    end
                    default: cp_s <= CP_DEC;
                    endcase
                end
            end

            PH_DRAIN: begin
                if (pf_cnt == 4'd0 && !pf_ov) begin
                    if (busy[act ^ 1])
                        phase <= PH_WAITFREE;
                    else
                        phase <= PH_SWAP;
                end
            end

            PH_WAITFREE: begin
                if (!busy[act ^ 1])
                    phase <= PH_SWAP;
            end

            PH_SWAP: begin
                act      <= ~act;
                act_base <= dst_base;
                busy[~act] <= 1'b1;                 // 渲染器将渲染新 active（帧 committed_new）
                committed <= committed_new;
                commit_no <= committed_new;
                swap_done <= 1'b1;
                phase <= PH_READY;
                if (pend_v && pend_kind) begin
                    phase <= PH_COPY;               // 挂起 DELTA：合并流重建
                    cp_s <= CP_HOLD;
                    cp_i <= 17'd0;
                    cp_wv <= 1'b0;
                    cp_fd <= 1'b0;
                end
                pend_v <= 1'b0;
            end
            default: phase <= PH_READY;
            endcase

            // ---- DELTA 帧宣布：READY 立即合并重建；其余相态锁存（SWAP 后启动）----
            if (frame_started && frame_kind) begin
                if (phase == PH_READY && !frame_done) begin
                    phase <= PH_COPY;
                    cp_s  <= CP_HOLD;
                    cp_i  <= 17'd0;
                    cp_wv <= 1'b0;
                    cp_fd <= 1'b0;
                end else begin
                    pend_v    <= 1'b1;
                    pend_kind <= 1'b1;
                end
            end

            // ---- 补丁 FIFO 计数（装载 -1 转入输出寄存器；弹出不再扣——字已在装载时出账）----
            pf_cnt <= pf_cnt + {3'b0, pf_push} - {3'b0, pf_load};
        end
    end

    // ---- 补丁输出寄存器 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pf_ov <= 1'b0; pf_od <= 27'd0; pf_rp <= 3'd0;
        end else begin
            if (pf_load) begin
                pf_ov <= 1'b1;
                pf_od <= pf_mem[pf_rp];
            end else if (pf_pop) begin
                pf_ov <= 1'b0;
                pf_rp <= pf_rp + 3'd1;          // ★ 出队推进读指针（此前缺失：FIFO 反复吐同一字）
            end
        end
    end
endmodule
