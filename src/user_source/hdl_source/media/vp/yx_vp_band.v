// yx_vp_band.v — YX-VP 条带渲染器（方案 A 显示端：索引缓冲 → 码本查表 → 行缓冲）
//
// ★ 板 B 专用模块。与 yx_vp_ixbuf.v（索引缓冲）配对。
//
// 每带（4 像素行）从 active 索引缓冲顺序取 BW 个索引字，逐块查码本（BRAM）
// 写入 8 行行缓冲（2 带 ping-pong，每带 4 行）。带完成 → band_done 脉冲
// （band_no = 完成带号）；扫描端比对/消费后回 band_ack。
//
// ★ 握手深度 2（欠扫描治理）：完成未 ack 的带最多挂 2 个（pend_cnt），渲染侧
//   不再逐带停等——扫描端消费第 N 带的同时渲染器已在画第 N+1 带；仅当扫描端
//   落后满 2 带（pend_cnt==2）才暂停。正确性依据：带 b 的写半区 = ping-pong
//   (b[0])，2 带之前的带必已 ack（同半区释放），行缓冲永不读写冲突。
//   帧边界：最后一带完成后 frame_wait 暂停渲染，其 ack 到达才回 frame_done
//   并接挂起帧/回 IDLE（帧号语义与深度 1 版本一致）。
//
// ★ 扫描读端口：scan_ra（行缓冲 14 位地址 {半区,行,列}）→ 下一拍 scan_rd 出数。
//   渲染写与扫描读分属不同半区，真双口 BRAM 映射（仿真 reg 数组双读）。
//
// 帧节拍：swap_done（新帧提交）后开始渲染 frame=commit_no；整帧渲染完回 IDLE
// 等下一帧（行缓冲保持内容，扫描端可继续重复显示）。渲染中到来的 swap_done
// 锁存为挂起帧（不跳帧），当前帧收尾后立即接上。frame_done 脉冲上报。
//
// 码本：16*CBSIZE 个 RGB565 字，仿真由 TB $readmemh 装载，板上初始化于 BRAM。
module yx_vp_band #(
    parameter W      = 1280,
    parameter H      = 720,
    parameter CBSIZE = 1024,
    parameter AW     = 17                // 索引缓冲字地址位宽
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 帧提交（来自 ixbuf）----
    input  wire        swap_done,
    input  wire [15:0] commit_no,
    input  wire [AW-1:0] act_base,

    // ---- SDRAM 读口（索引取带）----
    output wire        rd_req,          // 电平式：等待期保持，dvld 撤销（刷新窗口不丢请求）
    output reg  [AW-1:0] rd_addr,
    input  wire        rd_dvld,
    input  wire [15:0] rd_data,

    // ---- 扫描读端口（行缓冲 → SDRAM 扫描入帧 / TB 比对）----
    input  wire [13:0] scan_ra,         // {band_half, row[1:0], col[9:0]}
    output wire [15:0] scan_rd,         // ★ 组合读（仿真验收版）
    input  wire [13:0] scan_rb,         // 第二读口：偶/奇像素同拍读出（打包 32bit 字）
    output wire [15:0] scan_rd_b,       // 板上实现：ln 双副本 BRAM（渲染写×2/扫描读×2）
    input  wire        book_we,         // ★ 码本写口（板上头解析装载；仿真绑 0）
    input  wire [13:0] book_wa,
    input  wire [15:0] book_wd,

    // ---- 扫描端握手 ----
    output reg         band_done,       // 1 clk 脉冲：带 band_no 已渲染
    output reg  [15:0] render_no,       // 当前渲染帧号（0 基）
    output reg  [8:0]  band_no,         // band_done 拍上的完成带号
    input  wire        band_ack,        // 扫描端已消费该带（比对/显示完）
    output reg         frame_done,      // 1 clk 脉冲：整帧渲染完成（= render_ack）
    output reg         frame_start      // ★ 1 clk 脉冲：渲染器启动新帧（IDLE 直进/
                                       //   接挂起帧拍；此拍 base_l 已锁存新窗基址，
                                       //   取带器 reload 依此触发——旧 frame_done 拍
                                       //   base_l 还是旧窗，取带会读旧窗数据撕裂）
);
    localparam BW = W/4;
    localparam BH = H/4;

    // ---- 码本（同步读 BRAM；外加写口供板上头解析装载）----
    reg [15:0] book [0:16*CBSIZE-1];
    reg [13:0] book_ra;
    reg [15:0] book_rdata;
    always @(posedge clk) book_rdata <= book[book_ra];
    // 板上初始化：头解析器经此写口灌码本（仿真 TB 用 $readmemh，两路并存安全：
    // 解析装载发生在渲染开始前）
    always @(posedge clk) if (book_we) book[book_wa] <= book_wd;

    // ---- 行缓冲（8 行 × W 像素；2 带 ping-pong）----
    reg [15:0] ln [0:8*W-1];
    // 扫描读口（与渲染写分属不同半区，双口安全；双口为打包 32bit 字服务）
    // ★ 组合读（仿真验收版）：推数拍本拍地址本拍数据，full 停推时地址冻结
    //   无重复无丢失。板上 BRAM 为同步读，需推数拍对齐流水（P3/P5 适配）。
    //   reg 数组组合索引在仿真中行为正确，不产生 X。
    assign scan_rd   = ln[scan_ra];
    assign scan_rd_b = ln[scan_rb];

    // ---- 状态 ----
    reg [1:0]  st;                       // 0=IDLE 1=FETCH 2=BOOK 3=WRITE
    reg [AW-1:0] base_l;                 // 本帧索引基址（帧启动时锁存）
    reg [8:0]  band;                     // ★ 渲染侧带计数（完成即推进，不等 ack）
    reg [8:0]  bx;                       // 带内块计数
    reg [9:0]  cur_idx;                  // 当前块索引
    reg [3:0]  wp;                       // 块内写计数 0..15
    reg [1:0]  fetch_r;                  // 读请求/数据等待
    reg [1:0]  pend_cnt;                 // ★ 已完成未 ack 带数（深度 2，0..2）
    reg [8:0]  ack_q0, ack_q1;           // ★ 未 ack 帧号队列（队首=q0；深度 2 下
                                         //   band_no 会被后续完成覆盖，帧尾判定必须
                                         //   用 ack 时刻弹出的队首，不能用 band_no）
    reg        frame_wait;               // ★ 帧最后一带已完成，等其 ack
    reg        pend_v;                   // 挂起帧（渲染中到来的 swap_done）
    reg [AW-1:0] pend_base;
    reg [15:0] pend_fno;

    wire [1:0] q_row = wp[3:2];          // ★ 必须显式位宽：隐式 wire 默认 1 位会丢高位
    wire [1:0] q_col = wp[1:0];
    // 行缓冲写地址：带内行 band[0]*4 + q_row，列 bx*4 + q_col（8*W ≤ 16384 → 14 位）
    wire [13:0] ln_wa = {band[0], q_row} * W + {2'b00, bx, 2'b00} + {10'b0, q_col};
    // 索引字地址：base + (band*BW + bx)
    wire [AW-1:0] ix_addr = base_l + (band * BW) + bx;
    // 电平式读请求：取带等待期保持，dvld 到达撤销（刷新窗口不丢请求）
    assign rd_req = (st == 2'd1) && fetch_r[0] && !rd_dvld;
    // ★ 渲染放行条件：帧未收尾等待 + 未 ack 带数 < 2（深度 2 背压）
    wire can_render = !frame_wait && (pend_cnt < 2'd2);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 2'd0; base_l <= {AW{1'b0}};
            render_no <= 16'hffff; band_no <= 9'd0; band <= 9'd0; bx <= 9'd0;
            cur_idx <= 10'd0; wp <= 4'd0; fetch_r <= 2'd0;
            pend_cnt <= 2'd0; frame_wait <= 1'b0;
            ack_q0 <= 9'd0; ack_q1 <= 9'd0;
            rd_addr <= {AW{1'b0}};
            band_done <= 1'b0; frame_done <= 1'b0; frame_start <= 1'b0;
            book_ra <= 14'd0;
            pend_v <= 1'b0; pend_base <= {AW{1'b0}}; pend_fno <= 16'hffff;
        end else begin
            band_done <= 1'b0;
            frame_done <= 1'b0;
            frame_start <= 1'b0;

            // ---- 新帧提交：IDLE 立即开始（受深度 2 背压门控），渲染中锁存 ----
            if (swap_done) begin
                if (st == 2'd0 && !pend_v) begin
                    base_l    <= act_base;
                    render_no <= commit_no;
                    band      <= 9'd0;
                    bx        <= 9'd0;
                    fetch_r   <= 2'd0;
                    frame_start <= 1'b1;    // ★ 首帧启动：取带器 reload 触发点
                    st        <= 2'd1;
                end else begin
                    pend_v    <= 1'b1;
                    pend_base <= act_base;
                    pend_fno  <= commit_no;
                end
            end

            case (st)
            2'd0: begin // IDLE：等新帧（含挂起帧）
                if (pend_v && !swap_done) begin
                    base_l    <= pend_base;
                    render_no <= pend_fno;
                    pend_v    <= 1'b0;
                    band      <= 9'd0;
                    bx        <= 9'd0;
                    fetch_r   <= 2'd0;
                    st        <= 2'd1;
                end
            end

            2'd1: begin // FETCH：带内逐块取索引；req 电平保持到 dvld
                if (can_render) begin
                    if (bx < BW) begin
                        if (!fetch_r[0]) begin
                            rd_addr <= ix_addr;
                            fetch_r <= 2'd1;
                        end else if (rd_dvld) begin
                            cur_idx <= rd_data[9:0];
                            fetch_r <= 2'd0;
                            book_ra <= {rd_data[9:0], 4'b0000};
                            wp      <= 4'd0;
                            st      <= 2'd2;   // BOOK：等一拍装载 book_rdata
                        end
                    end else begin
                        // 本带完成：上报完成带号，渲染侧立即推进（深度 2）
                        band_done <= 1'b1;
                        band_no   <= band;
                        if (pend_cnt == 2'd0) ack_q0 <= band;
                        else                  ack_q1 <= band;
                        pend_cnt  <= pend_cnt + 2'd1;
                        bx        <= 9'd0;
                        if (band == BH - 1) begin
                            band       <= 9'd0;
                            frame_wait <= 1'b1;   // 帧最后一带：等 ack 再收尾（保住
                                                  // 行缓冲半区不被下一帧覆盖，TB 比对依赖）
                            frame_done <= 1'b1;   // 帧完成脉冲提前到"最后一带完成"拍，
                                                  // 与 ack 解耦（ixbuf 释放时序不依赖 ack）
                        end else begin
                            band <= band + 9'd1;
                        end
                    end
                end
            end

            2'd2: begin // BOOK：本拍装载 book[{idx,0}]；地址预增一拍，使写循环每拍恰好对齐下一像素
                book_ra <= book_ra + 14'd1;
                st      <= 2'd3;
            end

            2'd3: begin // WRITE：16 像素写入行缓冲（book_ra 自动递增）
                ln[ln_wa] <= book_rdata;
                book_ra   <= book_ra + 14'd1;
                wp        <= wp + 4'd1;
                if (wp == 4'd15) begin
                    bx <= bx + 9'd1;
                    st <= 2'd1;
                end
            end
            default: st <= 2'd0;
            endcase

            // ---- 带边界推进（ack 后；带号/半区推进已在完成时做）----
            // 帧尾判定用 ack 时刻弹出的队首带号（深度 2 下 band_no 不可靠）
                if (pend_cnt != 2'd0 && band_ack) begin
                pend_cnt <= pend_cnt - 2'd1;
                if (pend_cnt == 2'd2) ack_q0 <= ack_q1;   // 队列前移（还剩 1 个未 ack）
                if (ack_q0 == BH - 1) begin
                    // 帧最后一带被消费：解除帧尾停等，接挂起帧/回 IDLE
                    frame_wait <= 1'b0;
                    if (pend_v && !swap_done) begin
                        base_l    <= pend_base;
                        render_no <= pend_fno;
                        pend_v    <= 1'b0;
                        band      <= 9'd0;
                        bx        <= 9'd0;
                        fetch_r   <= 2'd0;
                        frame_start <= 1'b1;    // ★ 接挂起帧：取带器 reload 触发点
                        st        <= 2'd1;      // 接上挂起帧
                    end else if (st == 2'd1) begin
                        st <= 2'd0;             // 回 IDLE 等下一帧
                    end
                end
            end
        end
    end
endmodule
