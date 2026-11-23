// yx_b_ix_fetch.v — 板 B 渲染取带读出适配器 v5（region 屏障 + 每带 LOAD + hold 重载
//                    + ixbuf 拷贝读口 RD2 分时服务）
//
// band 的 rd_req/rd_dvld 字接口由 RD2 顺序流承载；本模块把 RD2 FIFO 的
// 32bit 字（{16'h0, idx}）拆出低半交给 band。
//
// 握手协议：
//   · band 侧 rd_req 电平保持至 dvld（dvld 高时 rd_req 自动撤销）
//   · rd_dvld = out_v 电平；置位次拍由 band 采样消费，同沿清零
//   · FIFO do 为 pop 沿寄存（shim 实测语义）
//
// ★ v4 读地址协议（每带 LOAD，绕开 rRD2_MAX_ADDR 复位锁存局限）：
//   vendor 控制器的 rRD2_MAX_ADDR 只在复位锁存（LOAD 不锁 MAX，Sdram_
//   Control_4Port.v :517-518/:566-569），步进条件 rRD2_ADDR < MAX-LENGTH
//   使"整窗循环读"在窗 1 死循环读窗头 256 字（MAX=复位值=窗 0 尾 → 窗 1
//   首突发后恒回卷引脚）——帧 0 完美、帧 1+ 数据源全错的根因。v4 改为：
//   RD2_LENGTH=64（带 320 字=5 突发整除）、MAX 引脚恒 0x1FFFFF（永不自动
//   回卷）、fetch 按交付字数自数带边界（每 320 字），带边界走 mini-hold：
//   弹空 FIFO+等在途完+LOAD 锁新带首地址（need_base+带序×320）→ 控制器
//   恢复后从新带首读。窗尾（带 179 交付完）不再 LOAD，等待帧切换 reload。
//
// ★ hold 两段（v3 保留）：
//   WAIT   → 不拉 LOAD、不弹 FIFO：等目标窗已完整落 SDRAM
//            （region_valid && region_win==need_win）。带边界 mini-reload
//            时 ok_now 恒真（同窗服务期间），WAIT 立即转 FLUSH。
//   FLUSH  → 保持 LOAD（冻结所有新通道调度；在途突发照常完成）+ 持续弹空
//            FIFO（丢弃控制器超读的前缀/线性越界垃圾），撤条件 = FIFO 空
//            && 无在途突发 → LOAD 尾拍锁存新地址 → 撤 LOAD 次拍调度恢复
//            → 服务 rd_req。
//   帧切换 reload 与带边界 mini-reload 共用同一 hold 机制。
//
// ★★★ v5 新增：ixbuf 拷贝读口（cp_req/cp_addr ← ixbuf.cp_rd/cp_addr）由本
//   模块经 RD2 顺序流承载——"随机口板级方案"契约就此闭环：板上 cp 读不再
//   是顶层随机口（P4/P5 无需行为模型代管），而是 RD2 读流的一段分时复用。
//   设计要点（详见 docs/YX_BBOARD_CPRD_20261121.md）：
//   · cp 读是严格顺序流（cp_addr = 源窗基址 + cp_i，单调不减）；DELTA 补丁
//     命中使 cp_addr 前跳 1 字/补丁（≤5638/帧）→ 头部惰性丢弃追平，成本可忽略；
//   · 服务时机 = fetch 静默窗（band 数据流零扰动；KEY 流无 DELTA、cp 逻辑
//     永不激活 → 行为与 v4 逐位一致）：帧尾空闲 frame_done_f（末带末字交付
//     完、等下一帧 reload）——case-b/pend 的合并在帧尾空闲窗全速完成。
//     ★ v5b：reload-WAIT 窗不服务（SWAP(N) 以 merge(N) 完成为前提，ok_now
//       只滞后末突发 ~150 拍，纯轮询；实测此窗服务 = 无交付 LOAD + 立即 kill）。
//   · 流连续性（cp_pos = FIFO 头字地址，cp_req 期间）：
//       cp_pos <  cp_addr → 丢弃追平；cp_pos == cp_addr → 交付；
//       cp_pos >  cp_addr → 等 merge 前进（skid 在途，不 pop）。
//     cp_addr < cp_pos（新 COPY 换窗重起点）或 cp_pos_v=0（首次/被抢占）→
//     静默点重 LOAD（★64 对齐下取整）：LOAD 冻结全部通道调度 + 弹空在途
//     （同 v4 FLUSH 收尾），空且无在途突发时锁对齐地址 → 释放 → 控制器
//     连续过读。
//   · ★ v5b 64 对齐根因修复：full-page 突发在行边界（256=4×64）内回绕，
//     线性步进的未对齐 LOAD（如 57743，mod64=15）每行一次跨界突发返回本行
//     头部数据 → 交付错位（实测 1585 字、igold/golden FAIL）。对齐后突发恒
//     不跨行；cp_pos 同步对齐，首段 ≤63 字走 discard 追平。band/reload 路径
//     天然对齐（320=5×64）故基线从未暴露。详见 docs/YX_BBOARD_CPRD_20261121.md §0。
//   · 交付握手与 TB 随机口模型同款：cp_dvld 1 拍脉冲、cp_data 同拍有效、
//     仅在 cp_req（merge 处于 CP_RD 等待）时报价（防 merge 未采样被双消费）、
//     报价满 1 拍即撤（merge 必在 CP_RD 内采样）。merge 经补丁越过 skid 字
//     （cp_addr > word_a，防御性）→ 丢弃重同步。
//   · 带宽核算：cp 每 DELTA 帧 57600 次交付 × ~4 拍/字 ≈ 23 万拍，落在帧尾
//     空闲窗（渲染 139 万拍），帧周期 +~16%；读带宽占比 ~0.25 字/拍（RD1/WR2
//     并行余量充足）。KEY 帧零开销。
module yx_b_ix_fetch #(
    parameter AW = 17,
    parameter NB = 57600             // 补丁数/帧（= 每窗字数）
)(
    input  wire        clk,
    input  wire        rst_n,
    // ---- band 读口 ----
    input  wire        rd_req,       // 电平：等待期保持，dvld 撤销
    output reg         rd_dvld,      // 电平 = out_v（band 采样沿自动消费）
    output reg  [15:0] rd_data,
    // ---- ixbuf 拷贝读服务（v5 新增；体系模式由顶层连 ixbuf.cp 口，抽象模式悬空）----
    input  wire        cp_req,       // = ixbuf.cp_rd（电平：等源字，dvld 撤销）
    input  wire [AW-1:0] cp_addr,    // = 源窗基址 + cp_i（单调不减）
    output reg         cp_dvld,      // 1 拍脉冲 = 交付 1 字（TB 模型同款语义）
    output wire [15:0] cp_data,      // = skid 字（组合呈现，dvld 拍有效）
    // ---- RD2 口 ----
    input  wire [31:0] rd2_fifo_dat, // RD2_DATA（do 为 pop 沿寄存）
    input  wire        rd2_empty,
    output reg         rd2_re,       // FIFO pop
    output reg  [20:0] rd2_addr,
    output reg         rd2_load,     // 单拍 LOAD（reload/带边界拍；FLUSH 期保持）
    input  wire        rd2_we,       // 控制器写 FIFO 脉冲（OUT_VALID&RD_MASK[1]，顶层给）
    input  wire        rd2_bmask1,   // RD_MASK[1]：RD2 突发在途标志（顶层给）
    // ---- 切区 ----
    input  wire        reload,       // 1 clk 脉冲（swap_done 次拍）
    input  wire [20:0] reload_base,  // 新 act 区基址
    // ---- seq_wr 窗完成屏障（按窗独立 2 位标志）----
    input  wire [1:0]  region_done   // done[k]=窗 k 已完整落 SDRAM 且未被重写
);
    localparam BPW = 320;            // 每带索引字数（W/4 = 1280/4）
    localparam BW  = NB/BPW;         // 带数/帧 = 180

    reg        out_v;
    reg        hold;                 // 重载期：WAIT（等窗写完）→ FLUSH（弹空+LOAD）
    reg        drain;                // FLUSH 弹空进行中（保留观测名）
    reg [15:0] push_cnt, pop_cnt;    // FIFO 占用自计数（同域）
    reg [15:0] drain_cnt;            // 保留观测名
    reg        old_done;             // 保留观测名
    reg        cap;                  // pop 次拍捕获标志
    reg        load_r;               // LOAD 次拍（LOAD 撤后首拍不 pop）
    reg [15:0] out_d;
    reg        need_win;             // 目标窗号（reload 锁存）
    reg [20:0] need_base;            // 目标窗基址（reload 锁存）
    reg [8:0]  bidx;                 // 窗内带序 0..BW-1（LOAD 地址按带推进）
    reg [8:0]  wcnt;                 // 带内已交付字数 0..BPW-1

    // ---- v5 cp 服务（RD2 分时）----
    reg        cp_on;                // cp 占有 RD2（band 交付链静止；仅静默窗进入）
    reg        cp_ld;                // 1=静默+重LOAD 子态  0=续传/交付子态
    reg        cp_pos_v;             // 流位置有效（cp LOAD 后置位；reload/退出清除）
    reg [20:0] cp_pos;               // FIFO 头字地址（每 pop +1）
    reg        cp_pop_p;             // pop 已发（次拍进 cap）
    reg        cp_cap_p;             // cap 已发（次拍装 skid 或丢弃）
    reg        cp_pop_disc;          // 本次 pop 为丢弃（capture 时直接扔）
    reg        cp_w_v;               // skid 字有效
    reg [15:0] cp_w_d;               // skid 字数据
    reg [20:0] cp_w_a;               // skid 字地址（报价对齐核验）
    reg        frame_done_f;         // 帧尾：末带末字已交付（idle cp 服务窗开启）

    wire [15:0] occ = push_cnt - pop_cnt;   // 占用自算（观测用）
    // 目标窗已完整落 SDRAM（按窗独立标志：写入领先渲染 1 窗时不会滚走）
    wire        ok_now = region_done[need_win];
    // cp 交付链静止（band 链 out_v/cap 与 cp 链互斥使用 rd2_re，进入前必须全空）
    wire        cp_quiet = !out_v && !cap && !cp_pop_p && !cp_cap_p && !cp_w_v && !cp_dvld;
    // cp 流续传判定：位置有效且请求地址不落后于流头（落后=新 COPY 换窗，须重 LOAD）
    wire        cp_stream_ok = cp_pos_v && (cp_addr >= cp_pos);

`ifdef YX_CP_DBG
    always @(posedge clk) begin
        if (rst_n) begin
            if (reload && cp_on)
                $display("CPDBG %0t PREEMPT pos=%0d dlv-in-flight", $time, cp_pos);
            if (!reload && !cp_on && !hold && frame_done_f && !rd_req && cp_req && cp_quiet)
                $display("CPDBG %0t ENTER-IDLE addr=%0d sok=%b", $time, cp_addr, cp_stream_ok);
            if (!reload && !cp_on && hold && !drain && !ok_now && cp_req && cp_quiet)
                $display("CPDBG %0t WAIT-NO-SVC addr=%0d ok=%b", $time, cp_addr, ok_now);
            if (cp_on && cp_ld && rd2_empty && !rd2_bmask1)
                $display("CPDBG %0t LOAD-DONE addr=%0d", $time, cp_addr);
            if (cp_dvld)
                $display("CPDBG %0t DELIV wa=%0d d=%04h", $time, cp_w_a, cp_w_d);
        end
    end
`endif

    assign cp_data = cp_w_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_dvld <= 1'b0; rd_data <= 16'd0;
            rd2_re <= 1'b0; rd2_addr <= 21'd0; rd2_load <= 1'b0;
            out_v <= 1'b0; out_d <= 16'd0;
            hold <= 1'b0; drain <= 1'b0; cap <= 1'b0; load_r <= 1'b0;
            push_cnt <= 16'd0; pop_cnt <= 16'd0; drain_cnt <= 16'd0;
            old_done <= 1'b1;
            need_win <= 1'b0; need_base <= 21'd0;
            bidx <= 9'd0; wcnt <= 9'd0;
            cp_on <= 1'b0; cp_ld <= 1'b0;
            cp_pos_v <= 1'b0; cp_pos <= 21'd0;
            cp_pop_p <= 1'b0; cp_cap_p <= 1'b0; cp_pop_disc <= 1'b0;
            cp_w_v <= 1'b0; cp_w_d <= 16'd0; cp_w_a <= 21'd0;
            cp_dvld <= 1'b0;
            frame_done_f <= 1'b0;
        end else begin
            rd2_re   <= 1'b0;
            rd2_load <= 1'b0;             // 单拍 LOAD：默认清
            load_r  <= rd2_load;
            rd_dvld <= out_v;

            // FIFO 占用自计数（rd2_we 与本模块同域；cp pop 一并计入）
            push_cnt <= push_cnt + (rd2_we ? 16'd1 : 16'd0);
            pop_cnt  <= pop_cnt  + (rd2_re ? 16'd1 : 16'd0);

            // ---- 帧切换（最高优先级，抢占 cp 服务）：锁存目标窗，单拍 LOAD 重置
            //      读指针，进 hold/WAIT；cp 流作废（新窗地址流不连续，在途突发
            //      残留由 FLUSH 弹空）----
            if (reload) begin
                need_win  <= (reload_base >= NB[20:0]);
                need_base <= reload_base;
                rd2_addr  <= reload_base;
                rd2_load  <= 1'b1;
                hold      <= 1'b1;
                drain     <= 1'b0;
                out_v     <= 1'b0;
                cap       <= 1'b0;
                bidx      <= 9'd0;
                wcnt      <= 9'd0;
                frame_done_f <= 1'b0;
                // cp 抢占复位（skid/报价/管线作废）
                cp_on <= 1'b0; cp_ld <= 1'b0;
                cp_pos_v <= 1'b0;
                cp_pop_p <= 1'b0; cp_cap_p <= 1'b0; cp_pop_disc <= 1'b0;
                cp_w_v <= 1'b0; cp_dvld <= 1'b0;
            end else if (cp_on) begin
                // ================= cp 服务（RD2 分时；band 链静止）=================
                if (cp_ld) begin
                    // CP_LOAD：LOAD 保持（冻结全部新通道调度）+ 弹空残留/在途。
                    // 硅片上 LOAD 连清 FIFO（弹空为无操作）、仿真 shim 不连
                    // （弹空真实排空）——两种实现都收敛到"空且无在途"。
                    rd2_load <= 1'b1;
                    if (!rd2_empty)
                        rd2_re <= 1'b1;
                    if (rd2_empty && !rd2_bmask1) begin
                        // ★ 64 字对齐下取整（YX6 根因修复）：full-page 突发在行
                        //   边界（256 字=4×64）内回绕，vendor 线性步进 +64 的突发
                        //   一旦跨行（起始列 >192），尾段 15 字会返回本行头——
                        //   实测 S5 会话（LOAD@57743 未对齐）交付 1585 字错位、
                        //   igold/golden 全线 FAIL。64 对齐 ⇒ 突发恒不跨行；
                        //   cp_pos 同步对齐，首段 ≤63 字走 discard 逻辑追平。
                        //   （band/reload 路径的 LOAD 基址天然 64 对齐：320=5×64。）
                        rd2_addr  <= {cp_addr[16:6], 6'd0};
                        cp_pos    <= {cp_addr[16:6], 6'd0};
                        cp_pos_v  <= 1'b1;
                        cp_pop_p  <= 1'b0; cp_cap_p <= 1'b0;
                        cp_ld     <= 1'b0;        // 次拍 LOAD 释放 → CP_RUN
                    end
                end else begin
                    // CP_RUN：续传/交付（LOAD 已释放，控制器按调度连续过读；
                    // pop 只在 merge 真在等（cp_req）时发，merge 停滞期 FIFO
                    // 自然被过读填满 = cp 的后续字，恢复后续传零重读）
                    if (cp_req && cp_quiet && !rd2_empty && (cp_pos <= cp_addr)) begin
                        rd2_re      <= 1'b1;
                        cp_pop_p    <= 1'b1;
                        cp_pop_disc <= (cp_pos < cp_addr);  // 补丁跳过的源字：丢弃追平
                        cp_w_a      <= cp_addr;             // 交付字地址（丢弃时不用）
                        cp_pos      <= cp_pos + 21'd1;
                    end
                    if (cp_pop_p) begin
                        cp_pop_p <= 1'b0;
                        cp_cap_p <= 1'b1;
                    end else if (cp_cap_p) begin
                        cp_cap_p <= 1'b0;
                        if (!cp_pop_disc) begin
                            cp_w_d <= rd2_fifo_dat[15:0];
                            cp_w_v <= 1'b1;
                        end
                    end else if (cp_w_v) begin
                        if (cp_dvld) begin
                            cp_dvld <= 1'b0;      // 报价满 1 拍（merge 已在 CP_RD 采样）
                            cp_w_v  <= 1'b0;
                        end else if (cp_w_a == cp_addr) begin
                            cp_dvld <= 1'b1;      // merge 在等且正是本字 → 报价
                        end else begin
                            cp_w_v <= 1'b0;       // merge 补丁越过本字（防御）→ 丢弃重同步
                        end
                    end
                end
            end else if (hold) begin
                if (!drain) begin
                    // WAIT：等目标窗完整落 SDRAM（带边界 mini-reload 时 ok_now 恒
                    // 真，立即转 FLUSH）。
                    // ★ v5b：不在此窗服务 cp——SWAP(N) 以 merge(N) 完成为前提
                    //   （DRAIN 要求 cp_i==NB），故 reload 的 ok_now 只可能滞后
                    //   末突发落 SDRAM 的 ~150 拍，纯轮询即可，不可能死锁；
                    //   实测（YX6）此窗服务只会产生 1 次无交付 LOAD + 立即 kill，
                    //   纯属浪费。
                    if (ok_now)
                        drain <= 1'b1;    // 转 FLUSH
                end else begin
                    // FLUSH：冻结所有新通道调度（LOAD 保持），弹空超读前缀/越界垃圾
                    rd2_load <= 1'b1;     // 保持 LOAD：锁存新地址+抑制新调度
                    if (!rd2_empty)
                        rd2_re <= 1'b1;   // 持续弹空
                    if (rd2_empty && !rd2_bmask1) begin
                        drain    <= 1'b0;
                        hold     <= 1'b0;
                        rd2_load <= 1'b1; // 末拍 LOAD（次拍撤；rRD2_ADDR 已连续锁存）
                    end
                end
            end else begin
                // ---- 捕获（pop 次拍 do 已更新）----
                if (cap) begin
                    out_d  <= rd2_fifo_dat[15:0];
                    rd_data<= rd2_fifo_dat[15:0];
                    out_v  <= 1'b1;
                    cap    <= 1'b0;
                end
                // ---- 消费清零（band 在 dvld=1 沿取走；rd_req 此拍为 0）----
                //      ★ 带边界在此拍判定：最后一字已交付 band（下一拍带可收完）
                else if (out_v) begin
                    out_v <= 1'b0;
                    if (wcnt == BPW[8:0]-9'd1) begin
                        wcnt <= 9'd0;
                        if (bidx != BW[8:0]-9'd1) begin
                            // 窗内带边界：mini-reload（LOAD 新带首地址）
                            bidx     <= bidx + 9'd1;
                            rd2_addr <= need_base + (bidx + 9'd1)*BPW;
                            rd2_load <= 1'b1;
                            hold     <= 1'b1;
                            drain    <= 1'b0;
                        end else begin
                            // ★ v5：末带末字交付 → 帧尾空闲（cp 服务窗开启）
                            frame_done_f <= 1'b1;
                        end
                        // 带尾（bidx==BW-1）不 LOAD：等帧切换 reload
                    end else wcnt <= wcnt + 9'd1;
                end
                // ---- pop 次拍：进入捕获（do 已更新）----
                else if (rd2_re) begin
                    cap <= 1'b1;
                end
                // ---- 发起 pop（band 在等且无在途字；LOAD 撤后首拍 load_r 保护）----
                else if (!load_r && rd_req && !rd2_empty) begin
                    rd2_re <= 1'b1;
                end
                // ---- v5：帧尾空闲 → cp 服务窗（case-b/pend 合并的全速完成点；
                //      band 无未决请求才进入，reload 到来即抢占）----
                else if (frame_done_f && !rd_req && cp_req && cp_quiet) begin
                    cp_on <= 1'b1;
                    cp_ld <= !cp_stream_ok;
                end
            end
        end
    end
endmodule
