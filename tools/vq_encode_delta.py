# -*- coding: utf-8 -*-
"""vq_encode_delta.py — 4x4 VQ 差分视频编码器（YXVQ v2）

v2 帧格式（在 v0 20B 头 + codebook 之后，逐帧）:
  帧头 5B: kind u8 (0=KEY 1=DELTA) | changed u24 LE | rsv u8
  KEY   : nb * idx_bytes        （光栅序全帧索引）
  DELTA : bitmap (nb+7)/8 B     （bit b = 块 b 变化；字节内 MSB-first）
          + changed * idx_bytes （光栅序仅变化块索引）
  idx_bytes = 1 (cbsize<=256) / 2 LE (cbsize>256)

KEY 策略: 首帧 / 每 keyint 帧 / 变化率>cut_th 的切镜头帧。

用法:
  python vq_encode_delta.py --src in.mp4 --out out.yxv2 --w 1280 --h 720 --fps 24 --cbsize 1024
"""
import argparse, os, struct, subprocess, sys, time

import numpy as np

FFM = r'C:\ffmpeg\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe'


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


def pack_bitmap(mask):
    """bool (nb,) -> bytes, 字节内 MSB-first（bit0=块0=字节0的bit7）"""
    nb = len(mask)
    nb_bytes = (nb + 7) // 8
    m = np.zeros(nb_bytes * 8, dtype=np.uint8)
    m[:nb] = mask.astype(np.uint8)
    m = m.reshape(nb_bytes, 8)
    out = np.zeros(nb_bytes, dtype=np.uint8)
    for i in range(8):
        out |= m[:, i] << (7 - i)
    return out.tobytes()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--w', type=int, default=1280)
    ap.add_argument('--h', type=int, default=720)
    ap.add_argument('--fps', type=int, default=24)
    ap.add_argument('--cbsize', type=int, default=1024)
    ap.add_argument('--frames', type=int, default=300)
    ap.add_argument('--keyint', type=int, default=30)
    ap.add_argument('--cut-th', type=float, default=0.80)
    a = ap.parse_args()
    if a.w % 4 or a.h % 4:
        raise SystemExit('宽高必须是 4 的倍数')

    t0 = time.time()
    base = ['-i', a.src]

    nb = (a.w // 4) * (a.h // 4)
    map_bytes = (nb + 7) // 8
    idx_bytes = 2 if a.cbsize > 256 else 1
    print('=== YXVQ v2 差分编码 ===')
    print('%dx%d@%d cb=%d  blocks=%d' % (a.w, a.h, a.fps, a.cbsize, nb))

    # ---- 1) 训练码本（降采样帧）----
    train_args = [FFM, '-v', 'error'] + base + [
        '-vf', 'scale=%d:%d:flags=lanczos,fps=%d' % (a.w, a.h, max(1, a.fps // 6)),
        '-frames:v', '200', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    sample = []
    for fr in frame_iter(train_args, a.w, a.h):
        blk = blocks_of(fr)
        step = max(1, len(blk) // 2000)
        sample.append(blk[::step])
    sample = np.concatenate(sample, 0)

    from sklearn.cluster import MiniBatchKMeans
    km = MiniBatchKMeans(n_clusters=min(a.cbsize, len(sample)), batch_size=8192, n_init=3,
                         max_iter=300, random_state=0)
    km.fit(sample)
    cent = km.cluster_centers_.reshape(-1, 48).astype(np.float32)
    cn = (cent ** 2).sum(1)[None, :]
    cb565 = km.cluster_centers_.reshape(a.cbsize, 4, 4, 3).transpose(0, 1, 2, 3).reshape(a.cbsize, 16, 3)
    # 码本块内像素序：与 blocks_of 一致（行内 4 像素 × 4 行）
    r = (np.clip(cb565[..., 0], 0, 255).astype(np.uint16) >> 3) << 11
    g = (np.clip(cb565[..., 1], 0, 255).astype(np.uint16) >> 2) << 5
    b = (np.clip(cb565[..., 2], 0, 255).astype(np.uint16) >> 3)
    cb565u = (r | g | b).astype('<u2')
    print('codebook 训练完成 (%.1fs)' % (time.time() - t0))

    # ---- 2) 流式编码 ----
    enc_args = [FFM, '-v', 'error'] + base + [
        '-vf', 'scale=%d:%d:flags=lanczos', '-r', str(a.fps),
        '-frames:v', str(a.frames), '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    # 注意 scale 参数单独插入
    enc_args[enc_args.index('scale=%d:%d:flags=lanczos')] = 'scale=%d:%d:flags=lanczos' % (a.w, a.h)

    chunk = 8192
    prev_idx = None
    n = 0
    key_n = delta_n = 0
    total_bytes = 0
    out = open(a.out, 'wb')
    out.write(b'YXV2')
    out.write(bytes([2, 4, 0]))
    out.write(struct.pack('<HHBHH', a.w, a.h, a.fps, 0, a.cbsize))
    out.write(b'\0' * 4)
    out.write(cb565u.tobytes())

    bitrates = []
    for fr in frame_iter(enc_args, a.w, a.h):
        blk = blocks_of(fr)
        idx = np.empty(len(blk), dtype=np.int32)
        for s in range(0, len(blk), chunk):
            e = min(s + chunk, len(blk))
            b2 = blk[s:e]
            d = (b2 ** 2).sum(1)[:, None] + cn - 2.0 * (b2 @ cent.T)
            idx[s:e] = d.argmin(1)

        is_key = prev_idx is None
        if not is_key:
            mask = idx != prev_idx
            changed = int(mask.sum())
            if changed / nb > a.cut_th or n % a.keyint == 0:
                is_key = True
            else:
                maskb = pack_bitmap(mask)
                idxb = idx[mask]
                payload = maskb + (idxb.astype('<u2' if idx_bytes == 2 else np.uint8).tobytes())
                kind, fh = 1, bytes([1]) + changed.to_bytes(3, 'little') + b'\0'
        if is_key:
            changed = nb
            kind, fh = 0, bytes([0]) + nb.to_bytes(3, 'little') + b'\0'
            payload = idx.astype('<u2' if idx_bytes == 2 else np.uint8).tobytes()

        out.write(fh)
        out.write(payload)
        total_bytes += 4 + len(payload)
        bitrates.append((4 + len(payload)) * a.fps)
        key_n += is_key
        delta_n += 1 - is_key
        prev_idx = idx.copy()
        n += 1

    out.close()
    # 回填帧数（流式编码时未知，头部先占位 0）
    with open(a.out, 'r+b') as f:
        f.seek(12)
        f.write(struct.pack('<H', n))
    sz = os.path.getsize(a.out)
    print()
    print('=== 完成 (%d 帧, %.1fs) ===' % (n, time.time() - t0))
    print('KEY 帧 %d  DELTA 帧 %d' % (key_n, delta_n))
    print('文件: %s  %.1f KB  有效码率 %.2f MB/s' % (a.out, sz / 1024,
          (sz - 20 - a.cbsize * 32) / n * a.fps / 1e6))
    print('平均帧码率 %.2f MB/s  最差帧 %.2f MB/s' % (
        np.mean(bitrates) / 1e6, np.max(bitrates) / 1e6))


if __name__ == '__main__':
    main()
