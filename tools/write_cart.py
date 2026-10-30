# -*- coding: utf-8 -*-
"""write_cart.py — 把 .yxc 卡带写入 SD 卡固定 LBA（绕过文件系统）

用法:
  python write_cart.py --drive X --cart cartridges\snake.yxc [--lba 1000000] [--verify-only]

原理:
  * 卷句柄 \\\\.\\X: + FSCTL_LOCK_VOLUME 锁定 → 裸扇区写
  * 分区偏移自校验：读卷内 LBA(32672-2048) 应为照片1的 'BM' 头；
    不匹配则尝试常见偏移(2048/63/0)或放弃——绝不盲写
  * 写完后回读比对
"""
import argparse, ctypes, ctypes.wintypes as wt, os, sys, struct

GENERIC_READ  = 0x80000000
GENERIC_WRITE = 0x40000000
FILE_SHARE_READ_WRITE = 0x03
OPEN_EXISTING = 3
FSCTL_LOCK_VOLUME    = 0x00090018
FSCTL_DISMOUNT_VOLUME= 0x00090020
INVALID_HANDLE_VALUE = -1

k32 = ctypes.WinDLL('kernel32', use_last_error=True)
k32.CreateFileW.restype = ctypes.c_void_p
k32.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, ctypes.c_void_p,
                            wt.DWORD, wt.DWORD, ctypes.c_void_p]
# 后续 API 用 c_uint64 而非 c_void_p（避免 ctypes 自动符号扩展导致 OverflowError）
H = ctypes.c_uint64
k32.DeviceIoControl.argtypes = [H, wt.DWORD, ctypes.c_void_p, wt.DWORD,
                                ctypes.c_void_p, wt.DWORD, ctypes.POINTER(wt.DWORD),
                                ctypes.c_void_p]
k32.SetFilePointer.argtypes = [H, wt.LONG, ctypes.POINTER(wt.LONG), wt.DWORD]
k32.ReadFile.argtypes = [H, ctypes.c_void_p, wt.DWORD,
                         ctypes.POINTER(wt.DWORD), ctypes.c_void_p]
k32.WriteFile.argtypes = [H, ctypes.c_void_p, wt.DWORD,
                          ctypes.POINTER(wt.DWORD), ctypes.c_void_p]
k32.CloseHandle.argtypes = [H]

def die(msg):
    print('write_cart: ERROR:', msg)
    sys.exit(1)

class Vol:
    def __init__(self, drv):
        self.h = k32.CreateFileW('\\\\.\\' + drv + ':', GENERIC_READ | GENERIC_WRITE,
                                 FILE_SHARE_READ_WRITE, None, OPEN_EXISTING, 0, None)
        if self.h in (None, INVALID_HANDLE_VALUE, 0):
            die(f'无法打开卷 {drv}: (WinError {ctypes.get_last_error()}) — 试试管理员权限')
        self.locked = False

    def lock(self):
        buf = ctypes.c_ulong()
        ret = ctypes.c_ulong()
        if not k32.DeviceIoControl(self.h, FSCTL_LOCK_VOLUME, None, 0,
                                   ctypes.byref(buf), 4, ctypes.byref(ret), None):
            die('FSCTL_LOCK_VOLUME 失败（资源管理器占用？拔插后重试）')
        k32.DeviceIoControl(self.h, FSCTL_DISMOUNT_VOLUME, None, 0, None, 0,
                            ctypes.byref(ret), None)
        self.locked = True

    def seek(self, lba):
        lo = ctypes.c_long(lba * 512 & 0xFFFFFFFF)
        hi = ctypes.c_long((lba * 512) >> 32)
        r = k32.SetFilePointer(self.h, lo, ctypes.byref(hi), 0)
        if r == 0xFFFFFFFF and ctypes.get_last_error():
            die(f'Seek 失败 @LBA {lba}')

    def read(self, n):
        buf = ctypes.create_string_buffer(n)
        got = ctypes.c_ulong()
        if not k32.ReadFile(self.h, buf, n, ctypes.byref(got), None) or got.value != n:
            die(f'读失败 (got {got.value}/{n})')
        return buf.raw[:n]

    def write(self, data):
        got = ctypes.c_ulong()
        if not k32.WriteFile(self.h, data, len(data), ctypes.byref(got), None) or got.value != len(data):
            die(f'写失败 (got {got.value}/{len(data)})')

    def close(self):
        k32.CloseHandle(self.h)

def find_partition_offset(vol, photo_lba=32672):
    """照片1绝对 LBA 的扇区头应为 'BM'；反推分区起始偏移"""
    for off in (2048, 63, 0, 4096, 8192):
        vol.seek(photo_lba - off)
        sec = vol.read(512)
        if sec[:2] == b'BM':
            return off
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--drive', required=True, help='盘符，如 F')
    ap.add_argument('--cart', default=r'cartridges\snake.yxc')
    ap.add_argument('--lba', type=int, default=1_000_000)
    ap.add_argument('--verify-only', action='store_true')
    a = ap.parse_args()

    data = open(a.cart, 'rb').read()
    nsec = (len(data) + 511) // 512
    padded = data + b'\x00' * (nsec * 512 - len(data))
    print(f'cart: {a.cart} ({len(data)} B, {nsec} 扇区) -> 绝对 LBA {a.lba}')

    v = Vol(a.drive)
    try:
        off = find_partition_offset(v)
        if off is None:
            die('无法校验分区偏移（未在任何常见偏移处找到照片 BMP 头）—— 拒绝盲写')
        print(f'分区偏移 = {off} 扇区（照片1 "BM" 头校验通过）')

        v.lock()
        rel = a.lba - off
        v.seek(rel)
        old = v.read(nsec * 512)
        if old[:4] == b'YXCA':
            print('目标位置已是 YXCA 卡带（覆盖写）')

        if not a.verify_only:
            v.seek(rel)
            v.write(padded)
            print(f'写入 {nsec} 扇区 完成')

        v.seek(rel)
        back = v.read(nsec * 512)
        ok = back == padded
        print('回读校验:', 'PASS ✓' if ok else 'FAIL ✗')
        sys.exit(0 if ok else 1)
    finally:
        v.close()

if __name__ == '__main__':
    main()
