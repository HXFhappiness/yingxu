// yx_vp_vq.v — YX-VP-VQ v1 视频解码核（YXVQ v2 格式：KEY/DELTA 差分帧）
//
// ★ 板 B（GS）专用模块：独立文件，不进 A 板顶层/构建列表。S1 阶段仅仿真对拍。
//
// 输入：字节流（byte_pending 单字节握手，来自 SD 快速引擎）
// 输出：像素写口（光栅线性地址 pix_addr + RGB565 pix_data）+ 帧完成脉冲
//
// 帧载荷（跟在 20B 文件头 + codebook 之后）：
//   帧头 5B: kind u8 | changed u24 LE | rsv u8     kind: 0=KEY 1=DELTA
//   KEY   : NB*IDXB 字节索引（光栅块序）
//   DELTA : MB 字节 bitmap（bit b=块 b 变化，字节内 MSB-first）+ changed*IDXB 索引
//
// 时序：查表流水 1.125 clk/像素（S_PRE 1 + S_RUN 17 = 18 clk/块）
//   KEY 帧 720p  = 57600*18 = 1.04M clk  < 3.06M（73.33MHz/24fps 帧预算）✓
//   KEY 帧 1080p = 129600*18 = 2.33M clk < 3.06M ✓
module yx_vp_vq #(
    parameter W      = 1280,
    parameter H      = 720,
    parameter CBSIZE = 1024,        // 256 或 1024
    parameter MAP_MAX = 131072      // 位图容量上限（覆盖 1080p NB=129600）
)(
    input  wire        clk,
    input  wire        rst_n,

    // 字节流入口（单字节握手；ready=0 时上游暂停于字节边界）
    input  wire        stream_valid,
    input  wire [7:0]  stream_data,
    output wire        stream_ready,

    // 像素帧缓冲写口（光栅线性地址）
    input  wire        pix_rdy,      // 下游（缓冲管理器）背压：0=暂停发射，状态全保持
    output wire        pix_we,
    output wire [21:0] pix_addr,
    output wire [15:0] pix_data,

    // 帧事件
    output reg         frame_done,   // 1 clk 脉冲，帧解码完成
    output wire        frame_key,    // 本帧是否 KEY（frame_done 当拍有效）
    output reg  [15:0] frame_no
);
    localparam IDXB = (CBSIZE > 256) ? 2 : 1;         // 每索引字节数
    localparam IW   = (CBSIZE > 256) ? 10 : 8;        // 索引位宽
    localparam BW   = W/4;
    localparam BH   = H/4;
    localparam NB   = BW*BH;                          // 总块数
    localparam MB   = (NB + 7) / 8;                   // bitmap 字节数

    localparam BLKW = $clog2(MAP_MAX + 1) + 1;        // 块号位宽
    localparam BXW  = ($clog2(BW) > 0) ? $clog2(BW) : 1;
    localparam BYW  = ($clog2(BH) > 0) ? $clog2(BH) : 1;

    // FSM
    localparam S_HDR0 = 4'd0, S_HDR1 = 4'd1, S_HDR2 = 4'd2, S_HDR3 = 4'd3, S_HDR4 = 4'd4,
               S_KEY  = 4'd5, S_MAP  = 4'd6, S_WALK = 4'd7, S_DIDX = 4'd8,
               S_PRE  = 4'd9, S_RUN  = 4'd10, S_FD  = 4'd11, S_WAITROOM = 4'd12;

    reg [3:0]  state;

    reg        kind_r;
    reg [23:0] changed_r;

    reg [IW-1:0] idx_r;      // 当前索引
    reg [13:0] base_r;       // 码本基址 = idx*16
    reg [2:0]  bcnt;         // 组内字节计数（索引组装）
    reg [BLKW-1:0] blk;      // 当前块号
    reg [BXW-1:0] bx;
    reg [BYW-1:0] by;
    reg [21:0] bybase;       // by*4*W
    reg [14:0] mcnt;         // bitmap 字节计数
    reg [4:0]  p;            // 像素流水计数：0=等首读，1..15=发射中，16=发射末像素
    reg [7:0]  ilo;          // 索引低字节暂存（IDXB=2）

    reg [15:0] book [0:16*CBSIZE-1];              // 码本（仿真由 TB 加载；板上 S2 走寄存器/SDRAM 装载）
    reg [13:0] book_ra;
    reg [15:0] book_rdata;
    always @(posedge clk) book_rdata <= book[book_ra];

    reg map_ram [0:MAP_MAX-1];                    // 变化位图

    // ---- 发射缓冲（32 深 skid FIFO）：暂停粒度 = 块 ----
    // 查表流水是 2 拍配对（addr@k ↔ data@k），拍级暂停会错位一格（棋盘格坏点）。
    // 因此块内 16 像素突发绝不暂停；只在块入口（S_KEY/S_DIDX 组装索引后）检查余量：
    // cnt<=4 才进入发射，最坏 4+18=22 <= 32，任何背压节奏都不丢字、不错位。
    // ★ 深度必须 2 的幂（指针 mod 回绕），非幂深会重蹈 vbuf 24-vs-32 越界覆辙。
    // 对 vbuf 侧是标准 valid/ready：pix_we 呈现队首，pix_rdy=1 才弹出，未接收时保持。
    reg [21:0] q_a [0:31];
    reg [15:0] q_d [0:31];
    reg [4:0]  q_wp, q_rp;
    reg [4:0]  q_cnt;
    reg        fsm_we;
    reg [21:0] fsm_addr;
    reg [15:0] fsm_data;
    wire q_empty = (q_cnt == 5'd0);
    wire q_room  = (q_cnt <= 5'd4);            // 块入口余量检查：整块突发可容纳
    wire q_push  = fsm_we;                     // 块内突发期间 cnt<=22，恒可写入
    wire q_pop   = !q_empty && pix_rdy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_wp <= 5'd0; q_rp <= 5'd0; q_cnt <= 5'd0;
        end else begin
            if (q_push) q_wp <= q_wp + 1'b1;
            if (q_pop)  q_rp <= q_rp + 1'b1;
            case ({q_push, q_pop})
                2'b10:   q_cnt <= q_cnt + 5'd1;
                2'b01:   q_cnt <= q_cnt - 5'd1;
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (q_push) begin
            q_a[q_wp] <= fsm_addr;
            q_d[q_wp] <= fsm_data;
        end
    end

    assign pix_we   = !q_empty;
    assign pix_addr = q_a[q_rp];
    assign pix_data = q_d[q_rp];

    assign frame_key = kind_r;

    // 发射像素号 qe = p-2（读发起与发射相隔 2 拍：边沿 k 发起 → c(k+1) 出数 → 边沿 k+2 消费）
    wire [4:0] qe = (p >= 5'd2) ? (p - 5'd2) : 5'd0;
    wire [21:0] pix_addr_c = bybase + (qe[3:2] * W) + (bx * 4) + {2'b0, qe[1:0]};

    // 字节消费条件
    wire want_byte = (state == S_HDR0) | (state == S_HDR1) | (state == S_HDR2) |
                     (state == S_HDR3) | (state == S_HDR4) | (state == S_KEY)  |
                     (state == S_MAP)  | (state == S_DIDX);
    assign stream_ready = want_byte;
    wire get = want_byte & stream_valid;

    // 块位置推进（KEY/DELTA 共用逻辑内联展开）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_HDR0;
            kind_r     <= 1'b0;
            changed_r  <= 24'd0;
            idx_r      <= {IW{1'b0}};
            base_r     <= 14'd0;
            bcnt       <= 3'd0;
            blk        <= {BLKW{1'b0}};
            bx         <= {BXW{1'b0}};
            by         <= {BYW{1'b0}};
            bybase     <= 22'd0;
            mcnt       <= 15'd0;
            p          <= 5'd0;
            ilo        <= 8'd0;
            book_ra    <= 14'd0;
            fsm_we     <= 1'b0;
            fsm_addr   <= 22'd0;
            fsm_data   <= 16'd0;
            frame_done <= 1'b0;
            frame_no   <= 16'd0;
        end else begin
            fsm_we     <= 1'b0;          // 默认不写
            frame_done <= 1'b0;

            case (state)
            // ---- 帧头 5B：kind | changed[7:0] | changed[15:8] | changed[23:16] | rsv ----
            S_HDR0: if (get) begin
                kind_r <= stream_data[0];
                frame_no <= frame_no + 16'd1;    // 帧号在下一帧头消费时递增：frame_done 拍上仍是当前帧号
                state  <= S_HDR1;
            end
            S_HDR1: if (get) begin
                changed_r[7:0] <= stream_data;
                state <= S_HDR2;
            end
            S_HDR2: if (get) begin
                changed_r[15:8] <= stream_data;
                state <= S_HDR3;
            end
            S_HDR3: if (get) begin
                changed_r[23:16] <= stream_data[7:0];
                state <= S_HDR4;
            end
            S_HDR4: if (get) begin
                // rsv 字节忽略；按 kind_r 分发
                blk    <= {BLKW{1'b0}};
                bx     <= {BXW{1'b0}};
                by     <= {BYW{1'b0}};
                bybase <= 22'd0;
                bcnt   <= 3'd0;
                mcnt   <= 15'd0;
                state  <= kind_r ? S_MAP : S_KEY;
            end

            // ---- KEY：连续 NB 个索引 ----
            S_KEY: if (get) begin
                if (IDXB == 2) begin
                    if (bcnt == 3'd0) begin
                        ilo  <= stream_data;
                        bcnt <= 3'd1;
                    end else begin
                        idx_r  <= {stream_data[IW-9:0], ilo};
                        base_r <= {stream_data[IW-9:0], ilo, 4'b0000};
                        p      <= 5'd0;
                        state  <= S_WAITROOM;    // 块入口余量检查（索引寄存器保持）
                    end
                end else begin
                    idx_r  <= stream_data[IW-1:0];
                    base_r <= {4'b0000, stream_data, 4'b0000};
                    p      <= 5'd0;
                    state  <= S_WAITROOM;
                end
            end

            // ---- 块入口余量等待：cnt<=4 才进入查表流水（索引寄存器已保持）----
            S_WAITROOM: if (q_room) state <= S_PRE;

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

            // ---- DELTA：按块号走查位图 ----
            S_WALK: begin
                if (map_ram[blk]) begin
                    bcnt  <= 3'd0;
                    state <= S_DIDX;         // 变化块：取下一个索引
                end else begin
                    // 未变化：不收流，推进块号
                    if (bx == BW-1) begin
                        bx     <= {BXW{1'b0}};
                        by     <= by + 1'b1;
                        bybase <= bybase + (4*W);
                    end else
                        bx <= bx + 1'b1;
                    if (blk == NB-1) begin
                        state      <= S_FD;           // 帧完成改由 S_FD 冲刷后统一宣布
                    end else
                        blk <= blk + 1'b1;
                end
            end

            S_DIDX: if (get) begin
                if (IDXB == 2) begin
                    if (bcnt == 3'd0) begin
                        ilo  <= stream_data;
                        bcnt <= 3'd1;
                    end else begin
                        idx_r  <= {stream_data[IW-9:0], ilo};
                        base_r <= {stream_data[IW-9:0], ilo, 4'b0000};
                        p      <= 5'd0;
                        state  <= S_WAITROOM;
                    end
                end else begin
                    idx_r  <= stream_data[IW-1:0];
                    base_r <= {4'b0000, stream_data, 4'b0000};
                    p      <= 5'd0;
                    state  <= S_WAITROOM;
                end
            end

            // ---- 查表流水：S_PRE 发首读；S_RUN 内 p=1..15 连发读请求，
            //      p>=2 起每拍发射一个像素（滞后 2 拍），p=17 发射像素 15 并收块 ----
            S_PRE: begin
                book_ra <= base_r;       // 像素 0 的读
                p       <= 5'd0;
                state   <= S_RUN;
            end
            S_RUN: begin
                // 块内突发绝不暂停：查表流水 2 拍配对，拍级暂停会错位一格
                if (p >= 5'd2) begin
                    fsm_we   <= 1'b1;
                    fsm_addr <= pix_addr_c;          // qe = p-2
                    fsm_data <= book_rdata;
                end
                if (p <= 5'd15) begin
                    book_ra <= base_r + {9'b0, p};   // 像素 p 的读
                    p       <= p + 5'd1;
                end else if (p == 5'd16) begin
                    p <= 5'd17;                      // 等像素 15 的 rdata，推到收块拍
                end else begin
                    // 本拍已发射像素 15，块完成
                    if (kind_r == 1'b0) begin
                        // KEY：推进块号/位置
                        if (bx == BW-1) begin
                            bx     <= {BXW{1'b0}};
                            by     <= by + 1'b1;
                            bybase <= bybase + (4*W);
                        end else
                            bx <= bx + 1'b1;
                        if (blk == NB-1) begin
                            state      <= S_FD;       // 帧完成改由 S_FD 冲刷后统一宣布
                        end else begin
                            blk   <= blk + 1'b1;
                            bcnt  <= 3'd0;
                            state <= S_KEY;
                        end
                    end else begin
                        // DELTA：收块后推进块号/位置并查帧尾（与 KEY 一致）
                        if (bx == BW-1) begin
                            bx     <= {BXW{1'b0}};
                            by     <= by + 1'b1;
                            bybase <= bybase + (4*W);
                        end else
                            bx <= bx + 1'b1;
                        if (blk == NB-1) begin
                            state      <= S_FD;       // 帧完成改由 S_FD 冲刷后统一宣布
                        end else begin
                            blk   <= blk + 1'b1;
                            state <= S_WALK;         // 回走查（ blk 已推进，不会重看当前块）
                        end
                    end
                end
                // p == 16：等待像素 15 的 rdata（只发射不发起）
            end

            S_FD: begin
                // 冲刷：等发射 FIFO 清空才宣布帧完成（保证 frame_done 拍上末像素已入 vbuf FIFO）
                if (q_empty) begin
                    frame_done <= 1'b1;
                    state      <= S_HDR0;
                end
            end
            default: state <= S_HDR0;
            endcase
        end
    end
endmodule
