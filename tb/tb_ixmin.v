// tb_ixmin.v — 索引管线最小对拍：ixdec → ixbuf → SDRAM 模型（无渲染器）
// 验收：每次 swap 后，active 缓冲内容 == 手工参考索引帧（逐位）
// 运行：+STREAM=ixmin.yxv2 +IXREF=ixmin_ixref.bin
`timescale 1ns/1ps

module tb_ixmin;
    parameter NB   = 2304;
    parameter AW   = 17;

    reg clk = 0;
    reg rst_n = 0;
    always #10 clk = ~clk;

    // ---- 流生产者 ----
    reg [7:0] smem [0:1<<20-1];
    integer slen = 0, soff = 0, sent = 0, payload_len = 0;
    reg cur_valid;
    reg [7:0] cur_byte;
    wire adv = cur_valid & srdy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_valid <= 0; cur_byte <= 0;
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

    // ---- ixdec ----
    wire        srdy;
    wire        ix_we;
    wire [16:0] ix_blk;
    wire [9:0]  ix_idx;
    wire        ix_rdy;
    wire        dec_fd, dec_key, dec_started, dec_kind;
    wire [15:0] dec_fno;

    yx_vp_ixdec #(.W(256), .H(144), .CBSIZE(1024)) u_ixdec (
        .clk(clk), .rst_n(rst_n),
        .stream_valid(sv), .stream_data(sd), .stream_ready(srdy),
        .ix_we(ix_we), .ix_blk(ix_blk), .ix_idx(ix_idx), .ix_rdy(ix_rdy),
        .frame_done(dec_fd), .frame_key(dec_key), .frame_no(dec_fno),
        .frame_started(dec_started), .frame_kind(dec_kind)
    );

    // ---- ixbuf ----
    reg         wr_gnt_r;
    wire        wr_gnt = wr_gnt_r;
    wire        wr_valid;
    wire [16:0] wr_addr;
    wire [15:0] wr_data;
    wire        cp_rd, cp_dvld;
    wire [16:0] cp_addr;
    wire [15:0] cp_data;
    wire        swap_done;
    wire [15:0] commit_no;
    wire [16:0] act_base;
    wire [15:0] rendered_no = commit_no;   // 渲染器瞬间跟上（简化）

    yx_vp_ixbuf #(.NB(NB), .AW(AW)) u_ixbuf (
        .clk(clk), .rst_n(rst_n),
        .ix_we(ix_we), .ix_blk(ix_blk), .ix_idx(ix_idx), .ix_rdy(ix_rdy),
        .frame_done(dec_fd), .frame_started(dec_started), .frame_kind(dec_kind),
        .wr_valid(wr_valid), .wr_addr(wr_addr), .wr_data(wr_data), .wr_gnt(wr_gnt),
        .cp_rd(cp_rd), .cp_addr(cp_addr), .cp_dvld(cp_dvld), .cp_data(cp_data),
        .swap_done(swap_done), .commit_no(commit_no), .act_base(act_base),
        .rendered_no(rendered_no)
    );

    // ---- 行为级 SDRAM：写口节流 1/3 + 刷新；拷贝读口 1/clk ----
    reg [15:0] sdram [0:(1<<AW)-1];
    reg [12:0] rcnt;
    wire       ref_win = (rcnt < 13'd64);
    reg [1:0]  wphase;
    reg        dv_c;
    reg [15:0] dt_c;
    integer    wr_served;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rcnt <= 0; wphase <= 0;
            dv_c <= 0; dt_c <= 0;
        end else begin
            rcnt <= (rcnt == 13'd8191) ? 0 : rcnt + 1;
            wphase <= (wphase == 2'd2) ? 0 : wphase + 1;
            dv_c <= 0;
            if (!ref_win && cp_rd) begin
                dv_c <= 1;
                dt_c <= sdram[cp_addr];
            end
            wr_gnt_r <= (!ref_win) && (wphase == 2'd0);
            if (wr_valid && wr_gnt_r)
                sdram[wr_addr] <= wr_data;
        end
    end

    // ---- 参考与比对 ----
    integer ref_fd;
    reg [15:0] refrow [0:NB-1];
    integer fr_err, i, nread, junk;
    integer cmp_total = 0;
    integer frames_commit = 0;
    integer frames_done = 0;
    reg done_reading = 0;
    reg [15:0] last_commit = 16'hffff;
    reg [1:0] cmp_dly;
    reg [15:0] cmp_fno;

    // swap 后延 4 拍比对（等拷贝/补丁完全落定）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmp_dly <= 0; cmp_fno <= 0;
        end else begin
            cmp_dly <= 0;
            if (swap_done) begin
                cmp_fno <= commit_no;
                cmp_dly <= 2'd1;
            end else if (cmp_dly == 2'd1)
                cmp_dly <= 2'd2;
            else if (cmp_dly == 2'd2)
                cmp_dly <= 2'd3;
            else if (cmp_dly == 2'd3) begin
                cmp_dly <= 0;
                // 比对 active 缓冲 vs 参考帧
                junk = $fseek(ref_fd, cmp_fno * NB * 2, 0);
                nread = $fread(refrow, ref_fd);
                if (nread != NB*2) begin
                    $display("REF-SHORT f%0d got %0d want %0d", cmp_fno, nread, NB*2);
                    cmp_total = cmp_total + 1;
                end else begin
                    fr_err = 0;
                    for (i = 0; i < NB; i = i + 1)
                        if (sdram[act_base + i] !== refrow[i]) begin
                            if (fr_err < 4)
                                $display("  IX-MM f%0d w%0d: got %04h want %04h",
                                         cmp_fno, i, sdram[act_base + i], refrow[i]);
                            fr_err = fr_err + 1;
                        end
                    cmp_total = cmp_total + fr_err;
                end
                if (fr_err == 0)
                    $display("RESULT-FRAME %0d: PASS (%0d words)", cmp_fno, NB);
                else
                    $display("RESULT-FRAME %0d: FAIL err=%0d", cmp_fno, fr_err);
                frames_commit = frames_commit + 1;
            end
        end
    end

    // ---- 主控 ----
    reg [255:0] spath, rpath;
    integer sf, wd = 30000000;
    integer cyc = 0;

    initial begin
        if (!$value$plusargs("STREAM=%s", spath)) begin $display("TB-ERR: +STREAM"); $finish; end
        if (!$value$plusargs("IXREF=%s", rpath)) begin $display("TB-ERR: +IXREF"); $finish; end
        if (!$value$plusargs("WD=%d", wd)) wd = 50_000_000;
        ref_fd = $fopen(rpath, "rb");
        if (ref_fd == 0) begin $display("TB-ERR: ref open"); $finish; end

        sf = $fopen(spath, "rb");
        if (sf == 0) begin $display("TB-ERR: stream open"); $finish; end
        slen = $fread(smem, sf);
        $fclose(sf);
        // 头解析：soff = 20 + cbsize*32；帧数
        soff = 20 + (smem[14] | smem[15] << 8) * 32;
        payload_len = slen - soff;
        junk = payload_len;
        $display("TB: payload=%0d bytes, NB=%0d", payload_len, NB);

        sent = 0;
        rst_n = 0; #40; @(posedge clk); rst_n = 1;

        while (cyc < wd) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (cyc % 1000000 == 0)
                $display("POLL t=%0d sent=%0d sv=%b srdy=%b decst=%0d ixph=%0d commit=%0d",
                         cyc, sent, sv, srdy, u_ixdec.state, u_ixbuf.phase, commit_no);
        end
        $display("TB-ERR: 看门狗超时 frames=%0d sent=%0d/%0d decst=%0d ixph=%0d",
                 frames_commit, sent, payload_len, u_ixdec.state, u_ixbuf.phase);
        $finish;
    end

    always @(posedge clk) begin
        if (dec_fd) frames_done = frames_done + 1;
    end
endmodule
