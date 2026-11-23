// yx_b_ix_seq_wr.v — 板 B 索引顺序写适配器 v3（128 字组突发对齐，窗完成屏障）
//
// ixbuf 写口（逐字补丁，KEY 帧按 blk 严格递增）→ 1 补丁 = 1 个 32bit SDRAM 字
// （{16'h0, idx} 低半）→ 直推 WR2 FIFO。
//
// ★ v3 组协议（根治窗尾滞留/欠载）：
//   vendor 写通道触发阈值 = FIFO 占用 ≥128（AE=127），突发长度 = WR2_LENGTH。
//   若盲推 1 字/拍，窗尾推停时 FIFO 占用随机 ∈[0,512)，必有 <128 字滞留
//   （不再触发末突发）或突发中途欠载（空读 do 重复写坏窗尾）。故改为：
//   每攒 128 字推一组（推满即停推）→ 等 mWR_DONE&WR_MASK[1]（本组突发落
//   SDRAM 完成，WR2_LENGTH=128 → 突发恰吞 128 字、FIFO 清 0、零滞留零欠载）
//   → 再推下一组。NB=57600=128×450 整除，窗尾恰在突发边界收干。
//
// ★ 窗完成屏障（region_done 按窗独立标志）：每窗第 450 组突发完成后置
//   region_done[win]=1；seq_wr 开始重写该窗（LOAD）时清除。取带器
//   （yx_b_ix_fetch）据此门控 rd_req 服务：渲染器等待取带暂停无风险
//   （码流可回压恢复），保证取带读到的索引窗已全部写入 SDRAM——旧版
//   "swap 后立即取带"导致全链 X 的根因。★ 按窗独立（而非"最近完成窗号
//   单值"）：写入领先渲染 1 窗时，单值寄存器会滚走、读侧窗的完成信息
//   丢失 → 取带器误等"该窗下次重写完成" → 死锁（实测 t=3M 卡死）。
//
// ★ 复位后首窗也发一次 LOAD（v2 仅切窗时发）：S_WAIT0 等首个补丁出现
//   （此时控制器 SDRAM INIT 早已完成），对窗 0 基址发 LOAD 后进流式——
//   旧版从不 LOAD → 控制器用复位寄存器（ADDR=0/LEN=128）写，且 LENGTH=256
//   与 NB 不再对齐。
//
// 窗口切换：屏障后等新窗首补丁（wr_valid=pf_ov 电平，gnt=0 期间 ixbuf 补丁
// FIFO 积压→ix_rdy 拉→ixdec 停，码流可恢复），对新窗基址发一次 LOAD。
// 旧 DRAIN 600 拍等待被组屏障取代（末组突发完成即窗尾排空+无在途突发）。
module yx_b_ix_seq_wr #(
    parameter AW     = 17,
    parameter NB     = 57600             // 补丁数/帧（= 每窗字数，须为 128 倍数）
)(
    input  wire        clk,
    input  wire        rst_n,
    // ---- ixbuf 写口 ----
    input  wire        wr_valid,
    input  wire [AW-1:0] wr_addr,
    input  wire [15:0] wr_data,
    output wire        wr_gnt,
    // ---- WR2 口 ----
    output reg  [31:0] wr2_data,
    output reg         wr2_en,
    output reg  [20:0] wr2_addr,
    output reg         wr2_load,
    input  wire        wr2_full,          // WR2 FIFO afull 背压（组协议下恒 0，兜底）
    input  wire        wr2_done,          // ★ WR2 突发完成事件（mWR_DONE&WR_MASK[1]，顶层给）
    output reg  [1:0]  region_done        // ★ 按窗完成标志：done[k]=窗 k 已完整落 SDRAM
                                          //   且未被重写（窗口轮转置位/清除）
);
    localparam GPN = NB/128;             // 组数/窗 = 450

    // 组协议合法性：NB 必须 128 整除（否则末组不满 → 突发欠载写坏窗尾）
    initial if (NB % 128 != 0)
        $display("yx_b_ix_seq_wr: NB=%0d 非 128 倍数，组协议失效！", NB);

    localparam S_WAIT0   = 3'd0;         // 复位后等首补丁
    localparam S_PUSH    = 3'd1;         // 组内逐字推
    localparam S_GRPDONE = 3'd2;         // 等本组突发落 SDRAM
    localparam S_REGION  = 3'd3;         // 窗完成：置 region 电平
    localparam S_WINWAIT = 3'd4;         // 等新窗首补丁

    reg [2:0]  st;
    reg        win;                      // 当前写窗
    reg        win_next;                 // 保留观测名（旧 RELOAD 中转）
    reg [15:0] drain_cnt;                 // 保留观测名（旧 DRAIN 等待已被组屏障取代）
    reg [6:0]  grp;                      // 组内位置 0..127
    reg [8:0]  grpno;                    // 窗内组号 0..GPN-1
    reg        last_grp;                 // 本组为窗末组

    wire wr_win = (wr_addr >= NB[AW-1:0]);   // 窗判定用比较（窗 1 基址 NB 非位对齐）

    // ★ gnt 含 !wr2_full：full 时撤销授权，ixbuf 停弹补丁（旧版 gnt 恒 1
    //   导致 pf 弹出后被 full 丢弃——10.4 万字丢失的直接根因）
    assign wr_gnt = (st == S_PUSH) && !wr2_full;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_WAIT0; win <= 1'b0; win_next <= 1'b0; drain_cnt <= 16'd0;
            grp <= 7'd0; grpno <= 9'd0; last_grp <= 1'b0;
            wr2_data <= 32'd0; wr2_en <= 1'b0; wr2_addr <= 21'd0; wr2_load <= 1'b0;
            region_done <= 2'b00;
        end else begin
            wr2_load <= 1'b0;
            wr2_en   <= 1'b0;
            case (st)
            S_WAIT0: begin // 首窗：等首补丁出现（控制器 INIT 早已完成），先 LOAD 再推
                if (wr_valid) begin
                    wr2_addr <= 21'd0;               // 窗 0 基址
                    wr2_load <= 1'b1;
                    grp <= 7'd0; grpno <= 9'd0; last_grp <= 1'b0;
                    st <= S_PUSH;
                end
            end
            S_PUSH: begin // 组内逐字推（1 字/拍）；推满 128 停推，等本组突发完成
                if (wr_valid && !wr2_full) begin
                    wr2_en   <= 1'b1;
                    wr2_data <= {16'h0000, wr_data};
                    if (grp == 7'd127) begin
                        grp <= 7'd0;
                        if (grpno == GPN[8:0]-9'd1) last_grp <= 1'b1;
                        else grpno <= grpno + 9'd1;
                        st <= S_GRPDONE;
                    end else grp <= grp + 7'd1;
                end
            end
            S_GRPDONE: begin // 等本组突发落 SDRAM（组协议下严格单突发在途，事件唯一）
                if (wr2_done) begin
                    if (last_grp) st <= S_REGION;
                    else          st <= S_PUSH;
                end
            end
            S_REGION: begin // 窗完整（末组已落 SDRAM、FIFO 空、无在途）：置完成标志
                region_done[win] <= 1'b1;
                st <= S_WINWAIT;
            end
            S_WINWAIT: begin // 等新窗首补丁；对新窗基址发一次 LOAD（gnt=0 期间码流可回压）
                if (wr_valid) begin
                    win_next  <= wr_win;
                    win       <= wr_win;
                    wr2_addr  <= wr_win ? NB[20:0] : 21'd0;
                    wr2_load  <= 1'b1;
                    // ★ 开始重写新窗：清除其完成标志（旧数据从此刻起不可信）
                    region_done[wr_win] <= 1'b0;
                    grp <= 7'd0; grpno <= 9'd0; last_grp <= 1'b0;
                    st <= S_PUSH;
                end
            end
            default: st <= S_WAIT0;
            endcase
        end
    end
endmodule
