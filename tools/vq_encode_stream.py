# -*- coding: utf-8 -*-
"""vq_encode_stream.py — 流式 VQ 编码器（整片编码，内存恒定）

用法:
  python vq_encode_stream.py --src in.mp4 --out out.yxvq --w 852 --h 480
         --fps 24 --cbsize 1024 [--ss 0] [--dur 0]
"""
import argparse, io, os, struct, subprocess, sys, time

import numpy as np

FFM = r'C:\ffmpeg\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe'


def to565(rgb):
    r = (rgb[..., 0].astype(np.uint16) >> 3) << 11
    g = (rgb[..., 1].astype(np.uint16) >> 2) << 5
    b = (rgb[..., 2].astype(np.uint16) >> 3)
    return r | g | b


def from565(v):
    v = v.astype(np.uint16)
    r = (((v >> 11) & 0x1F).astype(np.uint16) * 255 // 31).astype(np.uint8)
    g = (((v >> 5) & 0x3F).astype(np.uint16) * 255 // 63).astype(np.uint8)
    b = ((v & 0x1F).astype(np.uint16) * 255 // 31).astype(np.uint8)
    return np.stack([r, g, b], axis=-1)


def blocks_of(frame):
    h, w, _ = frame.shape
    b = frame.reshape(h // 4, 4, w // 4, 4, 3)
    b = b.transpose(0, 2, 1, 3, 4).reshape(-1, 16, 3)
    return b.reshape(-1, 48).astype(np.float32)


def frame_iter(ffargs, w, h):
    p = subprocess.Popen(ffargs, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    nbytes = w * h * 3
    while True:
        buf = p.stdout.read(nbytes)
        if len(buf) < nbytes:
            break
        yield np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 3)
    p.stdout.close()
    p.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--w', type=int, default=852)
    ap.add_argument('--h', type=int, default=480)
    ap.add_argument('--fps', type=int, default=24)
    ap.add_argument('--cbsize', type=int, default=1024)
    ap.add_argument('--ss', type=float, default=0.0)
    ap.add_argument('--dur', type=float, default=0.0)
    a = ap.parse_args()
    if a.w % 4 or a.h % 4:
        raise SystemExit('宽高必须是 4 的倍数')

    t0 = time.time()
    base = []
    if a.ss:
        base += ['-ss', str(a.ss)]
    base += ['-i', a.src]
    if a.dur:
        base += ['-t', str(a.dur)]

    # ---- 1) 训练：低帧率采样 ----
    train_args = [FFM] + base + ['-vf', 'scale=%d:%d:flags=lanczos,fps=%d' % (a.w, a.h, max(1, a.fps // 6)),
                         '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    sample = []
    ntrain = 0
    for fr in frame_iter(train_args, a.w, a.h):
        blk = blocks_of(fr)
        step = max(1, len(blk) // 2000)
        sample.append(blk[::step])
        ntrain += 1
        if ntrain >= 200:
            break
    sample = np.concatenate(sample, 0)
    print('train frames=%d  samples=%s' % (ntrain, sample.shape), flush=True)

    from sklearn.cluster import MiniBatchKMeans
    km = MiniBatchKMeans(n_clusters=a.cbsize, batch_size=8192, n_init=3,
                         max_iter=300, random_state=0, verbose=0)
    km.fit(sample)
    cent565 = to565(km.cluster_centers_.reshape(-1, 16, 3).clip(0, 255).astype(np.uint8)).reshape(-1, 16)
    cent = from565(cent565).reshape(-1, 48).astype(np.float32)
    cn = (cent ** 2).sum(1)[None, :]
    print('codebook %d trained (%.1fs)' % (a.cbsize, time.time() - t0), flush=True)

    # ---- 2) 流式编码 ----
    enc_args = [FFM] + base + ['-vf', 'scale=%d:%d:flags=lanczos' % (a.w, a.h),
                       '-r', str(a.fps), '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    idt = np.uint8 if a.cbsize <= 256 else np.uint16
    npx = (a.w // 4) * (a.h // 4)

    hdr = b'YXVQ' + bytes([1, 4, 0]) + struct.pack('<HHBH', a.w, a.h, a.fps, 0) + \
          struct.pack('<H', a.cbsize) + b'\x00' * 4
    f = open(a.out, 'wb')
    f.write(hdr)
    f.write(cent565.astype('<u2').tobytes())

    n = 0
    chunk = 8192
    for fr in frame_iter(enc_args, a.w, a.h):
        blk = blocks_of(fr)
        best = np.empty(len(blk), dtype=np.int32)
        for s in range(0, len(blk), chunk):
            e = min(s + chunk, len(blk))
            b = blk[s:e]
            d = (b ** 2).sum(1)[:, None] + cn - 2.0 * (b @ cent.T)
            best[s:e] = d.argmin(1)
        f.write(best.astype('<u2').tobytes() if idt is np.uint16 else best.astype(np.uint8).tobytes())
        n += 1
        if n % 240 == 0:
            print('  %d frames  (%.0fs)' % (n, time.time() - t0), flush=True)

    f.seek(12)
    f.write(struct.pack('<H', min(n, 65535)))
    f.close()
    sz = os.path.getsize(a.out)
    dur = n / a.fps
    print('done: %d frames  %.1fs  %.2f MB  码率 %.2f MB/s  (%.1fs)'
          % (n, dur, sz / 1e6, sz / max(dur, 1e-9) / 1e6, time.time() - t0))


if __name__ == '__main__':
    main()
