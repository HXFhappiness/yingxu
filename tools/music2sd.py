# -*- coding: utf-8 -*-
"""music2sd.py — 把任意音频文件转成映序音乐槽并写入 SD 卡

用法：
  python tools/music2sd.py --in song.mp3 --slot 0 --drive E        # 转格式 + 写卡
  python tools/music2sd.py --in song.mp3 --slot 0 --out out/a.yxm  # 只转格式（不写卡）
  python tools/music2sd.py --drive E --list                        # 查看 4 个槽的内容
  python tools/music2sd.py --in song.mp3 --slot 0 --mono           # 单声道（省一半空间）

做的事：
  1) 调 ffmpeg 把输入转成 48kHz / 16bit / 立体声(或单声道) 裸 PCM
  2) 加 32 字节头 'YXMA'，写成 .yxm
  3) 按固定 LBA 写入 SD 卡（分区偏移自动补偿，与 write_cart.py 一致）

槽布局（板子视角 LBA，每槽 48MB）：
  槽 i = 2_000_000 + i * 98_304 扇区
"""
import argparse, os, struct, subprocess, sys, tempfile

SLOT_BASE = 2_000_000
SLOT_SPAN = 98_304            # 48 MB / 512 = 约 4.2 分钟 48k 立体声
PART_OFF  = 2_048             # FAT32 分区起始（板子 LBA = 物理 - 2048）
MAGIC = b'YXMA'
HDR = 32


def find_ffmpeg():
    p = r'C:\Users\HXF\Desktop\YX\tools\ffmpeg\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe'
    if os.path.exists(p):
        return p
    import glob
    for c in glob.glob(r'C:\Users\HXF\Desktop\YX\tools\ffmpeg*\**\bin\ffmpeg.exe', recursive=True):
        return c
    return 'ffmpeg'


def convert(src, dst, rate=48000, mono=False):
    ff = find_ffmpeg()
    ch = 1 if mono else 2
    cmd = [ff, '-hide_banner', '-loglevel', 'error', '-y', '-i', src,
           '-ar', str(rate), '-ac', str(ch), '-sample_fmt', 's16',
           '-f', 's16le', dst]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    if r.returncode != 0:
        print('ffmpeg 失败:', (r.stderr or '')[-500:])
        return None
    return os.path.getsize(dst)


def build_yxm(pcm_path, out_path, rate=48000, mono=False):
    n = os.path.getsize(pcm_path)
    ch = 1 if mono else 2
    frames = n // (2 * ch)
    hdr = bytearray(HDR)
    hdr[0:4] = MAGIC
    hdr[4] = 1                                  # version
    hdr[5] = ch                                 # channels
    struct.pack_into('<H', hdr, 6, 16)          # bits
    struct.pack_into('<I', hdr, 8, rate)
    struct.pack_into('<I', hdr, 12, frames)
    struct.pack_into('<I', hdr, 16, n)          # pcm bytes
    with open(out_path, 'wb') as f:
        f.write(hdr)
        with open(pcm_path, 'rb') as p:
            while True:
                b = p.read(1 << 20)
                if not b:
                    break
                f.write(b)
    dur = frames / rate
    print(f'已生成 {out_path}: {frames} 帧, {dur:.1f} 秒, {ch} 声道, {rate} Hz, '
          f'{(HDR + n) / 1e6:.2f} MB')
    return HDR + n


def write_slot(drive, slot, data_len, path):
    if not os.path.exists(drive + ':\\'):
        print(f'{drive}: 不存在（卡没插好）')
        return False
    phys = SLOT_BASE + slot * SLOT_SPAN - PART_OFF
    if data_len > SLOT_SPAN * 512:
        print(f'数据 {data_len/1e6:.1f} MB 超过单槽 48 MB，请用 --mono 或切分')
        return False
    import ctypes
    ctypes.windll.kernel32
    k32 = ctypes.WinDLL('kernel32', use_last_error=True)
    k32.CreateFileW.restype = ctypes.c_void_p
    k32.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                                ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32,
                                ctypes.c_void_p]
    Hu = ctypes.c_uint64
    k32.DeviceIoControl.argtypes = [Hu, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32,
                                    ctypes.c_void_p, ctypes.c_uint32,
                                    ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
    k32.SetFilePointer.argtypes = [Hu, ctypes.c_long, ctypes.POINTER(ctypes.c_long), ctypes.c_uint32]
    k32.ReadFile.argtypes = [Hu, ctypes.c_void_p, ctypes.c_uint32,
                             ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
    k32.WriteFile.argtypes = [Hu, ctypes.c_void_p, ctypes.c_uint32,
                              ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
    k32.CloseHandle.argtypes = [Hu]
    FSCTL_LOCK, FSCTL_DISMOUNT = 0x00090018, 0x00090020

    h = k32.CreateFileW('\\\\.\\' + drive + ':', 0xC0000000, 3, None, 3, 0, None)
    if h in (None, 0, 0xFFFFFFFFFFFFFFFF):
        print('打开卷失败（WinError %d）—— 试试管理员权限/拔插' % ctypes.get_last_error())
        return False
    try:
        buf = ctypes.c_ulong(); ret = ctypes.c_ulong()
        if not k32.DeviceIoControl(h, FSCTL_LOCK, None, 0,
                                   ctypes.byref(buf), 4, ctypes.byref(ret), None):
            print('FSCTL_LOCK 失败（资源管理器占用？关闭窗口后拔插重试）')
            return False
        k32.DeviceIoControl(h, FSCTL_DISMOUNT, None, 0, None, 0,
                            ctypes.byref(ret), None)

        lo = ctypes.c_long((phys * 512) & 0xFFFFFFFF)
        hi = ctypes.c_long((phys * 512) >> 32)
        k32.SetFilePointer(h, lo, ctypes.byref(hi), 0)

        with open(path, 'rb') as f:
            data = f.read()
        # 写入长度必须 512 对齐（原始卷句柄要求），补零到整扇区
        nsec = (len(data) + 511) // 512
        data += b'\x00' * (nsec * 512 - len(data))
        written = ctypes.c_ulong(0)
        ok = k32.WriteFile(h, data, len(data), ctypes.byref(written), None)
        if not ok or written.value != len(data):
            print('写入失败 (got %d/%d)' % (written.value, len(data)))
            return False

        # 回读校验：头 + 全量
        lo = ctypes.c_long((phys * 512) & 0xFFFFFFFF)
        hi = ctypes.c_long((phys * 512) >> 32)
        k32.SetFilePointer(h, lo, ctypes.byref(hi), 0)
        rb = ctypes.create_string_buffer(len(data))
        got = ctypes.c_ulong(0)
        if not k32.ReadFile(h, rb, len(data), ctypes.byref(got), None) or got.value != len(data):
            print('回读失败')
            return False
        if rb.raw[:len(data)] != data:
            nd = sum(1 for a, b in zip(rb.raw, data) if a != b)
            print('校验失败：%d 字节不一致' % nd)
            return False
        print(f'已写入并校验槽 {slot}（物理扇区 {phys}），{data_len} 字节（对齐后 {len(data)}）')
        return True
    finally:
        k32.CloseHandle(h)


def list_slots(drive):
    if not os.path.exists(drive + ':\\'):
        print(f'{drive}: 不存在')
        return
    f = open('\\\\.\\' + drive + ':', 'rb')
    try:
        for i in range(4):
            phys = SLOT_BASE + i * SLOT_SPAN - PART_OFF
            f.seek(phys * 512)
            b = f.read(HDR)
            if b[:4] != MAGIC:
                print(f'  槽 {i}: 空')
                continue
            ch = b[5]
            rate = struct.unpack('<I', b[8:12])[0]
            frames = struct.unpack('<I', b[12:16])[0]
            print(f'  槽 {i}: {frames/rate:.1f} 秒, {ch} 声道, {rate} Hz')
    finally:
        f.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--in', dest='src')
    ap.add_argument('--slot', type=int, default=0)
    ap.add_argument('--drive', default='E')
    ap.add_argument('--out')
    ap.add_argument('--mono', action='store_true')
    ap.add_argument('--rate', type=int, default=48000)
    ap.add_argument('--list', action='store_true')
    a = ap.parse_args()
    if a.rate != 48000:
        print('警告: 板上 HDMI 输出固定 48kHz，非 48k 文件走零阶保持重采样，'
              '会引入约 -24dB 的失真（安静段可闻滋滋声）。建议用默认 48000。')

    if a.list:
        list_slots(a.drive)
        return

    if not a.src:
        print(__doc__)
        return

    tmpd = tempfile.mkdtemp()
    pcm = os.path.join(tmpd, 'a.pcm')
    n = convert(a.src, pcm, a.rate, a.mono)
    if n is None:
        return
    out = a.out or os.path.join(tmpd, 'a.yxm')
    total = build_yxm(pcm, out, a.rate, a.mono)

    if a.out:
        print('（--out 模式：只生成文件，未写卡）')
        return
    write_slot(a.drive, a.slot, total, out)


if __name__ == '__main__':
    main()
