# -*- coding: utf-8 -*-
# write_music.py — 把 YXMA 写进音乐槽（锁卷 + 扇区对齐 IO + 分块写 + 回读校验）
# 用法: python write_music.py --file out\going_home.yxm --slot 0 --drive E
import argparse, ctypes

PART_OFF = 2048
SEC = 512
FSCTL_LOCK_VOLUME = 0x00090018
FSCTL_DISMOUNT_VOLUME = 0x00090020

k32 = ctypes.WinDLL('kernel32', use_last_error=True)
k32.CreateFileW.restype = ctypes.c_void_p
k32.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                            ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32,
                            ctypes.c_void_p]
k32.DeviceIoControl.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p,
                                ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32,
                                ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
k32.SetFilePointer.argtypes = [ctypes.c_void_p, ctypes.c_long,
                               ctypes.POINTER(ctypes.c_long), ctypes.c_uint32]
k32.ReadFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32,
                         ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
k32.WriteFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32,
                          ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]


class Vol:
    def __init__(self, drive, lock=False):
        h = k32.CreateFileW('\\\\.\\' + drive + ':', 0xC0000000, 3, None, 3, 0, None)
        if h in (0, 0xFFFFFFFFFFFFFFFF):
            raise OSError('open volume failed (err=%d)' % k32.GetLastError())
        self.h = h
        self.locked = False
        if lock:
            ret = ctypes.c_uint32(0)
            if not k32.DeviceIoControl(self.h, FSCTL_LOCK_VOLUME, None, 0,
                                       None, 0, ctypes.byref(ret), None):
                raise OSError('FSCTL_LOCK_VOLUME failed (占用中? 拔插重试)')
            k32.DeviceIoControl(self.h, FSCTL_DISMOUNT_VOLUME, None, 0,
                                None, 0, ctypes.byref(ret), None)
            self.locked = True

    def read_sectors(self, lba, nsec):
        buf = ctypes.create_string_buffer(nsec * SEC)
        got = ctypes.c_uint32(0)
        b = lba * SEC
        k32.SetFilePointer(self.h, ctypes.c_long(b & 0xFFFFFFFF),
                           ctypes.byref(ctypes.c_long(b >> 32)), 0)
        ok = k32.ReadFile(self.h, buf, nsec * SEC, ctypes.byref(got), None)
        if not ok or got.value != nsec * SEC:
            raise OSError('read failed @lba %d (err=%d)' % (lba, k32.GetLastError()))
        return buf.raw

    def write_sectors(self, lba, data):
        assert len(data) % SEC == 0
        b = lba * SEC
        k32.SetFilePointer(self.h, ctypes.c_long(b & 0xFFFFFFFF),
                           ctypes.byref(ctypes.c_long(b >> 32)), 0)
        w = ctypes.c_uint32(0)
        ok = k32.WriteFile(self.h, data, len(data), ctypes.byref(w), None)
        if not ok or w.value != len(data):
            raise OSError('write failed @lba %d (err=%d)' % (lba, k32.GetLastError()))

    def close(self):
        k32.CloseHandle(self.h)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', required=True)
    ap.add_argument('--slot', type=int, default=0)
    ap.add_argument('--drive', default='E')
    ap.add_argument('--verify-only', action='store_true')
    a = ap.parse_args()

    data = open(a.file, 'rb').read()
    if len(data) % SEC:
        data += b'\x00' * (SEC - len(data) % SEC)
    nsec = len(data) // SEC

    base = 2_000_000 + a.slot * 98_304          # 板子视角 LBA
    phys = base - PART_OFF                       # 物理扇区
    print('file: %d B -> %d sectors' % (len(data), nsec))
    print('slot %d: board LBA %d, physical %d' % (a.slot, base, phys))

    v = Vol(a.drive, lock=not a.verify_only)
    try:
        hdr = v.read_sectors(32672 - PART_OFF, 1)
        if hdr[:2] != b'BM':
            print('FATAL: partition offset check failed')
            return
        print('partition offset OK (BM @ photo1)')

        if a.verify_only:
            got = v.read_sectors(phys, nsec)
            print('verify:', 'PASS' if got[:len(data)] == data else 'FAIL')
            return

        B = 256
        done = 0
        while done < nsec:
            n = min(B, nsec - done)
            v.write_sectors(phys + done, data[done*SEC:(done+n)*SEC])
            done += n
            if done % 2048 == 0 or done == nsec:
                print('  ... %d/%d sectors' % (done, nsec))
        print('written OK')

        ok = True
        done = 0
        while done < nsec:
            n = min(256, nsec - done)
            got = v.read_sectors(phys + done, n)
            if got[:len(data[done*SEC:(done+n)*SEC])] != data[done*SEC:(done+n)*SEC]:
                print('MISMATCH @ sector', phys + done)
                ok = False
                break
            done += n
        print('read-back:', 'PASS' if ok else 'FAIL')
    finally:
        v.close()


if __name__ == '__main__':
    main()
