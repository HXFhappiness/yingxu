# gen_golden.py — YXV2 真实流金标生成器（bboard_sys 文件金标对拍用）
#
# 用法: python tools\sim\gen_golden.py <stream.yxv2> <outdir>
# 输出:
#   <outdir>\idx.mem  — 每帧写入窗的期望索引内容（5 帧 × NB 字, 4 位十六进制/行）
#                       TB 在 region_done[w] 上升沿比对: 第 N 次写窗 w ↔ 帧 2*(N-1)+w
#   <outdir>\fb.mem   — 每帧渲染帧缓冲期望内容（5 帧 × FB_TOTAL 字, 8 位十六进制/行）
#                       TB 在 scan_done 沿比对: 期望 = golden_fb[frm*FB_TOTAL + band*2560 + k]
#   <outdir>\summary.txt — 流结构摘要
#
# 模型与 ixdec/ixbuf RTL 语义对齐:
#   - 索引 = (lo | hi<<8) & 0x3FF（CBSIZE=1024, IW=10, ixdec 取高字节低 2 位）
#   - 帧头 5B: kind(0=KEY 1=DELTA) + changed[3] + 1B; KEY 索引 2B×NB; DELTA bitmap
#     MB=(NB+7)/8 字节（字节内 MSB-first → 块 8m+i）+ 变化索引 2B×changed
#   - 窗口: 帧 f 写窗 f%2; KEY=稠密重写; DELTA=拷贝另一窗 + 稀疏补丁（合并流语义）
#   - 像素: cb_entry[idx][j], j=(row%4)*4+col%4, 行缓冲字={奇像素,偶像素}
import struct
import sys

def main():
    stream = sys.argv[1]
    outdir = sys.argv[2]
    d = open(stream, 'rb').read()

    W = d[7] | d[8] << 8
    H = d[9] | d[10] << 8
    nf = d[12] | d[13] << 8
    cbn = d[14] | d[15] << 8
    assert d[0:4] == b'YXV2', 'magic'
    BW, BH = W // 4, H // 4
    NB = BW * BH
    MB = (NB + 7) // 8
    IW_MASK = 0x3FF          # CBSIZE=1024 → 10 位索引
    FB_WB = 4 * W // 2

    # 码本: cbn 项 × 16 个 16b 字
    o = 20
    cb = []
    for i in range(cbn):
        cb.append(struct.unpack('<16H', d[o:o + 32]))
        o += 32

    # 帧解析 + 窗状态模拟
    wins = [None, None]      # 当前窗状态（None=未写=X）
    idx_lines = []           # 每帧 dst 窗内容
    frames = []
    for f in range(nf):
        fstart = o
        kind = d[o]
        ch = d[o + 1] | d[o + 2] << 8 | d[o + 3] << 16
        o += 5
        dst = f % 2
        src = dst ^ 1
        if kind == 0:
            # KEY 帧头 changed 字段为信息性（ixdec 不使用），不校验
            idxs = []
            for i in range(NB):
                lo = d[o]; hi = d[o + 1]; o += 2
                idxs.append((lo | hi << 8) & IW_MASK)
            wins[dst] = idxs
            kind_s = 'KEY'
        else:
            bitmap = d[o:o + MB]; o += MB
            # 拷贝语义: DELTA 窗 = 另一窗 + 补丁（首帧即 DELTA → 源窗未定义, 金标置 0 并告警）
            base = list(wins[src]) if wins[src] is not None else [0] * NB
            idxs = base
            nchg = 0
            for blk in range(NB):
                if bitmap[blk >> 3] >> (7 - (blk & 7)) & 1:
                    lo = d[o]; hi = d[o + 1]; o += 2
                    idxs[blk] = (lo | hi << 8) & IW_MASK
                    nchg += 1
            assert nchg == ch, 'DELTA changed 计数不符: %d vs %d' % (nchg, ch)
            wins[dst] = idxs
            kind_s = 'DELTA'
        frames.append((kind_s, ch, fstart, o - fstart))
        idx_lines.append(wins[dst])
        assert len(idx_lines[-1]) == NB

    assert o == len(d), '流未耗尽: %d/%d' % (o, len(d))

    # 帧缓冲金标: 帧 f 渲染窗 f%2 = idx_lines[f]
    fb_lines = []
    for f in range(nf):
        idx = idx_lines[f]
        for b in range(BH):
            base_w = b * FB_WB
            for k in range(FB_WB):
                pe_ = 2 * k
                po_ = 2 * k + 1
                re, ce = divmod(pe_, W)
                ro, co = divmod(po_, W)
                blke = b * BW + ce // 4
                blko = b * BW + co // 4
                je = (re % 4) * 4 + ce % 4
                jo = (ro % 4) * 4 + co % 4
                pixe = cb[idx[blke]][je]
                pixo = cb[idx[blko]][jo]
                fb_lines.append((pixo << 16) | pixe)

    with open(outdir + r'\idx.mem', 'w') as fp:
        for wbuf in idx_lines:
            for v in wbuf:
                fp.write('%04x\n' % v)
    with open(outdir + r'\fb.mem', 'w') as fp:
        for v in fb_lines:
            fp.write('%08x\n' % v)

    with open(outdir + r'\summary.txt', 'w') as fp:
        fp.write('stream=%s bytes=%d W=%d H=%d nframe=%d cb=%d NB=%d\n'
                 % (stream, len(d), W, H, nf, cbn, NB))
        for i, (ks, ch, off, ln) in enumerate(frames):
            fp.write(' f%d %s ch=%d off=%d len=%d win=%d\n' % (i, ks, ch, off, ln, i % 2))
    print('GOLDEN-OK frames=%d NB=%d idx_words=%d fb_words=%d'
          % (nf, NB, nf * NB, len(fb_lines)))
    for i, (ks, ch, off, ln) in enumerate(frames):
        print(' f%d %s ch=%d off=%d len=%d' % (i, ks, ch, off, ln))

if __name__ == '__main__':
    main()
