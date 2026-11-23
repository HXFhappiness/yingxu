// tb_yxvp_ixpipe.v — 方案 A 索引管线全链路对拍
//
// 链路: 字节流(.yxv2) → yx_vp_ixdec(补丁字) → yx_vp_ixbuf(双索引缓冲+拷贝-补丁-翻转)
//       → yx_vp_band(码本查表+行缓冲) → TB 逐带比对
//
// SDRAM 行为模型：写口 1/3 拍节流 + 每 8192 拍刷新停摆 64 拍；读口×2（拷贝/取带）各 1 拍/字。
// 验收：每带 band_done 时与 Python 参考帧（ref.bin）对应 4 行逐位比对；全帧全部带 PASS。
//
// 编译宏：YXVP_W / YXVP_H / YXVP_CBSIZE
// 运行参数：+STREAM=<yxv2> +REF=<ref.bin> +BOOK=<hex> [+WD=<clk上限>]
`timescale 1ns/1ps

module tb_yxvp_ixpipe;
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

    localparam NB   = (W/4) * (H/4);
    localparam BH   = H/4;
    // 2*NB <= 131072 用 17 位；1080p 2*129600=259200 需 19 位
    localparam AW   = (2*NB > (1<<17)) ? 19 : 17;
    localparam IDXB = (CBSIZE > 256) ? 2 : 1;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    // ================= 公共声明（避免前向引用陷阱）=================
    integer cyc, cyc_now;
    integer ref_fd;
    integer frames_done, bands_done, cmp_total, band_cnt;
    integer n_emit, n_push, n_wr;
    integer wd;
    reg done_reading;
    integer hdr_w, hdr_h, hdr_nframe, hdr_cb;
    integer i, j, nread, seek_off, junk, fr_err;
    reg [15:0] rendered_no;               // 渲染器完成帧号（0 基，馈 ixbuf）
    reg [15:0] rrow [0:4*W-1];            // 参考行缓冲（4 行）

    // ================= 字节流生产者 =================
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
    wire sv = cur_valid;
    wire [7:0] sd = cur_byte;

    // ================= 索引解码器 =================
    wire        srdy;
    wire        ix_we;
    wire [16:0] ix_blk;
    wire [9:0]  ix_idx;
    wire        ix_rdy;
    wire        dec_fd, dec_key, dec_started, dec_kind;
    wire [15:0] dec_fno;

    yx_vp_ixdec #(.W(W), .H(H), .CBSIZE(CBSIZE)) u_ixdec (
        .clk(clk), .rst_n(rst_n),
        .stream_valid(sv), .stream_data(sd), .stream_ready(srdy),
        .ix_we(ix_we), .ix_blk(ix_blk), .ix_idx(ix_idx), .ix_rdy(ix_rdy),
        .frame_done(dec_fd), .frame_key(dec_key), .frame_no(dec_fno),
        .frame_started(dec_started), .frame_kind(dec_kind)
    );

    // ================= 索引缓冲管理器 =================
    reg         wr_gnt_r;
    wire        wr_gnt = wr_gnt_r;
    wire        wr_valid;
    wire [AW-1:0] wr_addr;
    wire [15:0] wr_data;
    wire        cp_rd, cp_dvld;
    wire [AW-1:0] cp_addr;
    wire [15:0] cp_data;
    wire        swap_done;
    wire [15:0] commit_no;
    wire [AW-1:0] act_base;

    yx_vp_ixbuf #(.NB(NB), .AW(AW)) u_ixbuf (
        .clk(clk), .rst_n(rst_n),
        .ix_we(ix_we), .ix_blk(ix_blk), .ix_idx(ix_idx), .ix_rdy(ix_rdy),
        .frame_done(dec_fd), .frame_started(dec_started), .frame_kind(dec_kind),
        .wr_valid(wr_valid), .wr_addr(wr_addr), .wr_data(wr_data), .wr_gnt(wr_gnt),
        .cp_rd(cp_rd), .cp_addr(cp_addr), .cp_dvld(cp_dvld), .cp_data(cp_data),
        .swap_done(swap_done), .commit_no(commit_no), .act_base(act_base),
        .rendered_no(rendered_no)
    );

    // ================= 条带渲染器 =================
    wire        bnd_rd_req, bnd_dvld;
    wire [AW-1:0] bnd_rd_addr;
    wire [15:0] bnd_rd_data;
    wire        band_done, band_frame_done;
    wire [15:0] rend_no;
    wire [8:0]  band_no;
    reg         band_ack_r;
    wire        band_ack = band_ack_r;

    yx_vp_band #(.W(W), .H(H), .CBSIZE(CBSIZE), .AW(AW)) u_band (
        .clk(clk), .rst_n(rst_n),
        .swap_done(swap_done), .commit_no(commit_no), .act_base(act_base),
        .rd_req(bnd_rd_req), .rd_addr(bnd_rd_addr), .rd_dvld(bnd_dvld), .rd_data(bnd_rd_data),
        .band_done(band_done), .render_no(rend_no), .band_no(band_no),
        .band_ack(band_ack), .frame_done(band_frame_done)
    );

    // ================= 行为级 SDRAM（写节流 + 刷新；读口×2）=================
    reg [15:0] sdram [0:(1<<AW)-1];
    reg [12:0] rcnt;
    wire       ref_win = (rcnt < 13'd64);
    reg [1:0]  wphase;
    reg        dv_a, dv_b;
    reg [15:0] dt_a, dt_b;
    assign cp_dvld = dv_a;
    assign cp_data = dt_a;
    assign bnd_dvld = dv_b;
    assign bnd_rd_data = dt_b;
    integer    wr_served, rd_a_served, rd_b_served;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rcnt <= 13'd0; wphase <= 2'd0;
            dv_a <= 1'b0; dt_a <= 16'd0;
            dv_b <= 1'b0; dt_b <= 16'd0;
        end else begin
            rcnt <= (rcnt == 13'd8191) ? 13'd0 : rcnt + 13'd1;
            wphase <= (wphase == 2'd2) ? 2'd0 : wphase + 2'd1;
            dv_a <= 1'b0; dv_b <= 1'b0;
            if (!ref_win) begin
                // 读口 A：拷贝
                if (cp_rd) begin
                    dv_a <= 1'b1;
                    dt_a <= sdram[cp_addr];
                    rd_a_served = rd_a_served + 1;
                end
                // 读口 B：取带
                if (bnd_rd_req) begin
                    dv_b <= 1'b1;
                    dt_b <= sdram[bnd_rd_addr];
                    rd_b_served = rd_b_served + 1;
                end
            end
            // 写口：每 3 拍 1 字 + 刷新停摆
            wr_gnt_r <= (!ref_win) && (wphase == 2'd0);
            if (wr_valid && wr_gnt_r) begin
                sdram[wr_addr] <= wr_data;
                wr_served = wr_served + 1;
                n_wr = n_wr + 1;
                if (wr_served <= 40 || wr_served[11:0] == 12'd2304)
                    $display("WR#%0d t=%0d addr=%0d data=%04h", wr_served, cyc_now, wr_addr, wr_data);
            end
        end
    end

    // ================= 逐带比对（band_done → 比对 4 行 → ack）=================
    reg [15:0] mm_v;
    reg cmp_ok_b;
    reg [15:0] tmprow [0:W-1];            // 单行参考（W 字，精确读入）
    task band_cmp;
        input [15:0] fno;
        input [8:0]  bno;
        integer row, x, base_i, lidx;
        reg [15:0] ln_px;
        begin
            fr_err = 0;
            for (row = 0; row < 4; row = row + 1) begin
                seek_off = ((fno * H) + bno * 4 + row) * W * 2;
                junk = $fseek(ref_fd, seek_off, 0);
                nread = $fread(tmprow, ref_fd);
                if (nread != W*2) begin
                    $display("REF-SHORT f%0d b%0d r%0d got %0d want %0d", fno, bno, row, nread, W*2);
                    fr_err = fr_err + 1;
                end else begin
                    base_i = (bno[0] * 4 + row) * W;
                    for (x = 0; x < W; x = x + 1) begin
                        lidx = base_i + x;
                        // ★ P5-P0：行缓冲已打包 32bit（{奇,偶}），按字/半字取值
                        ln_px = lidx[0] ? u_band.u_ln32.mem[lidx>>1][31:16]
                                        : u_band.u_ln32.mem[lidx>>1][15:0];
                        if (ln_px !== tmprow[x]) begin
                            if (fr_err < 24)
                                $display("  BAND-MM f%0d b%0d r%0d x%0d: got %04h want %04h",
                                         fno, bno, row, x, ln_px, tmprow[x]);
                            fr_err = fr_err + 1;
                        end
                    end
                end
            end
            band_cnt = band_cnt + 1;
            if (fr_err == 0) begin
                cmp_ok_b <= 1'b1;
            end else begin
                cmp_total = cmp_total + 1;
                cmp_ok_b <= 1'b0;
                $display("RESULT-BAND f%0d b%0d: FAIL err=%0d", fno, bno, fr_err);
            end
        end
    endtask

    // band_done → 比对 → ack（延 2 拍等 NBA 落定）
    reg [1:0] ack_dly;
    reg [15:0] ack_fno;
    reg [8:0]  ack_bno;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ack_dly <= 2'd0; ack_fno <= 16'd0; ack_bno <= 9'd0; band_ack_r <= 1'b0;
        end else begin
            band_ack_r <= 1'b0;
            if (band_done) begin
                ack_fno <= rend_no;
                ack_bno <= band_no;
                ack_dly <= 2'd1;
            end else if (ack_dly != 2'd0) begin
                ack_dly <= ack_dly + 2'd1;
                if (ack_dly == 2'd2) begin
                    $display("FIRE t=%0d fno=%0d bno=%0d rend=%0d band=%0d st=%0d swapd=%b commit=%0d",
                             cyc_now, ack_fno, ack_bno, rend_no, band_no, u_band.st, swap_done, commit_no);
                    band_cmp(ack_fno, ack_bno);
                    bands_done = bands_done + 1;
                    band_ack_r <= 1'b1;
                    // 渲染器完成全部帧的比对后才允许退出（渲染器是瓶颈，不能按解码 fd 提前退）
                    if (bands_done >= hdr_nframe * BH) done_reading = 1;
                end
            end
        end
    end

    // 渲染器完成帧号跟踪 → ixbuf
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rendered_no <= 16'hffff;
        // 以最后一次 ack 的整帧行号为准（band==BH-1 时该帧已完整渲染并比对）
        else if (band_ack_r && ack_bno == BH - 1) rendered_no <= ack_fno;
    end

    // 帧完成计数（独立块：主循环启动前的脉冲也要计入）+ 帧边界字节核算
    integer fs_n, fd_n;
    initial begin fs_n = 0; fd_n = 0; end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frames_done = 0; done_reading = 0;
        end else begin
            if (dec_fd) begin
                frames_done = frames_done + 1;
                fd_n = fd_n + 1;
                if (fd_n <= 40)
                    $display("FDONE%0d t=%0d sent=%0d fno=%0d", fd_n, cyc_now, sent, dec_fno);
            end
            if (dec_started) begin
                fs_n = fs_n + 1;
                if (fs_n <= 40)
                    $display("FSTART%0d t=%0d sent=%0d kind=%b fno=%0d changed=%0d",
                             fs_n, cyc_now, sent, dec_kind, dec_fno, u_ixdec.changed_r);
            end
        end
    end

    // ================= 主控 =================
    reg [255:0] path, rpath, bookpath;
    integer sf;
    initial begin
        cyc = 0; cyc_now = 0; sent = 0;
        // X 注入定位：VCD 覆盖复位释放后前 30K 拍（t=50ns..650µs）
        $dumpfile("out\\ixpipe_x.vcd");
        $dumpvars(0, u_band);
        $dumpvars(0, u_ixbuf);
        frames_done = 0; bands_done = 0; cmp_total = 0; band_cnt = 0;
        n_emit = 0; n_push = 0; n_wr = 0; fr_err = 0;
        wr_served = 0; rd_a_served = 0; rd_b_served = 0;
        done_reading = 0;
        rendered_no = 16'hffff;
        cmp_ok_b = 0;

        if (!$value$plusargs("STREAM=%s", path)) begin $display("TB-ERR: 需要 +STREAM"); $finish; end
        if (!$value$plusargs("REF=%s", rpath))   begin $display("TB-ERR: 需要 +REF"); $finish; end
        if (!$value$plusargs("BOOK=%s", bookpath)) begin $display("TB-ERR: 需要 +BOOK"); $finish; end
        if (!$value$plusargs("WD=%d", wd)) wd = 100_000_000;
        $readmemh(bookpath, u_band.book);

        ref_fd = $fopen(rpath, "rb");
        if (ref_fd == 0) begin $display("TB-ERR: 打不开 %s", rpath); $finish; end
        // ref_fd 保持打开，band_cmp 内部 fseek 定位

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
        $display("TB: %0dx%0d cb=%0d frames=%0d payload=%0dB", hdr_w, hdr_h, hdr_cb, hdr_nframe, payload_len);

        rst_n = 0; #40; @(posedge clk); rst_n = 1;
        #650000 $dumpoff;

        while (cyc < wd && !done_reading) begin
            @(posedge clk);
            cyc = cyc + 1;
            cyc_now = cyc_now + 1;
            if (u_ixdec.fsm_we) n_emit = n_emit + 1;
            if (ix_we && ix_rdy) n_push = n_push + 1;
            if (cyc >= 1220000 && cyc <= 1220060)
                $display("CYC %0d: breq=%b bdvld=%b baddr=%0d bst=%0d bfetch=%b bpend=%b | model: refwin=%b rcserved=%0d | rdB_served=%0d",
                         cyc, u_band.rd_req, u_band.rd_dvld, u_band.rd_addr,
                         u_band.st, u_band.fetch_r, u_band.pend_cnt,
                         ref_win, rd_b_served, rd_b_served);
            if (cyc % 500000 == 0)
                $display("POLL t=%0d sent=%0d decstate=%0d ixphase=%0d act=%b busy=[%b%b] commit=%0d rend=%0d pfcnt=%0d | band: st=%0d band=%0d bx=%0d fetch=%b req=%b dvld=%b wp=%0d pend=%b addr=%0d | model: refwin=%b rdBsv=%0d dvb=%b",
                         cyc, sent, u_ixdec.state,
                         u_ixbuf.phase, u_ixbuf.act, u_ixbuf.busy[1], u_ixbuf.busy[0],
                         commit_no, rendered_no,
                         u_ixbuf.pf_cnt,
                         u_band.st, u_band.band_no, u_band.bx, u_band.fetch_r,
                         u_band.rd_req, u_band.rd_dvld, u_band.wp, u_band.pend_cnt,
                         u_band.rd_addr,
                         ref_win, rd_b_served, dv_b);
        end
        if (!done_reading) begin
            $display("TB-ERR: 看门狗超时 frames=%0d/%0d sent=%0d/%0d",
                     frames_done, hdr_nframe, sent, payload_len);
        end

        // 等最后一条带比对完成
        i = 0;
        while (band_cnt < bands_done && i < 1_000_000) begin
            @(posedge clk); i = i + 1;
        end

        // 诊断转储：索引缓冲内容 + 行缓冲
        $writememh("out\\ix_sdram_dump.txt", sdram);
        $writememh("out\\ix_ln_dump.txt", u_band.u_ln32.mem);

        $display("CNT: emit=%0d push=%0d wr=%0d bands=%0d frames=%0d cmpfail-frames=%0d",
                 n_emit, n_push, wr_served, bands_done, frames_done, cmp_total);
        if (cmp_total == 0 && bands_done == hdr_nframe * BH)
            $display("TB-SUMMARY: ALL PASS (frames=%0d bands=%0d, %0d clk)",
                     frames_done, bands_done, cyc);
        else
            $display("TB-SUMMARY: FAIL (bands=%0d/%0d cmpfail=%0d)",
                     bands_done, hdr_nframe * BH, cmp_total);
        $finish;
    end
endmodule
