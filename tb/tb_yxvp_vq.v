// tb_yxvp_vq.v — YX-VP-VQ 解码核对拍测试台
//
// 输入 .yxv2 文件（TB 解析 20B 头，跳过 codebook，把帧载荷喂给 RTL 字节流），
// 参考帧来自 vq_decode_delta.py --dump 的大端 RGB565 ref.bin。
// 每帧 frame_done 时把 TB 侧 fbuf 与参考帧逐像素比对。
//
// 编译宏：YXVP_W / YXVP_H / YXVP_CBSIZE
// 运行参数：+STREAM=<file.yxv2> +REF=<prefix.ref.bin> [+WD=<周期上限>]
`timescale 1ns/1ps

module tb_yxvp_vq;
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

    localparam NB = (W/4) * (H/4);

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    // ---- DUT ----
    wire        sv;
    wire [7:0]  sd;
    wire        srdy;
    wire        pix_we;
    wire [21:0] pix_addr;
    wire [15:0] pix_data;
    wire        frame_done, frame_key;
    wire [15:0] frame_no;

    yx_vp_vq #(.W(W), .H(H), .CBSIZE(CBSIZE)) dut (
        .clk(clk), .rst_n(rst_n),
        .stream_valid(sv), .stream_data(sd), .stream_ready(srdy),
        .pix_rdy(1'b1),
        .pix_we(pix_we), .pix_addr(pix_addr), .pix_data(pix_data),
        .frame_done(frame_done), .frame_key(frame_key), .frame_no(frame_no)
    );

    // ---- 流文件装载 ----
    localparam SMAX = 4*1024*1024;
    reg [7:0] smem [0:SMAX-1];
    integer slen, soff, sent, payload_len;
    integer nframe_want;

    // ---- 参考与帧缓冲 ----
    reg [15:0] fbuf [0:W*H-1];
    reg [15:0] rbuf [0:W*H-1];
    integer ref_fd;
    integer total_err;
    integer fd_cnt;

    // ---- 像素写模型 ----
    always @(posedge clk) begin
        if (rst_n && pix_we) fbuf[pix_addr] <= pix_data;
    end

    // ---- 码本装载（经层次引用进 DUT）----
    reg [255:0] bookpath;
    integer junk;

    // ---- 比对任务 ----
    integer i, nread, fr_err, seek_off;
    task cmp_frame;
        input integer fidx;
        reg [1023:0] msg;
        begin
            seek_off = fidx * W * H * 2;
            junk = $fseek(ref_fd, seek_off, 0);
            nread = $fread(rbuf, ref_fd);
            if (nread != W*H*2) begin
                $display("REF-SHORT: frame %0d got %0d bytes want %0d", fidx, nread, W*H*2);
                total_err = total_err + 1;
            end
            fr_err = 0;
            for (i = 0; i < W*H; i = i + 1)
                if (rbuf[i] !== fbuf[i]) begin
                    if (fr_err < 5)
                        $display("  MISMATCH f%0d px%0d: got %04h want %04h",
                                 fidx, i, fbuf[i], rbuf[i]);
                    fr_err = fr_err + 1;
                end
            if (fr_err == 0 && nread == W*H*2)
                $display("RESULT-FRAME %0d kind=%s: PASS (%0d px)",
                         fidx, dut.kind_r ? "DELTA" : "KEY", W*H);
            else begin
                $display("RESULT-FRAME %0d kind=%s: FAIL err=%0d",
                         fidx, dut.kind_r ? "DELTA" : "KEY", fr_err);
                total_err = total_err + 1;
            end
        end
    endtask

    // ---- 帧完成监测（延后 2 拍比对：发射保持级 + NBA 写落地）----
    reg [1:0] cmp_dly;
    always @(posedge clk) begin
        if (rst_n) begin
            cmp_dly <= {cmp_dly[0], frame_done};
            if (cmp_dly[1]) begin
                cmp_frame(fd_cnt);
                fd_cnt <= fd_cnt + 1;
            end
        end
    end

    // ---- 字节流驱动（寄存器生产者；@(*) 数组读会挂死 iverilog 编译器，禁用）----
    reg        cur_valid;
    reg [7:0]  cur_byte;
    wire       adv = cur_valid & srdy;
    always @(posedge clk) begin
        if (!rst_n) begin
            cur_valid <= 1'b0;
            cur_byte  <= 8'h00;
        end else if (adv) begin
            sent      <= sent + 1;
            cur_valid <= (sent + 1) < payload_len;
            cur_byte  <= smem[soff + sent + 1];
        end else if (!cur_valid && rst_n) begin
            cur_valid <= sent < payload_len;
            cur_byte  <= smem[soff + sent];
        end
    end
    assign sv = cur_valid;
    assign sd = cur_byte;

    // ---- 主控 ----
    integer cyc, k;
    initial begin
        total_err = 0;
        fd_cnt    = 0;
        sent      = 0;
        cyc       = 0;
        for (k = 0; k < W*H; k = k + 1) fbuf[k] = 16'hx;

        if (!$value$plusargs("STREAM=%s", path)) begin
            $display("TB-ERR: 需要 +STREAM=<yxv2文件>");
            $finish;
        end
        if (!$value$plusargs("REF=%s", rpath)) begin
            $display("TB-ERR: 需要 +REF=<prefix.ref.bin>");
            $finish;
        end
        if (!$value$plusargs("WD=%d", wd)) wd = 100_000_000;
        if (!$value$plusargs("BOOK=%s", bookpath)) begin
            $display("TB-ERR: 需要 +BOOK=<book.hex>");
            $finish;
        end
        $readmemh(bookpath, dut.book);

        // 读入 .yxv2
        sf = $fopen(path, "rb");
        if (sf == 0) begin $display("TB-ERR: 打不开 %s", path); $finish; end
        slen = $fread(smem, sf);
        $fclose(sf);
        if (slen < 20) begin $display("TB-ERR: 文件过短"); $finish; end

        // 解析 20B 头
        hdr_w      = smem[7]  | (smem[8]  << 8);
        hdr_h      = smem[9]  | (smem[10] << 8);
        hdr_nframe = smem[12] | (smem[13] << 8);
        hdr_cb     = smem[14] | (smem[15] << 8);
        if (hdr_w !== W || hdr_h !== H) begin
            $display("TB-ERR: 几何不符 文件 %0dx%0d vs 参数 %0dx%0d", hdr_w, hdr_h, W, H);
            $finish;
        end
        if (hdr_cb !== CBSIZE) begin
            $display("TB-ERR: 码本不符 文件 %0d vs 参数 %0d", hdr_cb, CBSIZE);
            $finish;
        end
        nframe_want = hdr_nframe;
        soff        = 20 + hdr_cb * 32;
        payload_len = slen - soff;
        $display("TB: %0dx%0d cb=%0d frames=%0d payload=%0dB",
                 hdr_w, hdr_h, hdr_cb, nframe_want, payload_len);

        ref_fd = $fopen(rpath, "rb");
        if (ref_fd == 0) begin $display("TB-ERR: 打不开 %s", rpath); $finish; end

        rst_n = 0;
        #40;
        @(posedge clk);
        rst_n = 1;

        // 完成检测 / 看门狗
        while (fd_cnt < nframe_want && cyc < wd) begin
            @(posedge clk);
            cyc = cyc + 1;
        end
        $fclose(ref_fd);
        if (fd_cnt >= nframe_want)
            $display("TB-SUMMARY: %0s (%0d/%0d 帧, %0d clk, stream=%0dB)",
                     total_err == 0 ? "ALL PASS" : "FAIL", fd_cnt, nframe_want, cyc, sent);
        else
            $display("TB-SUMMARY: TIMEOUT/INCOMPLETE (%0d/%0d 帧, %0d clk, sent=%0dB, state=%0d)",
                     fd_cnt, nframe_want, cyc, sent, dut.state);
        $finish;
    end

    reg [255:0] path, rpath;
    integer sf;
    integer wd;
    integer hdr_w, hdr_h, hdr_nframe, hdr_cb;
endmodule
