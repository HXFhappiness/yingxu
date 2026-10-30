# -*- coding: utf-8 -*-
# music_telem.py — 解析工具 music_telem.ps1 抓下的遥测原始行，判读 WAV 播放器状态
#
# g28 起，音乐模式(SW4+SW7 ON, SW5/6 OFF)下遥测的卡带调试字段被换成：
#   PC = wav rptr[9:0]                   读指针低 10 位（应递增）
#   DW = pops 累计弹出数                 每秒增量应 ≈ 48000
#   I0 = {sstate[1:0], occ[10:0], wptr[10:0]}
#   RC = 看门狗触发次数
#   I1 = {8'd0, last_L[15:0]}            最近写入 FIFO 的左声道样本（有符号）
#
# 用法: python tools/music_telem.py [out/telem_raw.txt]
import re, sys

path = sys.argv[1] if len(sys.argv) > 1 else r'C:\Users\HXF\Desktop\YX\out\telem_raw.txt'

RE = {
    'pc': re.compile(r'\bPC=([0-9A-Fa-f]{3})'),
    'dw': re.compile(r'\bDW=([0-9A-Fa-f]{4})'),
    'i0': re.compile(r'\bI0=([0-9A-Fa-f]{6})'),
    'rc': re.compile(r'\bRC=([0-9A-Fa-f]{4})'),
    'i1': re.compile(r'\bI1=([0-9A-Fa-f]{6})'),
}

frames = []
try:
    for ln in open(path, encoding='ascii', errors='replace'):
        if 'PC=' not in ln:
            continue
        f = {}
        for k, rx in RE.items():
            m = rx.search(ln)
            if m:
                f[k] = int(m.group(1), 16)
        if len(f) == 5:
            frames.append(f)
except FileNotFoundError:
    sys.exit('找不到 %s —— 先跑 tools\\music_telem.ps1' % path)

if not frames:
    print('文件里没有带 PC= 的帧。确认板子上电、SW7 ON、SW4 ON、SW5/SW6 OFF。')
    sys.exit(1)

def decode(f):
    return ((f['i0'] >> 22) & 3, (f['i0'] >> 11) & 0x7FF, f['i0'] & 0x7FF,
            (f['i1'] & 0xFFFF) - (0x10000 if f['i1'] & 0x8000 else 0))

print('解析到 %d 帧（遥测约每帧 1 次上报）\n' % len(frames))
print('%-5s %-7s %-6s %-5s %-5s %-6s %-7s' % ('idx', 'sstate', 'occ', 'wptr', 'rptr', 'wdog', 'lastL'))
step = max(1, len(frames) // 14)
for i in range(0, len(frames), step):
    f = frames[i]
    ss, occ, wp, ll = decode(f)
    print('%-5d %-7d %-6d %-5d %-5d %-6d %-7d' % (i, ss, occ, wp, f['pc'], f['rc'], ll))

def pd(a, b):
    return (b - a) & 0xFFFF

first, last = frames[0], frames[-1]
n = len(frames) - 1
dwb = pd(first['dw'], last['dw'])
rcb = pd(first['rc'], last['rc'])
ss, occ, wp, ll = decode(last)
# 遥测帧周期未知，用"每帧弹出数"表达；若约 1 帧/秒则数值即样本/秒
print('\n--- 判读 ---')
print('sstate   = %d   (0=找 YXMA 头, 1=播放, 2=结束)' % ss)
print('occ      = %d / 1024    wptr=%d rptr=%d' % (occ, wp, last['pc']))
print('pops     : %d -> %d   共 +%d（%d 帧，平均 %d/帧）' %
      (first['dw'], last['dw'], dwb, n, dwb // max(1, n)))
print('看门狗   : %d -> %d   触发 %d 次' % (first['rc'], last['rc'], rcb))
print('lastL    = %d   (有符号 16bit)' % ll)
vals = set((f['i1'] & 0xFFFF) for f in frames)
print('lastL 取值种类 = %d %s' % (len(vals), '(几乎不变 = 字节流没在走/全零)' if len(vals) <= 2 else '(在变化 = 有样本进来)'))
rp = set(f['pc'] for f in frames)
print('rptr 取值种类  = %d %s' % (len(rp), '(不动 = 没弹出)' if len(rp) <= 1 else '(在推进 = 弹出正常)'))

print()
if ss != 1:
    print('结论: 状态机不在播放态 → 头解析/重启问题')
elif len(rp) <= 1:
    print('结论: 停在 S_PLAY 但 rptr 不动 → 判空/rate_tick 路径问题（输出侧）')
elif len(vals) <= 2 and all(v in (0, 0xFFFF) for v in vals):
    print('结论: 弹出在走但样本恒为 0/饱和 → 进来的是静音数据（查起始扇区与文件内容）')
else:
    print('结论: 弹出与样本都正常 → 问题在混音/HDMI 输出侧')
