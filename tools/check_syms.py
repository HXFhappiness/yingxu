# -*- coding: utf-8 -*-
"""check_syms.py — 检查 .asm 里大小写归一后撞名的符号

yxa 会把所有符号转大写，所以 `BSPD` 和 `bspd` 是同一个符号，后者覆盖前者。
这类 bug 极隐蔽：汇编不报错，运行到某处才表现为"读到的值是别的变量"。

用法: python tools/check_syms.py cartridges/*.asm
"""
import sys, re, glob, os

DEF = re.compile(r'^\s*\.def\s+(\w+)\s+(.+)', re.I)
LAB = re.compile(r'^\s*(\w+)\s*:')


def check(path):
    seen = {}       # upper -> [(orig, value, line)]
    for n, line in enumerate(open(path, encoding='utf-8', errors='replace'), 1):
        m = DEF.match(line)
        if m:
            name, val = m.group(1), m.group(2).split(';')[0].strip()
            seen.setdefault(name.upper(), []).append((name, val, n))
    bad = {k: v for k, v in seen.items() if len({x[0] for x in v}) > 1}
    if bad:
        print(f'{os.path.basename(path)}: {len(bad)} 组撞名')
        for k, v in bad.items():
            for name, val, n in v:
                print(f'   {k:12s} <- {name:12s} = {val:10s} (行 {n})')
    else:
        print(f'{os.path.basename(path)}: 无撞名 ✓')
    return len(bad)


def main():
    args = sys.argv[1:] or glob.glob(r'C:\Users\HXF\Desktop\YX\cartridges\*.asm')
    total = 0
    for p in args:
        total += check(p)
    print()
    print('合计撞名组数:', total)


if __name__ == '__main__':
    main()
