# -*- coding: utf-8 -*-
"""vq_decode.py — YXVQ 参考解码器 + 左右对比视频（原图 | VQ）"""
import argparse, struct, subprocess

import numpy as np

FFM = r'C:\ffmpeg\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe'


def from565(v):
    v = v.astype(np.uint16)
    r = (((v >> 11) & 0x1F).astype(np.uint16) * 255 // 31).astype(np.uint8)
    g = (((v >> 5) & 0x3F).astype(np.uint16) * 255 // 63).astype(np.uint8)
    b = ((v & 0x1F).astype(np.uint16) * 255 // 31).astype(np.uint8)
    return np.stack([r, g, b], axis=-1)


def load(path):
    b = open(path, 'rb').read()
    assert b[:4] == b'YXVQ', 'not a YXVQ file'
    ver, blk, flags = b[4], b[5], b[6]
    w, h, fps, n = struct.unpack_from('<HHBH', b, 7)
    cb = struct.unpack_from('<H', b, 14)[0]
    o = 20
    book = np.frombuffer(b, dtype='<u2', count=cb * 16, offset=o).reshape(cb, 16)
    o += cb * 32
    idt = np.uint8 if cb <= 256 else np.uint16
    nidx = n * (w // 4) * (h // 4)
    idx = np.frombuffer(b, dtype=('<u2' if idt is np.uint16 else np.uint8), count=nidx, offset=o)
    idx = idx.reshape(n, h // 4, w // 4)
    return dict(w=w, h=h, fps=fps, n=n, cb=cb, book=book, idx=idx)


def decode_frame(d, i):
    w, h, book, idx = d['w'], d['h'], d['book'], d['idx'][i]
    blk = book[idx]                              # (h/4, w/4, 16)
    blk = blk.reshape(h // 4, w // 4, 4, 4).transpose(0, 2, 1, 3)
    px = blk.reshape(h, w)
    return from565(px)


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


def to565(rgb):
    r = (rgb[..., 0].astype(np.uint16) >> 3) << 11
    g = (rgb[..., 1].astype(np.uint16) >> 2) << 5
    b = (rgb[..., 2].astype(np.uint16) >> 3)
    return r | g | b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vq', required=True)
    ap.add_argument('--src', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--stills', default='')
    ap.add_argument('--ss', type=float, default=0.0)
    a = ap.parse_args()

    d = load(a.vq)
    w, h, n = d['w'], d['h'], d['n']
    print('YXVQ %dx%d  fps=%d  frames=%d  cb=%d' % (w, h, d['fps'], n, d['cb']))

    src = read_src(a.src, w, h, d['fps'], n, a.ss)
    n = min(n, len(src))
    d['n'] = n

    # 参考基准：原图经 RGB565 量化（与硬件同精度），公平对比
    src565 = np.stack([from565(to565(f)) for f in src[:n]])

    frames = []
    se = 0.0
    for i in range(n):
        rec = decode_frame(d, i)
        ref = src565[i]
        se += float(((rec.astype(np.float32) - ref.astype(np.float32)) ** 2).sum())
        sep = np.full((h, 4, 3), 255, np.uint8)
        frames.append(np.concatenate([ref, sep, rec], axis=1))
    mse = se / (n * w * h * 3)
    psnr = 10 * np.log10(255.0 ** 2 / max(mse, 1e-9))
    # Y-PSNR（BT.601，与 ffmpeg 的 y 通道可比）
    def toy(x):
        x = x.astype(np.float32)
        return 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]
    ys, yr = toy(src565[:n]), toy(np.stack([decode_frame(d, i) for i in range(n)]))
    my = float(((ys - yr) ** 2).mean())
    ypsnr = 10 * np.log10(255.0 ** 2 / max(my, 1e-9))
    print('PSNR vs RGB565 原图: %.2f dB   Y-PSNR: %.2f dB' % (psnr, ypsnr))

    W = w * 2 + 4
    raw = np.stack(frames).tobytes()
    cmd = [FFM, '-y', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
           '-s', '%dx%d' % (W, h), '-r', str(d['fps']), '-i', '-',
           '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18',
           '-pix_fmt', 'yuv420p', a.out]
    p = subprocess.run(cmd, input=raw, capture_output=True)
    if p.returncode != 0:
        raise SystemExit('ffmpeg encode failed: ' + p.stderr.decode('utf-8', 'replace')[:400])
    print('wrote', a.out)

    if a.stills:
        for k, i in enumerate([0, n // 3, 2 * n // 3]):
            from PIL import Image
            Image.fromarray(frames[i]).save('%s_%d.png' % (a.stills, k))
        print('stills written')


if __name__ == '__main__':
    main()
