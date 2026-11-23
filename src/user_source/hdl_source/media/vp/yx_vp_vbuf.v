// yx_vp_vbuf.v — YX-VP 三缓冲帧槽管理器（板 B / GS）
//
// ★ 板 B 专用模块：独立文件，不进 A 板顶层/构建列表。
//
// 职责：
//   1. 三个 SDRAM 帧槽状态流转：FREE → DEC(解码中) → READY → ACTIVE → FREE
//   2. 解码器像素流经写 FIFO 送 SDRAM；背压 pix_rdy 反馈解码器暂停发射
//      （KEY 帧全速发射 1 px/clk，超过 SDRAM 剩余带宽的部分被 FIFO+反压自动摊平）
//   3. frame_done 后等 FIFO 排空才标 READY —— 显示端永远不会读到半帧
//   4. vblank 时显示端取「最旧 READY」（视频语义：逐帧呈现不跳帧）
//   5. 空 DELTA 帧（changed=0）：无像素写入，不做任何槽操作，仅推进帧号
//
// 槽守恒：无 ACTIVE 时 3 槽可同时 READY（就绪队列深度 3）；首个显示帧换入后
// 恒为 1 ACTIVE + ≤2 READY + 其余 FREE/DEC，队列深度 3 覆盖全部情况。
module yx_vp_vbuf #(
    parameter W       = 1280,
    parameter H       = 720,
    parameter AW      = 22,             // SDRAM 字地址位宽（1080p×3 槽需 23）
    parameter BASE    = 0,              // 槽区基址（字地址）
    parameter FDEPTH  = 1024            // 写 FIFO 深度
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 解码器侧 ----
    input  wire        pix_we,
    input  wire [21:0] pix_addr,         // 帧内光栅线性地址
    input  wire [15:0] pix_data,
    input  wire        frame_done,       // 1 clk 脉冲，与末像素 pix_we 同拍
    input  wire [15:0] dec_frame_no,     // 解码器当前帧号（frame_done 拍有效）
    output wire        pix_rdy,

    // ---- SDRAM 写口（下游节流，wr_gnt=1 表示本拍接收）----
    output wire        wr_valid,
    output reg  [AW-1:0] wr_addr,
    output reg  [15:0] wr_data,
    input  wire        wr_gnt,

    // ---- 显示侧 ----
    input  wire        vblank,           // 1 clk 脉冲，每扫描帧一次
    output reg  [1:0]  act_slot,         // 当前显示槽
    output wire        act_valid,        // 首帧换入前为 0
    output reg  [15:0] act_fno,          // 当前显示的帧号
    output wire [AW-1:0] act_base,       // 当前显示槽基址（扫描地址生成用）

    // ---- 观测 ----
    output wire [5:0]  slot_sts,         // {st2,st1,st0}：0=FREE 1=DEC 2=READY 3=ACTIVE
    output wire [11:0] fifo_lvl
);
    localparam SLOT_STRIDE = W * H;
    localparam ST_FREE = 2'd0, ST_DEC = 2'd1, ST_READY = 2'd2, ST_ACTIVE = 2'd3;

    // ---- 槽状态 ----
    reg [1:0]  st [0:2];
    reg        dec_on;                    // 正在向某槽写一帧
    reg [1:0]  dec_slot;
    reg        pend_rdy;                  // frame_done 已见，等 FIFO 排空后标 READY
    reg [15:0] pend_fno;

    // ---- READY 队列（深度 3，先进先出=按帧序显示）----
    reg [1:0]  rq_slot [0:2];
    reg [15:0] rq_fno  [0:2];
    reg [2:0]  rq_cnt;

    // ---- 写 FIFO（同步读写，无组合阵列读）----
    reg [AW+15:0] fmem [0:FDEPTH-1];
    localparam FW = $clog2(FDEPTH);      // 指针位宽必须匹配深度（mod FDEPTH 回绕）
    reg [FW-1:0] wp, rp;
    reg [11:0] lvl;
    reg pres_vld;                        // 呈现-接收两段式：当前有一个字待下游接收
    wire fpush = pix_we & pix_rdy;
    wire fpop  = pres_vld & wr_gnt;      // 接收条件：有真实呈现且下游本拍接收
    assign fifo_lvl = lvl;
    assign wr_valid = pres_vld;

    // ---- 路由槽：写帧中用 dec_slot，否则取首个空闲槽 ----
    wire f0 = (st[0] == ST_FREE), f1 = (st[1] == ST_FREE), f2 = (st[2] == ST_FREE);
    wire [1:0] new_slot = f0 ? 2'd0 : (f1 ? 2'd1 : 2'd2);
    wire [1:0] route_slot = dec_on ? dec_slot : new_slot;
    wire free_exists = f0 | f1 | f2;

    function [AW-1:0] sbase;
        input [1:0] s;
        begin
            case (s)
                2'd0:    sbase = BASE;
                2'd1:    sbase = BASE + SLOT_STRIDE;
                default: sbase = BASE + 2*SLOT_STRIDE;
            endcase
        end
    endfunction

    assign act_valid = (st[act_slot] == ST_ACTIVE);
    assign act_base  = sbase(act_slot);
    assign slot_sts  = {st[2], st[1], st[0]};

    assign pix_rdy = !pend_rdy && (lvl < FDEPTH - 64) && (dec_on || free_exists);

    // 就绪队列事件（同拍碰撞安全：弹出与入队可同拍发生）
    wire vpop  = vblank && (rq_cnt != 3'd0);
    wire rmark = pend_rdy && (lvl == 12'd0) && dec_on;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st[0] <= ST_FREE; st[1] <= ST_FREE; st[2] <= ST_FREE;
            dec_on <= 1'b0; dec_slot <= 2'd0; pend_rdy <= 1'b0; pend_fno <= 16'd0;
            rq_slot[0] <= 2'd0; rq_slot[1] <= 2'd0; rq_slot[2] <= 2'd0;
            rq_fno[0] <= 16'd0; rq_fno[1] <= 16'd0; rq_fno[2] <= 16'd0;
            rq_cnt <= 3'd0;
            wp <= {FW{1'b0}}; rp <= {FW{1'b0}}; lvl <= 12'd0;
            pres_vld <= 1'b0;
            wr_addr <= {AW{1'b0}}; wr_data <= 16'd0;
            act_slot <= 2'd0; act_fno <= 16'd0;
        end else begin

            // ---- vblank：显示端取最旧就绪帧 ----
            if (vpop) begin
                if (st[act_slot] == ST_ACTIVE)
                    st[act_slot] <= ST_FREE;             // 旧显示槽归还
                act_slot <= rq_slot[0];
                act_fno  <= rq_fno[0];
                st[rq_slot[0]] <= ST_ACTIVE;
                if (rq_cnt == 3'd2) begin                // 弹出后队列前移（仅实际有后续元素时）
                    rq_slot[0] <= rq_slot[1];
                    rq_fno[0]  <= rq_fno[1];
                end else if (rq_cnt == 3'd3) begin
                    rq_slot[0] <= rq_slot[1];
                    rq_fno[0]  <= rq_fno[1];
                    rq_slot[1] <= rq_slot[2];
                    rq_fno[1]  <= rq_fno[2];
                end
            end
            // 无就绪帧：保持当前显示槽（重复上一帧）

            // ---- 帧完成捕获 ----
            // dec_frame_no = 已启动帧数（1 基）；归一为 0 基帧号
            if (frame_done) begin
                pend_rdy <= 1'b1;
                pend_fno <= dec_frame_no - 16'd1;
            end

            // ---- FIFO 排空后标 READY（空帧跳过槽操作）----
            // 冲刷设计保证 frame_done 时本帧像素已全部入队；此处 pix_we 若为 1，
            // 是下一帧首像素被背压扣住（未入队），与本帧无关，不阻塞标记。
            if (pend_rdy && lvl == 12'd0) begin
                if (dec_on) begin
                    st[dec_slot] <= ST_READY;
                    case (rq_cnt - {2'b0, vpop})         // 入队位置 = 弹出修正后的队尾
                        3'd0: begin rq_slot[0] <= dec_slot; rq_fno[0] <= pend_fno; end
                        3'd1: begin rq_slot[1] <= dec_slot; rq_fno[1] <= pend_fno; end
                        default: begin rq_slot[2] <= dec_slot; rq_fno[2] <= pend_fno; end
                    endcase
                end
                dec_on   <= 1'b0;
                pend_rdy <= 1'b0;
            end
            // 队列计数：单点赋值，弹出/入队同拍时算术合并
            rq_cnt <= rq_cnt + {2'b0, rmark} - {2'b0, vpop};

            // ---- 写 FIFO 入队（首像素同时分配槽）----
            if (fpush) begin
                fmem[wp] <= {sbase(route_slot) + pix_addr, pix_data};
                wp <= wp + 1'b1;
                if (!dec_on) begin
                    dec_on   <= 1'b1;
                    dec_slot <= new_slot;
                    st[new_slot] <= ST_DEC;
                end
            end

            // ---- FIFO 排空到 SDRAM（呈现-接收两段式，杜绝陈旧/重复呈现）----
            // fpop：本拍下游接收了呈现中的字 → rp 前移、呈现位清零
            // 装载：空闲且 lvl>0 → 装入 fmem[rp] 呈现（每字 1 气泡，足够 S2 带宽）
            if (fpop)
                pres_vld <= 1'b0;
            else if (!pres_vld && lvl != 12'd0) begin
                pres_vld <= 1'b1;
                wr_addr  <= fmem[rp][AW+15:16];
                wr_data  <= fmem[rp][15:0];
            end
            if (fpop)
                rp <= rp + 1'b1;

            // ---- FIFO 记账 ----
            case ({fpush, fpop})
                2'b10:   lvl <= lvl + 12'd1;
                2'b01:   lvl <= lvl - 12'd1;
                default: ;
            endcase
        end
    end
endmodule
