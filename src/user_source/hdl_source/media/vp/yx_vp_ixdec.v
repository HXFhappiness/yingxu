// yx_vp_ixdec.v — YX-VP 索引解码器（方案 A：发射 (块号,索引) 补丁字，不展开像素）
//
// ★ 板 B 专用模块。S2-A1 阶段与 yx_vp_ixbuf.v 配对仿真验收。
//
// 输入 YXV2 帧载荷（5B 帧头 + KEY 全帧索引 | bitmap + 变化索引），
// 输出补丁字流：每个要写的块一个 (blk, idx) 字，经 16 深 skid FIFO 进索引缓冲管理器。
//
// 相比像素版解码核（yx_vp_vq.v）的简化：无码本查表流水、无 16 像素展开、
// 无块内连发 —— 每变化块 1 个补丁字。
//
// ★ 时序要点：
//   FSM 的发射决策（edge k 设 fsm_we）与 skid 实际推送（edge k+1）相隔一拍，
//   余量检查按 cnt<=14（深度 16）预留 2 槽偏斜，任何节奏不溢出。
//   DELTA 走查在 skid 无空位时原地等待（不吞字节），位置寄存器保持。
module yx_vp_ixdec #(
    parameter W      = 1280,
    parameter H      = 720,
    parameter CBSIZE = 1024
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        stream_valid,
    input  wire [7:0]  stream_data,
    output wire        stream_ready,

    // 补丁字出口（valid/ready：ix_we 保持到 ix_rdy 接收）
    output wire        ix_we,
    output wire [16:0] ix_blk,
    output wire [9:0]  ix_idx,
    input  wire        ix_rdy,

    output reg         frame_done,     // 1 clk 脉冲（skid 清空后）
    output wire        frame_key,      // 本帧 KEY
    output reg  [15:0] frame_no,
    output reg         frame_started,  // 1 clk 脉冲：帧头首字节（宣布新帧）
    output wire        frame_kind      // 0=KEY 1=DELTA（frame_started 拍有效）
);
    localparam IW   = (CBSIZE > 256) ? 10 : 8;
    localparam IDXB = (CBSIZE > 256) ? 2 : 1;
    localparam BW   = W/4;
    localparam BH   = H/4;
    localparam NB   = BW*BH;
    localparam MB   = (NB + 7) / 8;

    // FSM
    localparam S_HDR0 = 4'd0, S_HDR1 = 4'd1, S_HDR2 = 4'd2, S_HDR3 = 4'd3, S_HDR4 = 4'd4,
               S_KEY  = 4'd5, S_MAP  = 4'd6, S_WALK = 4'd7, S_DIDX = 4'd8, S_FD = 4'd9;

    reg map_ram [0:131071];

    reg [3:0]  state;
    reg        kind_r;
    reg [23:0] changed_r;
    reg [16:0] blk;          // 当前块号（补丁写地址）
    reg [2:0]  bcnt;
    reg [14:0] mcnt;
    reg [7:0]  ilo;
    reg        fsm_we;       // 发射决策（可见于下一拍，skid 在下一拍推送）
    reg [16:0] em_blk;
    reg [9:0]  em_idx;

    wire want_byte = (state == S_HDR0) | (state == S_HDR1) | (state == S_HDR2) |
                     (state == S_HDR3) | (state == S_HDR4) | (state == S_KEY)  |
                     (state == S_MAP)  | (state == S_DIDX);
    // 发射态（S_KEY/S_DIDX）skid 满时不准 ready：否则生产者推进而 FSM 不消费，字节蒸发
    wire emit_state = (state == S_KEY) | (state == S_DIDX);
    assign stream_ready = want_byte & (!emit_state | q_room);
    wire get = want_byte & stream_valid;

    // ---- skid FIFO（16 深，2 的幂；项 = {blk[16:0], idx[9:0]}；输出寄存器结构）----
    // 在途总数 = q_cnt + out_v；FSM 余量检查 ≤14，决策-推送偏斜最多 +1，永不溢出（16）。
    reg [26:0] q_mem [0:15];
    reg [3:0]  q_wp, q_rp;
    reg [4:0]  q_cnt;                      // q_mem 中的字数（不含输出寄存器）
    reg        out_v;                      // 输出寄存器有效
    reg [26:0] out_d;
    wire push_ok = (q_cnt + {4'b0, out_v}) < 5'd16;
    wire q_push  = fsm_we & push_ok;
    wire q_pop   = out_v & ix_rdy;
    wire q_load  = !out_v && !q_pop && (q_cnt != 5'd0);
    wire q_room  = ((q_cnt + {4'b0, out_v}) <= 5'd14);   // FSM 余量检查（含 1 拍偏斜余量）
    wire q_empty = ((q_cnt + {4'b0, out_v}) == 5'd0);    // 全链清空

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_wp <= 4'd0; q_rp <= 4'd0; q_cnt <= 5'd0;
            out_v <= 1'b0; out_d <= 27'd0;
        end else begin
            // 出队（输出寄存器 → 下游）
            if (q_pop) begin
                out_v <= 1'b0;
                q_rp  <= q_rp + 4'd1;
            end
            // 装载输出寄存器（FIFO 非空且输出空闲；弹出同拍不装载 = 每字 1 气泡）
            if (q_load) begin
                out_v <= 1'b1;
                out_d <= q_mem[q_rp];
            end
            // 入队
            if (q_push) begin
                q_mem[q_wp] <= {em_blk, em_idx};
                q_wp <= q_wp + 4'd1;
            end
            // 计数：q_cnt 只数 q_mem 内字数；装载 -1 转入输出寄存器，弹出不再扣
            q_cnt <= q_cnt + {4'b0, q_push} - {4'b0, q_load};
        end
    end

    assign ix_we  = out_v;
    assign ix_blk = out_d[26:10];
    assign ix_idx = out_d[9:0];
    assign frame_key = ~kind_r;     // 1=KEY（kind 字节 0=KEY 1=DELTA）
    assign frame_kind = kind_r;     // ★ 此前漏驱动恒为 Z，DELTA 宣布永远失效

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_HDR0;
            kind_r     <= 1'b0;
            changed_r  <= 24'd0;
            blk        <= 17'd0;
            bcnt       <= 3'd0;
            mcnt       <= 15'd0;
            ilo        <= 8'd0;
            fsm_we     <= 1'b0;
            em_blk     <= 17'd0;
            em_idx     <= 10'd0;
            frame_done <= 1'b0;
            frame_started <= 1'b0;
            frame_no   <= 16'd0;
        end else begin
            fsm_we     <= 1'b0;
            frame_done <= 1'b0;
            frame_started <= 1'b0;

            case (state)
            S_HDR0: if (get) begin
                kind_r   <= stream_data[0];
                frame_no <= frame_no + 16'd1;    // 帧号 = 已启动帧数（1 基）
                frame_started <= 1'b1;
                state    <= S_HDR1;
            end
            S_HDR1: if (get) begin changed_r[7:0] <= stream_data;  state <= S_HDR2; end
            S_HDR2: if (get) begin changed_r[15:8] <= stream_data; state <= S_HDR3; end
            S_HDR3: if (get) begin changed_r[23:16] <= stream_data[7:0]; state <= S_HDR4; end
            S_HDR4: if (get) begin
                blk  <= 17'd0;
                bcnt <= 3'd0;
                mcnt <= 15'd0;
                state <= kind_r ? S_MAP : S_KEY;
            end

            // ---- KEY：全帧索引，每块一个补丁字 ----
            S_KEY: if (get && q_room) begin
                if (IDXB == 2) begin
                    if (bcnt == 3'd0) begin
                        ilo  <= stream_data;
                        bcnt <= 3'd1;
                    end else begin
                        fsm_we <= 1'b1;
                        em_blk <= blk;
                        em_idx <= {stream_data[IW-9:0], ilo};
                        bcnt   <= 3'd0;              // ★ 发射后复位字节相位（缺失时后续字节全被当高字节）
                        blk    <= blk + 17'd1;
                        state  <= (blk == NB - 1) ? S_FD : S_KEY;
                    end
                end else begin
                    fsm_we <= 1'b1;
                    em_blk <= blk;
                    em_idx <= stream_data[IW-1:0];
                    blk    <= blk + 17'd1;
                    state  <= (blk == NB - 1) ? S_FD : S_KEY;
                end
            end

            // ---- DELTA：先收 bitmap（字节内 MSB-first → 块 8m+i）----
            S_MAP: if (get) begin
                map_ram[mcnt*8 + 0] <= stream_data[7];
                map_ram[mcnt*8 + 1] <= stream_data[6];
                map_ram[mcnt*8 + 2] <= stream_data[5];
                map_ram[mcnt*8 + 3] <= stream_data[4];
                map_ram[mcnt*8 + 4] <= stream_data[3];
                map_ram[mcnt*8 + 5] <= stream_data[2];
                map_ram[mcnt*8 + 6] <= stream_data[1];
                map_ram[mcnt*8 + 7] <= stream_data[0];
                if (mcnt == MB - 1) begin
                    mcnt  <= 15'd0;
                    state <= S_WALK;
                end else
                    mcnt <= mcnt + 15'd1;
            end

            // ---- DELTA：走查位图；变化块在 skid 有空位时才取索引 ----
            S_WALK: begin
                if (map_ram[blk]) begin
                    if (q_room) begin
                        bcnt  <= 3'd0;
                        state <= S_DIDX;
                    end
                    // 无空位：原地等（不吞字节）
                end else begin
                    if (blk == NB - 1) begin
                        state <= S_FD;
                    end else
                        blk <= blk + 17'd1;
                end
            end

            S_DIDX: if (get && q_room) begin     // ★ 与 S_KEY 同：skid 满时原地等，不吞字节
                if (IDXB == 2) begin
                    if (bcnt == 3'd0) begin
                        ilo  <= stream_data;
                        bcnt <= 3'd1;
                    end else begin
                        fsm_we <= 1'b1;
                        em_blk <= blk;
                        em_idx <= {stream_data[IW-9:0], ilo};
                        bcnt   <= 3'd0;              // ★ 同 S_KEY：发射后复位字节相位
                        blk    <= blk + 17'd1;
                        state  <= (blk == NB - 1) ? S_FD : S_WALK;
                    end
                end else begin
                    fsm_we <= 1'b1;
                    em_blk <= blk;
                    em_idx <= stream_data[IW-1:0];
                    blk    <= blk + 17'd1;
                    state  <= (blk == NB - 1) ? S_FD : S_WALK;
                end
            end

            // ---- 冲刷：skid 清空才宣布帧完成（保证补丁全部进入 ixbuf）----
            S_FD: begin
                if (q_empty && !fsm_we) begin
                    frame_done <= 1'b1;
                    state      <= S_HDR0;
                end
            end
            default: state <= S_HDR0;
            endcase
        end
    end
endmodule
