# -*- coding: utf-8 -*-
"""vq_view.py — 流式 VQ 解码成 mp4；可与 MJPEG 视频左右并排做同步对比。

用法:
  python vq_view.py --vq a.yxvq --out v.mp4
  python vq_view.py --vq a.yxvq --mjpeg mj.mkv --out cmp.mp4
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


def read_header(path):
    f = open(path, 'rb')
    h = f.read(20)
    assert h[:4] == b'YXVQ', 'not YXVQ'
    w, hh, fps, n = struct.unpack_from('<HHBH', h, 7)
    cb = struct.unpack_from('<H', h, 14)[0]
    book = np.frombuffer(f.read(cb * 32), dtype='<u2').reshape(cb, 16)
    return f, dict(w=w, h=hh, fps=fps, n=n, cb=cb, book=book)


def raw_iter(path, w, h, fps):
    p = subprocess.Popen([FFM, '-v', 'error', '-i', path,
                          '-vf', 'scale=%d:%d:flags=lanczos' % (w, h), '-r', str(fps),
                          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    nb = w * h * 3
    while True:
        b = p.stdout.read(nb)
        if len(b) < nb:
            break
        yield np.frombuffer(b, dtype=np.uint8).reshape(h, w, 3)
    p.stdout.close()
    p.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vq', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--mjpeg', default='')
    ap.add_argument('--crf', default='18')
    a = ap.parse_args()

    f, d = read_header(a.vq)
    w, h, fps, cb = d['w'], d['h'], d['fps'], d['cb']
    idt = np.uint8 if cb <= 256 else np.uint16
    npx = (w // 4) * (h // 4)
    print('YXVQ %dx%d fps=%d cb=%d' % (w, h, fps, cb))

    mj = raw_iter(a.mjpeg, w, h, fps) if a.mjpeg else None
    W = w * 2 + 4 if a.mjpeg else w
    enc = subprocess.Popen([FFM, '-y', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
                            '-s', '%dx%d' % (W, h), '-r', str(fps), '-i', '-',
                            '-c:v', 'libx264', '-preset', 'veryfast', '-crf', a.crf,
                            '-pix_fmt', 'yuv420p', '-movflags', '+faststart', a.out],
                           stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)

    n = 0
    while True:
        buf = f.read(npx * (2 if idt is np.uint16 else 1))
        if len(buf) < npx * (2 if idt is np.uint16 else 1):
            break
        idx = np.frombuffer(buf, dtype=('<u2' if idt is np.uint16 else np.uint8)).reshape(h // 4, w // 4)
        blk = d['book'][idx].reshape(h // 4, w // 4, 4, 4).transpose(0, 2, 1, 3).reshape(h, w)
        rec = from565(blk)
        if mj is not None:
            try:
                ref = next(mj)
            except StopIteration:
                break
            sep = np.full((h, 4, 3), 255, np.uint8)
            frame = np.concatenate([ref, sep, rec], axis=1)
        else:
            frame = rec
        enc.stdin.write(frame.tobytes())
        n += 1
        if n % 600 == 0:
            print('  %d frames' % n, flush=True)

    enc.stdin.close()
    enc.wait()
    f.close()
    print('wrote %s  (%d frames)' % (a.out, n))


if __name__ == '__main__':
    main()
