// tb_yxvp_vbuf.v — 解码核 + 三缓冲槽管理器 + 行为级 SDRAM + 扫描显示 全链路对拍
//
// 链路: 字节流(文件) → yx_vp_vq → yx_vp_vbuf → SDRAM 模型 → 显示模型
//
// SDRAM 模型：写口每 3 拍最多服务 1 字（悲观带宽假设 ≈ 49MB/s 等效），每 8192 拍刷新停摆 64 拍，
// 读口可见期 1 字/拍。KEY 帧写入自动摊平到扫描帧槽内（pix_rdy 反压验证）。
//
// 检查项：
//   A. 撕裂不变量：写口永不触碰当前 ACTIVE 槽
//   B. 显示顺序：vblank 换入的帧号单调不减
//   C. 端到端逐位：最终 ACTIVE 槽内容 == Python 参考最后一帧
//
// 编译宏：YXVP_W / YXVP_H / YXVP_CBSIZE
// 运行参数：+STREAM=<yxv2> +REF=<ref.bin> +BOOK=<hex> [+WD=<clk上限>]
`timescale 1ns/1ps

module tb_yxvp_vbuf;
`ifdef YXVP_W
    parameter W = `YXVP_W;
`else
    parameter W = 1280;
`endif
`ifdef YXVP_H
    parameter H = `YXVP_H;
`else
    parameter H = 720;
`endif
`ifdef YXVP_CBSIZE
    parameter CBSIZE = `YXVP_CBSIZE;
`else
    parameter CBSIZE = 1024;
`endif

    localparam AW    = (W*H*3 > 4194304) ? 23 : 22;
    localparam SLOT  = W*H;
    localparam LINES = H + H/24;          // 720→750, 144→150
    localparam BLKX  = (W*29)/100;        // 行消隐（与 720p 时序同比例 ~22%）
    localparam LINE_T = W + BLKX;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    // ================= 公共观测信号（先声明，避免前向引用陷阱）=================
    reg        vblank_r;
    reg        disp_req;
    reg [AW-1:0] disp_addr;
    reg        wr_gnt_r;
    wire       wr_gnt = wr_gnt_r;
    integer    wr_served, rd_served, ref_cnt;
    integer    n_emit, n_push, n_fpop;
    integer    n_load, n_hold, n_rdyx, n_pendx;
    integer    cmp_total;
    integer    lf, mm_fd;
    integer    ef, pf;
    wire [21:0] fsm_addr_w = u_dec.fsm_addr;
    integer    vb_cnt, last_disp_fno;
    reg        tear_err, order_err;
    integer    cmp_err;
    integer    ref_fd;
    reg [15:0] rbuf [0:W*H-1];

    // ================= 解码核 =================
    wire        srdy;
    wire        v_pix_we;
    wire [21:0] v_pix_addr;
    wire [15:0] v_pix_data;
    wire        v_pix_rdy;
    wire        v_fd, v_fkey;
    wire [15:0] v_fno;
    wire        sv;
    wire [7:0]  sd;

    yx_vp_vq #(.W(W), .H(H), .CBSIZE(CBSIZE)) u_dec (
        .clk(clk), .rst_n(rst_n),
        .stream_valid(sv), .stream_data(sd), .stream_ready(srdy),
        .pix_rdy(v_pix_rdy),
        .pix_we(v_pix_we), .pix_addr(v_pix_addr), .pix_data(v_pix_data),
        .frame_done(v_fd), .frame_key(v_fkey), .frame_no(v_fno)
    );

    // ================= 三缓冲管理器 =================
    wire        wr_valid;
    wire [AW-1:0] wr_addr;
    wire [15:0] wr_data;
    wire [1:0]  act_slot;
    wire        act_valid;
    wire [15:0] act_fno;
    wire [AW-1:0] act_base;
    wire [5:0]  slot_sts;
    wire [11:0] fifo_lvl;

    yx_vp_vbuf #(.W(W), .H(H), .AW(AW), .BASE(0)) u_vbuf (
        .clk(clk), .rst_n(rst_n),
        .pix_we(v_pix_we), .pix_addr(v_pix_addr), .pix_data(v_pix_data),
        .frame_done(v_fd), .dec_frame_no(v_fno),
        .pix_rdy(v_pix_rdy),
        .wr_valid(wr_valid), .wr_addr(wr_addr), .wr_data(wr_data), .wr_gnt(wr_gnt),
        .vblank(vblank_r),
        .act_slot(act_slot), .act_valid(act_valid), .act_fno(act_fno), .act_base(act_base),
        .slot_sts(slot_sts), .fifo_lvl(fifo_lvl)
    );

    // ================= 行为级 SDRAM =================
    reg [15:0] sdram [0:(1<<AW)-1];
    reg [12:0] rcnt;                       // 刷新计时
    wire       ref_win = (rcnt < 13'd64);  // 刷新窗口 64 拍
    reg [1:0]  wphase;                     // 写服务节流：每 3 拍 1 字
    reg        rd_vld;
    reg [15:0] rd_dat;
    integer    tear_chk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rcnt <= 13'd0; wphase <= 2'd0;
            rd_vld <= 1'b0; rd_dat <= 16'd0;
            tear_err <= 1'b0;
        end else begin
            rcnt <= (rcnt == 13'd8191) ? 13'd0 : rcnt + 13'd1;
            wphase <= (wphase == 2'd2) ? 2'd0 : wphase + 2'd1;
            rd_vld <= 1'b0;
            // 读服务（显示请求，刷新窗口停摆）
            if (!ref_win && disp_req) begin
                rd_vld <= 1'b1;
                rd_dat <= sdram[disp_addr];
                rd_served = rd_served + 1;
            end
            // 写服务：每 3 拍 1 字 + 刷新窗口停摆
            wr_gnt_r <= (!ref_win) && (wphase == 2'd0);
            if (wr_valid && wr_gnt_r) begin
                // 检查 A：写口不得触碰当前 ACTIVE 槽（BASE=0，槽号=地址/槽距）
                tear_chk = wr_addr / SLOT;
                if (tear_chk == act_slot && slot_sts[act_slot*2 +: 2] === 2'd3) begin
                    tear_err <= 1'b1;
                    $display("TEAR-ERR t=%0dclk 写槽=%0d addr=%h act_slot=%0d act_fno=%0d sts=%b",
                             cyc_now, tear_chk, wr_addr, act_slot, act_fno, slot_sts);
                end
                sdram[wr_addr] <= wr_data;
                wr_served = wr_served + 1;
            end
            if (ref_win) ref_cnt = ref_cnt + 1;
        end
    end

    // ================= 显示模型（扫描 + vblank）=================
    integer sx, sy;
    reg scan_on;

    // ---- 槽事件探针（定位分配/换入异常用）----
    integer cyc_now, cur_fno;
    integer pw_lo, pw_hi;
    reg [21:0] last_pix_addr;
    always @(posedge clk) begin
        if (rst_n) begin
            cyc_now = cyc_now + 1;
            if (u_vbuf.vpop)
                $display("[VPOP] t=%0d slot=%0d fno=%0d old_act=%0d sts=%b",
                         cyc_now, u_vbuf.rq_slot[0], u_vbuf.rq_fno[0], act_slot, slot_sts);
            if (u_vbuf.fpush && !u_vbuf.dec_on)
                $display("[ALLOC] t=%0d slot=%0d sts=%b",
                         cyc_now, u_vbuf.new_slot, slot_sts);
            if (u_vbuf.rmark)
                $display("[MARK] t=%0d slot=%0d fno=%0d rq_cnt=%0d",
                         cyc_now, u_vbuf.dec_slot, u_vbuf.pend_fno, u_vbuf.rq_cnt);
            // 推送探针：窗口内的每次入队（字地址 + 指针/电平）
            if (u_vbuf.fpush && cyc_now >= pw_lo && cyc_now <= pw_hi)
                $display("[PUSH] t=%0d route=%0d pixaddr=%0d word=%0d wp=%0d rp=%0d lvl=%0d dec_on=%b",
                         cyc_now, u_vbuf.route_slot, v_pix_addr,
                         u_vbuf.sbase(u_vbuf.route_slot) + v_pix_addr,
                         u_vbuf.wp, u_vbuf.rp, u_vbuf.lvl, u_vbuf.dec_on);
            // 排水探针：窗口内的每次接受
            if (wr_valid && wr_gnt_r && cyc_now >= pw_lo && cyc_now <= pw_hi)
                $display("[DRAIN] t=%0d addr=%0d rp=%0d lvl=%0d",
                         cyc_now, wr_addr, u_vbuf.rp, u_vbuf.lvl);
            // 丢失定位计数器：发射 → vbuf 推送 → FIFO 弹出 → SDRAM 落盘
            if (u_dec.fsm_we) begin
                n_emit = n_emit + 1;
                $fdisplay(ef, "%0d %0d", cyc_now, fsm_addr_w);
            end
            if (u_dec.fsm_we) begin
                n_load = n_load + 1;
                $fdisplay(lf, "%0d %0d", cyc_now, u_dec.fsm_addr);
            end
            if (u_dec.q_cnt != 0 && !v_pix_rdy) n_hold = n_hold + 1;
            if (v_pix_rdy === 1'bx) n_rdyx = n_rdyx + 1;
            if (u_dec.q_cnt === 3'bx) n_pendx = n_pendx + 1;
            if (v_pix_we && v_pix_rdy) begin
                n_push = n_push + 1;
                $fdisplay(pf, "%0d %0d", cyc_now, v_pix_addr);
            end
            if (u_vbuf.fpop) n_fpop = n_fpop + 1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sx <= 0; sy <= 0;
            disp_req <= 1'b0; disp_addr <= {AW{1'b0}};
            vblank_r <= 1'b0;
            last_disp_fno <= -1;
            order_err <= 1'b0;
            scan_on <= 1'b1;                    // 上电即扫描（首帧前显示垃圾，符合真实显示器）
        end else begin
            vblank_r <= 1'b0;
            if (scan_on && !ref_win) begin
                if (sx < W) begin
                    disp_req  <= 1'b1;
                    disp_addr <= act_base + sy*W + sx;
                    sx <= sx + 1;
                end else begin
                    disp_req <= 1'b0;
                    if (sx >= LINE_T - 1) begin
                        sx <= 0;
                        sy <= sy + 1;
                        if (sy >= LINES - 1) begin
                            sy <= 0;
                            vblank_r <= 1'b1;      // 扫描帧结束
                        end
                    end else
                        sx <= sx + 1;
                end
            end else begin
                disp_req <= 1'b0;
            end
            // 检查 B：显示顺序单调（整数中转，避免无符号/有符号比较陷阱）
            if (vblank_r && act_valid) begin
                vb_cnt = vb_cnt + 1;
                cur_fno = act_fno;
                if (cur_fno < last_disp_fno) begin
                    order_err <= 1'b1;
                    $display("ORDER-ERR t=%0dclk 显示帧号回退 %0d -> %0d",
                             cyc_now, last_disp_fno, cur_fno);
                end
                last_disp_fno <= cur_fno;
                // 检查 C：每帧换入即比对（槽内容在 READY 后不变，可直接比）
                ref_cmp(cur_fno, act_base);
            end
        end
    end

    // ================= 端到端比较任务 =================
    task ref_cmp;
        input integer fidx;
        input [AW-1:0] base;
        integer i, nread, seek_off, junk;
        begin
            cmp_err = 0;
            ref_fd = $fopen(rpath, "rb");
            if (ref_fd == 0) begin $display("TB-ERR: 打不开 %s", rpath); $finish; end
            seek_off = fidx * W * H * 2;
            junk = $fseek(ref_fd, seek_off, 0);
            nread = $fread(rbuf, ref_fd);
            $fclose(ref_fd);
            if (nread != W*H*2) begin
                $display("REF-SHORT: frame %0d got %0d want %0d", fidx, nread, W*H*2);
                cmp_err = -1;
            end else begin
                for (i = 0; i < W*H; i = i + 1)
                    if (sdram[base + i] !== rbuf[i]) begin
                        cmp_err = cmp_err + 1;
                        $fdisplay(mm_fd, "%0d %04h %04h", i, sdram[base + i], rbuf[i]);
                    end
            end
            if (cmp_err == 0)
                $display("RESULT-E2E frame %0d slot=%0d: PASS (%0d px 经 SDRAM 逐位一致)",
                         fidx, base / SLOT, W*H);
            else begin
                cmp_total = cmp_total + 1;
                $display("RESULT-E2E frame %0d: FAIL err=%0d (首个失配块见 out\\vp_mm.txt)",
                         fidx, cmp_err);
            end
        end
    endtask

    // ================= 字节流生产者（寄存器式）=================
    localparam SMAX = 4*1024*1024;
    reg [7:0] smem [0:SMAX-1];
    integer slen, soff, sent, payload_len;
    reg cur_valid;
    reg [7:0] cur_byte;
    wire adv = cur_valid & srdy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_valid <= 1'b0; cur_byte <= 8'h00;
        end else if (adv) begin
            sent      <= sent + 1;
            cur_valid <= (sent + 1) < payload_len;
            cur_byte  <= smem[soff + sent + 1];
        end else if (!cur_valid) begin
            cur_valid <= sent < payload_len;
            cur_byte  <= smem[soff + sent];
        end
    end
    assign sv = cur_valid;
    assign sd = cur_byte;

    // ================= 主控 =================
    reg [255:0] path, rpath, bookpath;
    integer sf, wd, hdr_w, hdr_h, hdr_nframe, hdr_cb;
    integer cyc, frames_seen, stall_cnt, fmax, prev_fd_cyc, dec_clks, i;
    reg done_reading;

    initial begin
        wr_served = 0; rd_served = 0; ref_cnt = 0; n_emit = 0; n_push = 0; n_fpop = 0; n_load = 0; n_hold = 0; n_rdyx = 0; n_pendx = 0; cmp_total = 0;
        ef = $fopen("out\\vp_emit.txt", "w");
        pf = $fopen("out\\vp_push.txt", "w");
        lf = $fopen("out\\vp_load.txt", "w");
        mm_fd = $fopen("out\\vp_mm.txt", "w");
        vb_cnt = 0; last_disp_fno = -1; cmp_err = 0;
        cyc = 0; sent = 0; frames_seen = 0; stall_cnt = 0; fmax = 0;
        prev_fd_cyc = 0; done_reading = 0;
        tear_err = 0; order_err = 0;
        cyc_now = 0; cur_fno = 0;

        if (!$value$plusargs("STREAM=%s", path)) begin $display("TB-ERR: 需要 +STREAM"); $finish; end
        if (!$value$plusargs("REF=%s", rpath))   begin $display("TB-ERR: 需要 +REF"); $finish; end
        if (!$value$plusargs("BOOK=%s", bookpath)) begin $display("TB-ERR: 需要 +BOOK"); $finish; end
        if (!$value$plusargs("WD=%d", wd)) wd = 200_000_000;
        if (!$value$plusargs("PWIN=%d", pw_lo)) pw_lo = 0;
        if (!$value$plusargs("PWINHI=%d", pw_hi)) pw_hi = 0;
        $readmemh(bookpath, u_dec.book);

        sf = $fopen(path, "rb");
        if (sf == 0) begin $display("TB-ERR: 打不开 %s", path); $finish; end
        slen = $fread(smem, sf);
        $fclose(sf);
        hdr_w      = smem[7]  | (smem[8]  << 8);
        hdr_h      = smem[9]  | (smem[10] << 8);
        hdr_nframe = smem[12] | (smem[13] << 8);
        hdr_cb     = smem[14] | (smem[15] << 8);
        if (hdr_w !== W || hdr_h !== H) begin
            $display("TB-ERR: 几何不符 文件 %0dx%0d vs 参数 %0dx%0d", hdr_w, hdr_h, W, H); $finish;
        end
        if (hdr_cb !== CBSIZE) begin
            $display("TB-ERR: 码本不符 文件 %0d vs 参数 %0d", hdr_cb, CBSIZE); $finish;
        end
        soff        = 20 + hdr_cb * 32;
        payload_len = slen - soff;
        $display("TB: %0dx%0d cb=%0d frames=%0d payload=%0dB  AW=%0d LINE_T=%0d LINES=%0d",
                 hdr_w, hdr_h, hdr_cb, hdr_nframe, payload_len, AW, LINE_T, LINES);

        rst_n = 0; #40; @(posedge clk); rst_n = 1;

        while (cyc < wd && !done_reading) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (!v_pix_rdy && u_dec.state === 4'd10) stall_cnt = stall_cnt + 1;
            if (fifo_lvl > fmax) fmax = fifo_lvl;
            if (v_fd) begin
                frames_seen = frames_seen + 1;
                dec_clks = cyc - prev_fd_cyc;
                prev_fd_cyc = cyc;
                $display("FRAME-DONE #%0d kind=%s t=%0d 解码时长=%0d clk",
                         v_fno, v_fkey ? "DELTA" : "KEY", cyc, dec_clks);
            end
            if (frames_seen >= hdr_nframe && cyc > prev_fd_cyc + 3_000_000)
                done_reading = 1;
        end
        if (!done_reading) begin
            $display("TB-ERR: 看门狗超时 frames=%0d/%0d sent=%0d/%0d",
                     frames_seen, hdr_nframe, sent, payload_len);
            $finish;
        end

        // ---- 等最后一帧换入显示 ----
        i = 0;
        while (act_fno !== hdr_nframe - 1 && i < 6_000_000) begin
            @(posedge clk); i = i + 1;
        end
        if (act_fno !== hdr_nframe - 1) begin
            $display("TB-ERR: 末帧未换入显示 act_fno=%0d want=%0d", act_fno, hdr_nframe-1);
            $finish;
        end

        // 逐帧比对已在每次换入显示时完成（ref_cmp 在 vblank 分支内调用）

        $display("CNT: emit=%0d load=%0d push=%0d fpop=%0d sdram=%0d hold=%0d rdyx=%0d pendx=%0d", n_emit, n_load, n_push, n_fpop, wr_served, n_hold, n_rdyx, n_pendx);
        $display("STATS: 扫描帧=%0d 写服务=%0d 读服务=%0d 刷新停摆=%0d 解码停顿=%0d FIFO峰值=%0d",
                 vb_cnt, wr_served, rd_served, ref_cnt, stall_cnt, fmax);
        if (tear_err || order_err || cmp_total != 0)
            $display("TB-SUMMARY: FAIL (tear=%b order=%b fail-frames=%0d)", tear_err, order_err, cmp_total);
        else
            $display("TB-SUMMARY: ALL PASS (frames=%0d, %0d clk)", frames_seen, cyc);
        $finish;
    end
endmodule
