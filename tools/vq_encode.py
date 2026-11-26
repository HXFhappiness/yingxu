# -*- coding: utf-8 -*-
"""vq_encode.py — 4x4 VQ 视频编码器（YXVQ v0）

格式:
  magic 'YXVQ' | ver 01 | blk 04 | flags 00 | w u16 | h u16 | fps u8 | nframe u16
  | cbsize u16 | reserved 4B            = 20B 头
  codebook: cbsize * 16 * 2B (RGB565 LE)
  frames:   nframe * (w/4)*(h/4) 字节索引

用法:
  python vq_encode.py --src in.mp4 --out out.yxvq --w 854 --h 480 --fps 24 --frames 48
"""
import argparse, os, struct, subprocess, sys, time

import numpy as np

FFM = r'C:\ffmpeg\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe'


def read_frames(src, w, h, fps, nframes, ss=0.0):
    cmd = [FFM, '-v', 'error']
    if ss:
        cmd += ['-ss', str(ss)]
    cmd += ['-i', src,
            '-vf', 'scale=%d:%d:flags=lanczos' % (w, h),
            '-r', str(fps), '-frames:v', str(nframes),
            '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        raise SystemExit('ffmpeg failed: ' + p.stderr.decode('utf-8', 'replace')[:400])
    buf = np.frombuffer(p.stdout, dtype=np.uint8)
    n = len(buf) // (w * h * 3)
    print('decoded frames:', n)
    return buf[:n * w * h * 3].reshape(n, h, w, 3)


def to565(rgb):
    r = (rgb[..., 0].astype(np.uint16) >> 3) << 11
    g = (rgb[..., 1].astype(np.uint16) >> 2) << 5
    b = (rgb[..., 2].astype(np.uint16) >> 3)
    return (r | g | b).astype(np.uint16)


def from565(v):
    v = v.astype(np.uint16)
    r = (((v >> 11) & 0x1F).astype(np.uint16) * 255 // 31).astype(np.uint8)
    g = (((v >> 5) & 0x3F).astype(np.uint16) * 255 // 63).astype(np.uint8)
    b = ((v & 0x1F).astype(np.uint16) * 255 // 31).astype(np.uint8)
    return np.stack([r, g, b], axis=-1)


def blocks_of(frame):
    """frame: (h,w,3) uint8 -> (nb,48) float32"""
    h, w, _ = frame.shape
    b = frame.reshape(h // 4, 4, w // 4, 4, 3)
    b = b.transpose(0, 2, 1, 3, 4).reshape(-1, 16, 3)
    return b.reshape(-1, 48).astype(np.float32)


def blocks_of565(v565):
    """frame RGB565 (h,w) -> (nb,16) uint16 块，按行优先块序"""
    h, w = v565.shape
    b = v565.reshape(h // 4, 4, w // 4, 4).transpose(0, 2, 1, 3).reshape(-1, 16)
    return b


def pack565(blocks565):
    """(nb,16) uint16 -> (nb,32) uint8 小端"""
    return blocks565.astype('<u2').view(np.uint8).reshape(len(blocks565), 32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--w', type=int, default=854)
    ap.add_argument('--h', type=int, default=480)
    ap.add_argument('--fps', type=int, default=24)
    ap.add_argument('--frames', type=int, default=48)
    ap.add_argument('--ss', type=float, default=0.0)
    ap.add_argument('--cbsize', type=int, default=256)
    ap.add_argument('--train-frames', type=int, default=0, help='0=用全部帧训练')
    a = ap.parse_args()

    if a.w % 4 or a.h % 4:
        raise SystemExit('宽高必须是 4 的倍数')

    t0 = time.time()
    frames = read_frames(a.src, a.w, a.h, a.fps, a.frames, a.ss)
    n, h, w, _ = frames.shape
    print('frames=%d  %dx%d  fps=%d  (%.1fs)' % (n, w, h, a.fps, time.time() - t0))

    v565 = np.stack([to565(f) for f in frames])

    # 训练码本：采样块
    tn = a.train_frames if a.train_frames else n
    sample = []
    for i in range(tn):
        blk = blocks_of(frames[i])
        step = max(1, len(blk) // 3000)
        sample.append(blk[::step])
    sample = np.concatenate(sample, 0)
    print('kmeans samples:', sample.shape)

    from sklearn.cluster import MiniBatchKMeans
    km = MiniBatchKMeans(n_clusters=a.cbsize, batch_size=8192, n_init=3,
                         max_iter=300, random_state=0, verbose=0)
    km.fit(sample)
    cent = km.cluster_centers_.astype(np.float32)          # (cb,48) RGB888
    print('codebook trained (%.1fs)' % (time.time() - t0))

    # 码本量化为 RGB565（与硬件一致）
    cent_rgb = cent.reshape(-1, 16, 3).clip(0, 255).astype(np.uint8)
    cent565 = to565(cent_rgb).reshape(-1, 16)
    cent_use = from565(cent565).reshape(-1, 48).astype(np.float32)   # 用 565 后的值编码

    # 逐帧编码
    idt = np.uint8 if a.cbsize <= 256 else np.uint16
    indices = np.zeros((n, (w // 4) * (h // 4)), dtype=idt)
    se = 0
    for i in range(n):
        blk = blocks_of(frames[i])
        best = np.empty(len(blk), dtype=np.int32)
        bestd = np.empty(len(blk), dtype=np.float32)
        for s in range(0, len(blk), 4096):
            e = min(s + 4096, len(blk))
            d = ((blk[s:e, None, :] - cent_use[None, :, :]) ** 2).sum(-1)
            best[s:e] = d.argmin(1)
            bestd[s:e] = d.min(1)
        indices[i] = best
        se += float(bestd.sum())

    # 统计
    nblk = (w // 4) * (h // 4)
    frame_bytes = nblk * (1 if a.cbsize <= 256 else 2)
    total = 20 + a.cbsize * 32 + n * frame_bytes
    mse = se / (n * w * h * 3)
    psnr = 10 * np.log10(255.0 ** 2 / max(mse, 1e-9))
    print('---')
    print('块数/帧: %d   每帧 %d B   %d 帧共 %.1f KB' % (nblk, frame_bytes, n, total / 1024))
    print('码率: %.2f MB/s @ %dfps' % (frame_bytes * a.fps / 1e6, a.fps))
    print('PSNR: %.2f dB' % psnr)

    # 写文件
    hdr = b'YXVQ' + bytes([1, 4, 0]) + struct.pack('<HHBH', w, h, a.fps, n) + \
          struct.pack('<H', a.cbsize) + b'\x00' * 4
    with open(a.out, 'wb') as f:
        f.write(hdr)
        f.write(pack565(cent565).tobytes())
        f.write(indices.astype('<u2').tobytes() if idt is np.uint16 else indices.tobytes())
    print('wrote', a.out, os.path.getsize(a.out), 'bytes  (%.1fs)' % (time.time() - t0))


if __name__ == '__main__':
    main()
