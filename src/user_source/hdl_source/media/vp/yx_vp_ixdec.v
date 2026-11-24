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
               S_KEY  = 4'd5, S_MAP  = 4'd6, S_WALK = 4'd7, S_DIDX = 4'd8, S_FD = 4'd9,
               S_WALKR = 4'd10;

    // ★★ P2b：改变块位图从 LUT 分布式 RAM 改成厂商 32Kb BRAM 原语。
    //   为什么必须改：map_ram 是 57,600×1bit，原来是 **组合读**（`if (map_ram[blk])`
    //   同拍决策），TD 只能建在 LUT 里，综合后 `u_ixdec` 8,249 LUT 且成为全设计
    //   唯一时序违例族：`rem_reg → map_ram_syn_*.e[0]` −1,031 ps（1,033 条端点）。
    //   BRAM 读必然 1 拍延迟，故把走查拆成"读 / 决策"两拍（S_WALKR → S_WALK）：
    //   blk 在两拍内不变 → dob 天然对应 blk；且 q_room 不足停顿拍地址也不变，
    //   数据保持稳定，无需额外的命中锁存。代价：走查 2 拍/块，
    //   57600 块 = 115,200 拍 ≈ 1.15 ms/帧（DELTA 帧），帧预算 33 ms 下可忽略。
    //   位图打包成 8 bit/字（每字 8 个块，块 8m+i ↔ 字节 m 的 bit(7-i)），
    //   7200 字 → 8192×8 深度 → 2 块 32Kb（bram32k 尚余 8 块）。
    //   ★ 例化放在下面寄存器声明之后（wire 引用 state/blk/mcnt）。

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
    wire q_room;                           // skid 余量（赋值见下方 skid FIFO 处）
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
    assign q_room = ((q_cnt + {4'b0, out_v}) <= 5'd14);   // FSM 余量检查（含 1 拍偏斜余量）
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

    // ---- P2b：改变块位图（8 bit/字 × 8192 → 厂商 32Kb 原语，2 块）----
    // 写：S_MAP 每字节直写（块 8m+i ↔ 字节 m 的 bit(7-i)）
    // 读：B 口同步读，1 拍延迟 → S_WALKR 呈现地址、S_WALK 用数据决策
    wire [7:0]  map_dob;
    wire        map_we   = (state == S_MAP) && stream_valid;   // S_MAP 下 get == stream_valid
    wire [12:0] map_a    = blk[15:3];                // 块 → 字节地址（7200 < 8192）
    wire        map_bite = map_dob[~blk[2:0]];       // 块在字节内的位（MSB-first）
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A (8),
        .DATA_WIDTH_B (8),
        .ADDR_WIDTH_A (13),
        .ADDR_WIDTH_B (13),
        .BYTE_ENABLE  (0),
        .MODE         ("DP"),
        .REGMODE_A    ("NOREG"),
        .REGMODE_B    ("NOREG"),
        .WRITEMODE_A  ("NORMAL"),
        .WRITEMODE_B  ("NORMAL"),
        .RESETMODE    ("ASYNC"),
        .INIT_FILE    ("NONE"),
        .FILL_ALL     ("NONE"),
        .IMPLEMENT    ("32K")
    ) u_map (
        .dia (stream_data), .addra (mcnt[12:0]), .cea (1'b1), .wea (map_we),
        .clka(clk),         .rsta  (1'b0),       .bea (1'b1),
        .dib (8'd0),        .addrb (map_a),      .ceb (1'b1), .oceb(1'b1),
        .clkb(clk),         .web   (1'b0),       .rstb(1'b0), .beb (1'b1),
        .doa (),            .dob   (map_dob)
    );
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

            // ---- DELTA：先收 bitmap（字节内 MSB-first → 块 8m+i ↔ bit(7-i)）----
            // 直接按字节写入 u_map（bit(7-i) 的打包规则由 map_ram 的读侧还原）
            S_MAP: if (get) begin
                if (mcnt == MB - 1) begin
                    mcnt  <= 15'd0;
                    state <= S_WALKR;        // ★ 先过"读"拍（BRAM 1 拍延迟）
                end else
                    mcnt <= mcnt + 15'd1;
            end

            // ---- DELTA：读拍（blk 保持不变，让 u_map 的 dob 对应 blk）----
            S_WALKR: state <= S_WALK;

            // ---- DELTA：决策拍（此时 map_bite 对应 blk）；变化块在 skid 有空位时才取索引 ----
            S_WALK: begin
                if (map_bite) begin
                    if (q_room) begin
                        bcnt  <= 3'd0;
                        state <= S_DIDX;
                    end
                    // 无空位：原地等（不吞字节）。blk 不变 → dob 保持 → 决策不变
                end else begin
                    if (blk == NB - 1) begin
                        state <= S_FD;
                    end else begin
                        blk   <= blk + 17'd1;
                        state <= S_WALKR;        // ★ 回到读拍
                    end
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
                        state  <= (blk == NB - 1) ? S_FD : S_WALKR;
                    end
                end else begin
                    fsm_we <= 1'b1;
                    em_blk <= blk;
                    em_idx <= stream_data[IW-1:0];
                    blk    <= blk + 17'd1;
                    state  <= (blk == NB - 1) ? S_FD : S_WALKR;
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
