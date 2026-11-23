`timescale 1ns/1ps
// tb_gen_key_stream.v — 合成 KEY-only YXV2 码流生成器（无 python 依赖）
// 格式（与 vp_*_5f.yxv2 实测一致）：
//   20B 文件头："YXV2" + 02 04 + 00 + w(L16) + h(L16) + nframe(L16) + cb(L16) + 4×00
//   cb×32B 码本（entry i 的字 j = i+j，供后续像素核对）
//   每帧：kind=00 + 3B changed(0) + NB×2B 索引（idx[7:0] 先，byte1 低 2 位=idx[9:8]）
// 内容：idx = (blk*11 + frame*313) % CBSIZE（确定性，便于像素级核对）
// 用法：vvp tb_gen_key_stream.vvp +OUT=xxx.yxv2 +W=1280 +H=720 +CB=1024 +NF=5
module tb_gen_key_stream;
    integer W = 1280, H = 720, CB = 1024, NF = 5;
    integer fd, i, f, b, w, lo, hi;
    reg [255:0] path;
    reg [7:0]   ch;
    reg [15:0]  v;

    initial begin
        if (!$value$plusargs("OUT=%s", path))  begin $display("need +OUT"); $finish; end
        if (!$value$plusargs("W=%d", W))   W = 1280;
        if (!$value$plusargs("H=%d", H))   H = 720;
        if (!$value$plusargs("CB=%d", CB)) CB = 1024;
        if (!$value$plusargs("NF=%d", NF)) NF = 5;

        fd = $fopen(path, "wb");
        if (fd == 0) begin $display("open fail"); $finish; end
        // 文件头
        $fwrite(fd, "%c%c%c%c", 8'h59, 8'h58, 8'h56, 8'h32);   // YXV2
        $fwrite(fd, "%c%c", 8'h02, 8'h04);
        $fwrite(fd, "%c", 8'h00);
        $fwrite(fd, "%c%c", W[7:0],  W[15:8]);
        $fwrite(fd, "%c%c", H[7:0],  H[15:8]);
        $fwrite(fd, "%c", 8'd24);                // fps 字段（实测 vp_720_5f 流 [11]=0x18）
        $fwrite(fd, "%c%c", NF[7:0], NF[15:8]);
        $fwrite(fd, "%c%c", CB[7:0], CB[15:8]);
        $fwrite(fd, "%c%c%c%c", 8'h00, 8'h00, 8'h00, 8'h00);
        // 码本：entry i 的字 j = i+j（16b）——像素核对公式依赖此内容
        for (i = 0; i < CB; i = i + 1)
            for (w = 0; w < 16; w = w + 1) begin
                v = (i + w) & 65535;
                $fwrite(fd, "%c%c", v[7:0], v[15:8]);
            end
        // 帧（帧头 5 字节：kind + 3×changed + 保留字节——ixdec S_HDR0..S_HDR4 共吃 5 字节）
        for (f = 0; f < NF; f = f + 1) begin
            $fwrite(fd, "%c", 8'h00);                // kind=KEY
            $fwrite(fd, "%c%c%c%c", 8'h00, 8'h00, 8'h00, 8'h00);
            for (b = 0; b < W*H/16; b = b + 1) begin
                i = (b*11 + f*313) % CB;             // 索引内容（确定性）
                lo = i & 255;
                hi = (i >> 8) & 3;
                $fwrite(fd, "%c", lo[7:0]);
                ch = 8'h00 | hi[1:0];
                $fwrite(fd, "%c", ch);
            end
        end
        $fclose(fd);
        $display("GEN ok %0dx%0d cb=%0d frames=%0d -> %0s", W, H, CB, NF, path);
        $finish;
    end
endmodule
