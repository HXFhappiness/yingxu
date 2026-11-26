# -*- coding: utf-8 -*-
"""vq_decode_delta.py — YXVQ v2 差分参考解码器 + 对比视频 + PSNR

流式解码模型（与 RTL 一致）：
  KEY   : 块计数器 0..nb-1 逐块取索引写帧缓冲
  DELTA : 先把 bitmap 收进 map（MSB-first），再流式取索引；
          块 b 的 map bit=1 → 取下一索引写帧缓冲，=0 → 保留上帧块
PSNR 基准 = 源视频经 RGB565 量化（与硬件同精度）。

用法:
  python vq_decode_delta.py --vq out.yxv2 --src in.mp4 --out cmp.mp4 --stills png前缀
"""
import argparse, struct, subprocess

import numpy as np

FFM = r'C:\ffmpeg\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe'


def from565(v):
    v = v.astype(np.uint16)
    r = (((v >> 11) & 0x1F).astype(np.uint16) * 255 // 31).astype(np.uint8)
    g = (((v >> 5) & 0x3F).astype(np.uint16) * 255 // 63).astype(np.uint8)
    b = ((v & 0x1F).astype(np.uint16) * 255 // 31).astype(np.uint8)
    return np.stack([r, g, b], axis=-1)


def to565(rgb):
    r = (rgb[..., 0].astype(np.uint16) >> 3) << 11
    g = (rgb[..., 1].astype(np.uint16) >> 2) << 5
    b = (rgb[..., 2].astype(np.uint16) >> 3)
    return r | g | b


def load(path):
    b = open(path, 'rb').read()
    assert b[:4] == b'YXV2', 'not a YXV2 file'
    ver, blk, flags = b[4], b[5], b[6]
    w, h, fps, n = struct.unpack_from('<HHBH', b, 7)
    cb = struct.unpack_from('<H', b, 14)[0]
    o = 20
    book = np.frombuffer(b, dtype='<u2', count=cb * 16, offset=o).reshape(cb, 16)
    o += cb * 32
    idx_dt = '<u2' if cb > 256 else np.uint8
    nb = (w // 4) * (h // 4)
    mb = (nb + 7) // 8
    return dict(w=w, h=h, fps=fps, cb=cb, book=book, idx_dt=idx_dt, nb=nb, mb=mb, o=o, raw=b)


def decode_all(d, want_raster=False):
    """流式模型逐帧解码 -> (n, h, w) RGB + 每帧统计（want_raster 时同时返回 RGB565 光栅帧）"""
    w, h, nb, mb = d['w'], d['h'], d['nb'], d['mb']
    book, idx_dt, raw, o = d['book'], d['idx_dt'], d['raw'], d['o']
    isize = 2 if idx_dt == '<u2' else 1

    fb = np.zeros((nb, 16), dtype='<u2')     # 帧缓冲：块序 RGB565
    frames = []
    rasters = []
    stats = []
    p = o
    while p < len(raw) and len(frames) < 10 ** 9:
        kind = raw[p]
        changed = int.from_bytes(raw[p+1:p+4], 'little')
        p += 5
        if kind == 0:                        # KEY
            idx = np.frombuffer(raw, dtype=idx_dt, count=nb, offset=p)
            p += nb * isize
            fb = book[idx].astype('<u2').reshape(nb, 16)
        else:                                # DELTA
            mapb = np.frombuffer(raw, dtype=np.uint8, count=mb, offset=p)
            p += mb
            idx = np.frombuffer(raw, dtype=idx_dt, count=changed, offset=p)
            p += changed * isize
            # 展开 MSB-first bitmap
            bits = np.zeros(mb * 8, dtype=np.uint8)
            for i in range(8):
                bits[i::8] = (mapb >> (7 - i)) & 1
            sel = bits[:nb].astype(bool)
            fb[sel] = book[idx].astype('<u2').reshape(-1, 16)
        if kind == 1:
            assert sel.sum() == changed, 'bitmap(%d)/changed(%d) 不一致' % (sel.sum(), changed)
        if want_raster:
            rasters.append(fb.reshape(h // 4, w // 4, 4, 4).transpose(0, 2, 1, 3).reshape(h, w))
        frames.append(from565(fb.reshape(h // 4, w // 4, 4, 4).transpose(0, 2, 1, 3).reshape(h, w)))
        stats.append((kind, changed, (5 + mb + changed * isize) if kind == 1 else (5 + nb * isize)))
    if want_raster:
        return frames, stats, np.stack(rasters)
    return frames, stats


def read_src(src, w, h, fps, n, ss=0.0):
    cmd = [FFM, '-v', 'error']
    if ss:
        cmd += ['-ss', str(ss)]
    cmd += ['-i', src, '-vf', 'scale=%d:%d:flags=lanczos' % (w, h),
            '-r', str(fps), '-frames:v', str(n), '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    p = subprocess.run(cmd, capture_output=True)
    buf = np.frombuffer(p.stdout, dtype=np.uint8)
    n2 = len(buf) // (w * h * 3)
    return buf[:n2 * w * h * 3].reshape(n2, h, w, 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vq', required=True)
    ap.add_argument('--src', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--stills', default='')
    ap.add_argument('--dump', default='', help='输出前缀：.book.hex/.ref.bin（RTL 对拍用）')
    a = ap.parse_args()

    d = load(a.vq)
    w, h, fps = d['w'], d['h'], d['fps']
    print('YXV2 %dx%d fps=%d cb=%d' % (w, h, fps, d['cb']))

    if a.dump:
        # 码本 hex（每项 4 位十六进制，块内像素序）
        with open(a.dump + '.book.hex', 'w') as f:
            for v in d['book'].ravel():
                f.write('%04x\n' % v)
        _, _, rasters = decode_all(d, want_raster=True)
        rasters.astype('>u2').tofile(a.dump + '.ref.bin')   # 大端：TB $fread 按元素 2B 直接对齐
        print('dump: %s.book.hex (%d 项)  %s.ref.bin (%d 帧 x %d px)' % (
            a.dump, d['cb'] * 16, a.dump, len(rasters), w * h))
        return

    frames, stats = decode_all(d)
    n = len(frames)
    print('解码 %d 帧' % n)

    src = read_src(a.src, w, h, fps, n)
    n = min(n, len(src))
    src565 = np.stack([from565(to565(f)) for f in src[:n]])

    se = 0.0
    key_n = sum(1 for s in stats[:n] if s[0] == 0)
    for i in range(n):
        se += float(((frames[i].astype(np.float32) - src565[i].astype(np.float32)) ** 2).sum())
    mse = se / (n * w * h * 3)
    psnr = 10 * np.log10(255.0 ** 2 / max(mse, 1e-9))

    def toy(x):
        x = x.astype(np.float32)
        return 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]
    rec = np.stack(frames[:n])
    my = float(((toy(src565[:n]) - toy(rec)) ** 2).mean())
    ypsnr = 10 * np.log10(255.0 ** 2 / max(my, 1e-9))

    print('PSNR vs RGB565 原图: %.2f dB   Y-PSNR: %.2f dB' % (psnr, ypsnr))
    print('KEY 帧 %d / %d' % (key_n, n))

    W = w * 2 + 4
    sep = np.full((h, 4, 3), 255, np.uint8)
    raw = np.stack([np.concatenate([src565[i], sep, frames[i]], axis=1) for i in range(n)]).tobytes()
    cmd = [FFM, '-y', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
           '-s', '%dx%d' % (W, h), '-r', str(fps), '-i', '-',
           '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18',
           '-pix_fmt', 'yuv420p', a.out]
    p = subprocess.run(cmd, input=raw, capture_output=True)
    if p.returncode != 0:
        raise SystemExit('ffmpeg encode failed: ' + p.stderr.decode('utf-8', 'replace')[:400])
    print('wrote', a.out)

    if a.stills:
        from PIL import Image
        for k, i in enumerate([0, n // 3, n - 1]):
            Image.fromarray(np.concatenate([src565[i], sep, frames[i]], axis=1)).save(
                '%s_%d.png' % (a.stills, k))
        print('stills written')


if __name__ == '__main__':
    main()
