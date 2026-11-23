// yx_b_hdr_parse.v — YXV2 文件头解析 + 码本装载 + 字节流直通
//
// 文件头 20B（实测 vp_*_5f.yxv2 布局）：
//   [0:3]="YXV2" [4]=ver [5]=04 [6]=00 [7:8]=W(L) [9:10]=H(L) [11]=fps
//   [12:13]=nframe(L) [14:15]=codebook 数(L) [16:19]=保留
// 行为：校验 magic 与 W/H/CB 匹配参数（不符置 hdr_err 停机），随后 cb×32B
// 逐字灌 band 码本 BRAM（小端 16b），装载完成置 hdr_ok，此后字节流原样直通
// ixdec（首个到达字节 = 帧头 kind，ixdec 从 S_HDR0 起正好消费）。
//
// ★ 首帧 KEY 强制校验（YX5 遗留债清偿）：码本装载后的第一个直通字节 = 帧 0
//   的 kind（0=KEY 1=DELTA）。首帧若为 DELTA，合并流将读未初始化窗 → 静默
//   全错；此处校验首字节必须 0，违规置 hdr_err（TB GATE 有 phe 判据收口）。
//   校验不吞字节——同拍直通照常（out_valid 与检查并行）。
//
// 回压语义：in_ready 恒 1（解析/装载永不迟滞，码本写 1 字/拍 ≤ 字节率）。
module yx_b_hdr_parse #(
    parameter W      = 1280,
    parameter H      = 720,
    parameter CBSIZE = 1024
)(
    input  wire        clk,
    input  wire        rst_n,
    // ---- 入口字节流 ----
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    output wire        in_ready,
    // ---- 出口字节流（→ ixdec）----
    output wire        out_valid,
    output wire [7:0]  out_data,
    input  wire        out_ready,
    // ---- 码本写口（→ band）----
    output reg         book_we,
    output reg  [13:0] book_wa,
    output reg  [15:0] book_wd,
    // ---- 状态 ----
    output reg         hdr_ok,
    output reg         hdr_err
);
    localparam S_MAGIC = 3'd0, S_PARAM = 3'd1,
               S_CB    = 3'd3, S_PASS  = 3'd4, S_ERR   = 3'd5;

    reg [2:0]  st;
    reg [4:0]  bidx;                  // 头内字节序号 0..19
    reg [15:0] w_r, h_r, nf_r, cb_r;
    reg [15:0] cb_cnt;                // 已装载字节/2 的字计数
    reg [7:0]  lo_b;
    reg        lo_v;
    reg        f0_chk;                // 首帧 kind 字节已校验

    // 回压语义：头/码本阶段永不迟滞（写 1 字/拍 ≤ 字节率）；PASS 直通段必须
    // 把 out_ready 传回入口（否则 ixdec 未就绪时字节被静默丢弃、码流失步）
    assign in_ready = (st != S_PASS) ? 1'b1 : out_ready;
    assign out_valid = (st == S_PASS) && in_valid;
    assign out_data  = in_data;
    wire get = in_valid;
    reg [15:0] dbg_cnt = 16'd0;
    always @(posedge clk) dbg_cnt <= dbg_cnt + (get ? 16'd1 : 16'd0);
    always @(posedge clk) begin
        if (get && dbg_cnt < 16'd12)
            $display("PARSE %0d (st=%0d): %02x", dbg_cnt, st, in_data);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_MAGIC; bidx <= 5'd0;
            w_r <= 16'd0; h_r <= 16'd0; nf_r <= 16'd0; cb_r <= 16'd0;
            cb_cnt <= 16'd0; lo_b <= 8'd0; lo_v <= 1'b0;
            f0_chk <= 1'b0;
            book_we <= 1'b0; book_wa <= 14'd0; book_wd <= 16'd0;
            hdr_ok <= 1'b0; hdr_err <= 1'b0;
        end else begin
            book_we <= 1'b0;
            if (book_we) book_wa <= book_wa + 14'd1;   // band 写在次拍，写完再进下一址
            if (get) begin
                case (st)
                S_MAGIC: begin
                    if ((bidx == 0 && in_data != 8'h59) ||
                        (bidx == 1 && in_data != 8'h58) ||
                        (bidx == 2 && in_data != 8'h56) ||
                        (bidx == 3 && in_data != 8'h32)) begin
                        hdr_err <= 1'b1; st <= S_ERR;
                    end
                    bidx <= bidx + 5'd1;
                    if (bidx == 4'd3) st <= S_PARAM;
                end
                S_PARAM: begin
                    case (bidx)
                    5'd7:  w_r[7:0]   <= in_data;
                    5'd8:  w_r[15:8]  <= in_data;
                    5'd9:  h_r[7:0]   <= in_data;
                    5'd10: h_r[15:8]  <= in_data;
                    5'd12: nf_r[7:0]  <= in_data;
                    5'd13: nf_r[15:8] <= in_data;
                    5'd14: cb_r[7:0]  <= in_data;
                    5'd15: cb_r[15:8] <= in_data;
                    default: ;
                    endcase
                    // ★ 校验并入末字节拍（不占独立状态——独立状态会吞一个字节）
                    if (bidx == 5'd19) begin
                        if (w_r == W[15:0] && h_r == H[15:0] && cb_r == CBSIZE[15:0]) begin
                            cb_cnt  <= 16'd0; lo_v <= 1'b0;
                            book_wa <= 14'd0;
                            st <= S_CB;
                        end else begin
                            hdr_err <= 1'b1; st <= S_ERR;
                        end
                    end else
                        bidx <= bidx + 5'd1;
                end
                S_CB: begin
                    if (!lo_v) begin
                        lo_b  <= in_data;
                        lo_v  <= 1'b1;
                    end else begin
                        book_we <= 1'b1;
                        book_wd <= {in_data, lo_b};
                        cb_cnt  <= cb_cnt + 16'd1;
                        lo_v    <= 1'b0;
                        // ★ book_wa 在 book_we 拍后自增：band 的写晚一拍，
                        //   用的必须是当前字的地址（同拍自增会写 wa+1、漏 wa）
                        if (cb_cnt == CBSIZE * 16 - 1) begin
                            hdr_ok <= 1'b1;
                            st     <= S_PASS;
                        end
                    end
                end
                S_PASS: begin
                    // ★ 首帧 KEY 强制校验：直通首字节 = 帧 0 kind，必须 0（KEY）。
                    //   不吞字节——同拍直通照常，违规仅置 hdr_err 由 GATE 收口。
                    if (!f0_chk) begin
                        f0_chk <= 1'b1;
                        if (in_data != 8'h00) begin
                            hdr_err <= 1'b1;
                            if (hdr_err == 1'b0)
                                $display("HDRPARSE-ERR: first frame kind=%02h (want 00=KEY)", in_data);
                            st <= S_ERR;
                        end
                    end
                end
                default: st <= S_ERR;
                endcase
            end
        end
    end
endmodule
