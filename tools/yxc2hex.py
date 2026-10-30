#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""yxc2hex.py — .yxc → 仿真 hex 镜像
用法: python yxc2hex.py game.yxc out_dir
产出: out_dir/prog.hex (1024 行 6 位 hex，NOP 补齐)
      out_dir/data.hex (224 行 2 位 hex，DATA 段已按装载地址摆入；无数据则不生成)
"""
import sys, os

def main():
    if len(sys.argv) < 3:
        print('usage: python yxc2hex.py game.yxc out_dir'); sys.exit(2)
    buf = open(sys.argv[1], 'rb').read()
    if buf[0:4] != b'YXCA':
        print('not a .yxc'); sys.exit(1)
    nwords  = int.from_bytes(buf[8:10], 'little')
    datalen = int.from_bytes(buf[10:12], 'little')
    dataaddr= buf[12]
    os.makedirs(sys.argv[2], exist_ok=True)

    # 程序镜像
    with open(os.path.join(sys.argv[2], 'prog.hex'), 'w') as f:
        for i in range(1024):
            if i < nwords:
                o = 0x20 + i * 3
                f.write(f'{buf[o]:02x}{buf[o+1]:02x}{buf[o+2]:02x}\n')
            else:
                f.write('000000\n')

    # 数据镜像（完整 224B RAM 初值）
    if datalen:
        ram = bytearray(224)
        d = buf[0x20 + nwords * 3:]
        for i, b in enumerate(d[:datalen]):
            a = dataaddr + i
            if a < 224:
                ram[a] = b
        with open(os.path.join(sys.argv[2], 'data.hex'), 'w') as f:
            for b in ram:
                f.write(f'{b:02x}\n')
        print(f'yxc2hex: prog={nwords}w, data={datalen}B @0x{dataaddr:02X}')
    else:
        print(f'yxc2hex: prog={nwords}w, no data')

if __name__ == '__main__':
    main()
