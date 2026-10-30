#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =============================================================================
# yxem.py — YX-8 卡带模拟器 (映序)
# 指令级解释执行 .yxc，I/O 语义与硬件定义一致（G2 共生验证的参照实现）。
#
# 用法:
#   python yxem.py game.yxc [options]
# 选项:
#   --frames N        运行 N 帧（默认 600）
#   --keys SCRIPT     按键脚本 "23:2,120:1"（帧:键值，保持到下一项）
#   --keys-random P   每帧以概率 P 随机按 0..3 键
#   --dump N          每 N 帧打印状态摘要（0 = 关闭）
#   --seed S          随机种子
#   --trace           逐指令打印（调试）
#   --cosim           确定性模式：按键恒 0、随机数 = 硬件 LFSR、程序补齐 1K 字
#   --goldtrace FILE  共生验证黄金轨迹（与 tb_yx8_cosim.v 输出同格式）
#   --maxinsn N       指令数上限（cosim 用，到数即停）
#
# 帧模型: 每帧从当前 PC 连续执行直到 WFI（或执行上限，防失控）。
# I/O 窗口（v1.1.2 修正版映射，与 CPU RTL 及《贪吃蛇》卡带一致）:
#   0xE0-0xE7 砖块位图(60bit)          0xE8-0xF0 精灵暂存 9B(en,xL,xH,yL,yH,w,h,cL,cH)
#   0xF1 精灵提交(槽号)  0xF2 按键  0xF3 帧计数  0xF4 随机数  0xF5 PSG
#   0xF6 系统(vblank=0x80)  0xFE 计分条
# =============================================================================
import sys, random

TRACE = False
MASK = 0xE0   # brick mask 8B
SEN  = 0xE8   # sprite scratch 9B
SCOM = 0xF1
KEYS = 0xF2
FRM  = 0xF3
RAND = 0xF4
PSG  = 0xF5
SYS  = 0xF6
SCORE= 0xFE

class Cart:
    def __init__(self, path):
        with open(path, 'rb') as f:
            buf = f.read()
        if buf[0:4] != b'YXCA':
            sys.exit('yxem: not a .yxc file')
        self.ver      = buf[4]
        self.flags    = buf[5]
        self.entry    = int.from_bytes(buf[6:8], 'little')
        self.nwords   = int.from_bytes(buf[8:10], 'little')
        self.datalen  = int.from_bytes(buf[10:12], 'little')
        self.dataaddr = buf[12]
        self.title    = buf[0x10:0x20].split(b'\x00')[0].decode('ascii', 'replace')
        o = 0x20
        self.code = []
        for i in range(self.nwords):
            self.code.append((buf[o], buf[o+1], buf[o+2]))
            o += 3
        self.data = buf[o:o + self.datalen]

class Machine:
    def __init__(self, cart, seed=1, cosim=False, gold=None, maxinsn=0):
        self.cart = cart
        self.code = cart.code
        self.cosim = cosim
        self.gold = gold
        self.maxinsn = maxinsn
        if cosim:
            # 与 RTL/程序 RAM 一致：补 NOP 到 1K 字，PC 空间 mod 1024
            self.code = cart.code + [(0, 0, 0)] * (1024 - len(cart.code))
        self.lfsr = 0xAC                  # 与 RTL 相同的硬件随机数（cosim 用）
        self.last_wa = 511
        self.last_wv = 0
        self.ram  = bytearray(0xE0)          # 0x00-0xDF 数据 RAM
        self.io   = bytearray(0x100)         # I/O 窗口
        # DATA 段按 dataaddr 铺进 RAM
        for i, b in enumerate(cart.data):
            a = cart.dataaddr + i
            if a < 0xE0:
                self.ram[a] = b
        self.r = [0] * 8
        self.z = self.c = self.n = 0
        self.pc = cart.entry
        self.stack = []                      # 硬件栈的模拟 (JSR/RTS)
        self.frames = 0
        self.psg_events = []
        self.sprites = [None] * 16
        self.halted = False
        self.wfi_count = 0
        self.insn_count = 0
        self.rng = random.Random(seed)
        self.io[SYS] = 0x00                  # 卡带 0
        self.hist = []                       # 最近指令回溯 (调试观察点用)
        self.transitions = []                # (帧, 旧state, 新state, 长度)

    # ---- 内存访问: 0x00-0xDF RAM, 0xE0-0xFF I/O ----
    def rd(self, a):
        a &= 0xFF
        if a < 0xE0:
            v = self.ram[a]
            import os
            w = os.environ.get('YXEM_WATCH')
            if w is not None and a == int(w, 0):
                print(f"  [watch-rd] f{self.frames} pc={self.pc:4d} R[0x{a:02X}] = 0x{v:02X}")
            return v
        if a == RAND:
            if self.cosim:
                cur = self.lfsr
                fb = (cur ^ (cur >> 2) ^ (cur >> 3) ^ (cur >> 4)) & 1
                self.lfsr = ((cur << 1) | fb) & 0xFF
                return cur
            return self.rng.randrange(256)
        if a == FRM:  return self.frames & 0xFF
        if a == SYS:  return 0x80 | (self.io[SYS] & 0x03)   # vblank=1 + 卡带号
        return self.io[a]

    def wr(self, a, v):
        a &= 0xFF; v &= 0xFF
        self.last_wa = a
        self.last_wv = v
        import os
        w = os.environ.get('YXEM_WATCH')
        if w is not None and a == int(w, 0):
            print(f"  [watch] f{self.frames} pc={self.pc:4d} W[0x{a:02X}] = 0x{v:02X}")
            for (hpc, hop) in reversed(self.hist[-12:]):
                print(f"          <- pc={hpc:4d} op={hop:02X}")
            print(f"          R={self.r} Z{self.z}C{self.c}N{self.n}")
        if a < 0xE0:
            self.ram[a] = v; return
        if 0xE8 <= a <= 0xF1:               # 精灵暂存(9B, 0xE8-0xF0) + 提交(0xF1)
            self.io[a] = v
            if a == SCOM:
                slot = v & 0x0F
                s = self.io[SEN:SEN+9]
                if s[0]:                    # en
                    x = s[1] | (s[2] << 8)
                    y = s[3] | (s[4] << 8)
                    col = s[7] | (s[8] << 8)
                    self.sprites[slot] = (x, y, s[5], s[6], col)
                else:
                    self.sprites[slot] = None
            return
        if a == PSG:
            if v: self.psg_events.append((self.frames, v))
            self.io[a] = v; return
        if a == SYS:
            if v & 0x80: self.halted = True   # 热重启请求（模拟器：停机）
            return
        self.io[a] = v

    # ---- 标志 ----
    def set_zn(self, v):
        v &= 0xFF
        self.z = 1 if v == 0 else 0
        self.n = 1 if v & 0x80 else 0
        return v

    # ---- 单指令 ----
    def step(self):
        pc0 = self.pc
        op, a, b = self.code[pc0]
        self.last_wa = 511
        self.last_wv = 0
        if TRACE:
            print(f"    pc={self.pc:4d} op={op:02X} a={a:02X} b={b:02X} "
                  f"R={self.r} Z{self.z}C{self.c}N{self.n}")
        self.hist.append((self.pc, op))
        if len(self.hist) > 16: self.hist.pop(0)
        self.pc = (self.pc + 1) % len(self.code)
        self.insn_count += 1
        R = self.r

        if   op == 0x00: pass                                    # NOP
        elif op == 0x01: self.c = 0                              # CLC
        elif op == 0x02: self.c = 1                              # SEC
        elif op == 0x03: self._trace(pc0, op, a, b); return 'wfi'   # WFI
        elif op == 0x04:                                         # RTS
            if not self.stack:
                sys.exit(f'yxem: RTS on empty stack @ {self.pc}')
            self.pc = self.stack.pop() % len(self.code)
        elif op == 0x05: self.halted = True                      # HLT

        elif 0x10 <= op <= 0x1C:                                 # ALU RR
            v1, v2 = R[a], R[b]
            self.alu(op - 0x10, a, v1, v2)
        elif 0x1D <= op <= 0x1F:                                 # INC/DEC/NEG
            v1 = R[a]
            v2 = (v1 + 1) if op == 0x1D else (v1 - 1) if op == 0x1E else (-v1)
            R[a] = self.alu_res(v2)
        elif 0x20 <= op <= 0x2C:                                 # ALU imm
            v1, v2 = R[a], b
            if op == 0x2C: R[a] = self.set_zn(b)                 # MOVI/LDI 不影响 C
            else: self.alu(op - 0x20, a, v1, v2)

        elif 0x30 <= op <= 0x33:                                 # LDR/STR
            addr = (b + R[3]) & 0xFF if (op & 1) else b
            if op in (0x30, 0x31): R[a] = self.rd(addr)
            else: self.wr(addr, R[a])

        elif 0x40 <= op <= 0x46:                                 # 分支
            take = False
            if   op == 0x40: take = self.z == 1
            elif op == 0x41: take = self.z == 0
            elif op == 0x42: take = self.c == 1
            elif op == 0x43: take = self.c == 0
            elif op == 0x44: take = self.n == 1
            elif op == 0x45: take = self.n == 0
            elif op == 0x46: take = True
            if take:
                off = b - 256 if b >= 128 else b
                self.pc = (self.pc + off) % len(self.code)

        elif op == 0x50:                                         # JMP 双字
            lo = a; hi = self.code[self.pc][1]
            self.pc = (hi << 8) | lo
            if self.cosim: self.pc &= 0x3FF
        elif op == 0x51:                                         # JSR 双字
            lo = a; hi = self.code[self.pc][1]
            self.stack.append((self.pc + 1) % len(self.code))
            self.pc = (hi << 8) | lo
            if self.cosim: self.pc &= 0x3FF
        else:
            sys.exit(f'yxem: illegal opcode {op:02X} @ {self.pc}')
        self._trace(pc0, op, a, b)

    def _trace(self, pc0, op, a, b):
        """共生验证黄金轨迹：逐指令退休后全状态（与 tb_yx8_cosim.v 输出同格式）"""
        if self.gold is None: return
        r = self.r
        self.gold.write(f"{pc0} {op} {a} {b} "
                        f"{r[0]} {r[1]} {r[2]} {r[3]} {r[4]} {r[5]} {r[6]} {r[7]} "
                        f"{self.z} {self.c} {self.n} {self.last_wa} {self.last_wv}\n")

    def alu(self, sub, a, v1, v2):
        R = self.r
        if   sub == 0:  r = v1 + v2; c = 1 if r > 0xFF else 0     # ADD
        elif sub == 1:  r = v1 + v2 + self.c; c = 1 if r > 0xFF else 0  # ADC
        elif sub == 2:  r = v1 - v2; c = 1 if r >= 0 else 0       # SUB
        elif sub == 3:  r = v1 - v2 - (1 - self.c); c = 1 if r >= 0 else 0  # SBC
        elif sub == 4:  r = v1 & v2; c = self.c
        elif sub == 5:  r = v1 | v2; c = self.c
        elif sub == 6:  r = v1 ^ v2; c = self.c
        elif sub == 7:                                            # CMP/CMPI：只改标志！
            r = v1 - v2
            self.z = 1 if (r & 0xFF) == 0 else 0
            self.n = 1 if r & 0x80 else 0
            self.c = 1 if r >= 0 else 0
            return                                                # 不写回寄存器
        elif sub == 8:                                            # SHL #b
            sh = v2 & 7
            r = (v1 << sh) & 0xFF
            c = ((v1 >> (8 - sh)) & 1) if sh else self.c
        elif sub == 9:                                            # SHR #b
            sh = v2 & 7
            r = (v1 >> sh) & 0xFF
            c = ((v1 >> (sh - 1)) & 1) if sh else self.c
        elif sub == 10:                                           # ROL #b (8位循环, C=移出位)
            sh = v2 & 7
            r = ((v1 << sh) | (v1 >> (8 - sh))) & 0xFF if sh else v1
            c = ((v1 >> (8 - sh)) & 1) if sh else self.c
        elif sub == 11:                                           # ROR #b
            sh = v2 & 7
            r = ((v1 >> sh) | (v1 << (8 - sh))) & 0xFF if sh else v1
            c = ((v1 >> (sh - 1)) & 1) if sh else self.c
        elif sub == 12: r = v2; c = self.c                        # MOV
        else: sys.exit('bad alu')
        R[a] = self.set_zn(r); self.c = c

    def alu_res(self, v2):
        # INC/DEC/NEG: 影响 Z/N, 保留 C（与 RTL 约定一致）
        r = v2 & 0xFF
        self.z = 1 if r == 0 else 0
        self.n = 1 if r & 0x80 else 0
        return r

    # ---- 一帧: 执行到 WFI ----
    def frame(self, keybits):
        if self.maxinsn and self.insn_count >= self.maxinsn:
            return False
        if self.cosim:
            self.io[KEYS] = 0
        else:
            self.io[KEYS] = keybits
        guard = 0
        while True:
            guard += 1
            if guard > 200000 or self.halted:
                return False
            r = self.step()
            if self.maxinsn and self.insn_count >= self.maxinsn:
                return False                  # 指令预算用尽：帧中途精确停
            if r == 'wfi':
                self.frames += 1
                self.wfi_count += 1
                return True

# ---- CLI ----
def main():
    global TRACE
    args = sys.argv[1:]
    if not args:
        print('usage: python yxem.py game.yxc [--frames N] [--keys "f:k,..."] '
              '[--keys-random P] [--dump N] [--seed S] [--trace] '
              '[--cosim --goldtrace FILE --maxinsn N]'); sys.exit(2)
    cart = Cart(args[0])
    frames, dump = 600, 60
    keyscript, keyprob = None, 0.0
    cosim, goldpath, maxinsn = False, None, 0
    i = 1
    while i < len(args):
        if args[i] == '--frames': frames = int(args[i+1]); i += 2
        elif args[i] == '--dump': dump = int(args[i+1]); i += 2
        elif args[i] == '--keys': keyscript = args[i+1]; i += 2
        elif args[i] == '--keys-random': keyprob = float(args[i+1]); i += 2
        elif args[i] == '--cosim': cosim = True; i += 1
        elif args[i] == '--goldtrace': goldpath = args[i+1]; i += 2
        elif args[i] == '--maxinsn': maxinsn = int(args[i+1]); i += 2
        elif args[i] == '--trace': TRACE = True; i += 1
        else: i += 1

    if cosim:
        gold = open(goldpath, 'w') if goldpath else None
        m = Machine(cart, seed=1, cosim=True, gold=gold, maxinsn=maxinsn)
        keyscript, keyprob = None, 0.0
    else:
        m = Machine(cart, seed=1)
        if '--seed' in args:
            m.rng.seed(int(args[args.index('--seed') + 1]))

    print(f"yxem: \"{cart.title}\" v{cart.ver} entry={cart.entry} "
          f"code={cart.nwords}w data={cart.datalen}B@0x{cart.dataaddr:02X}")

    if cosim:
        f = 0
        while f < frames and not m.halted:
            m.frame(0)
            f += 1
        if m.gold: m.gold.close()
        print(f"COSIM-GOLD: insns={m.insn_count} frames={m.frames}")
        sys.exit(0 if m.insn_count > 0 else 1)

    script = {}
    if keyscript:
        for item in keyscript.split(','):
            f, k = item.split(':')
            script[int(f)] = int(k)
    keybits = 0
    ks = sorted(script.items()) if script else []

    hist = {'moves': 0, 'eats': 0, 'deaths': 0, 'restarts': 0}
    state_frames = [0, 0, 0]
    psg_kinds = {0: 0, 1: 0, 2: 0}
    mask_mismatch = 0
    prev_len, prev_state = 3, 0
    f = 0
    while f < frames and not m.halted:
        while ks and ks[0][0] <= f:
            keybits = ks.pop(0)[1]
        if keyprob > 0 and m.rng.random() < keyprob:
            keybits = m.rng.randrange(4)
        m.frame(keybits)
        f += 1
        length = m.ram[0x3E]
        state = m.ram[0x43]
        if length > prev_len: hist['eats'] += 1
        if state != prev_state:
            m.transitions.append((f, prev_state, state, length))
        if state == 1 and prev_state == 0: hist['deaths'] += 1
        if state == 0 and prev_state == 2: hist['restarts'] += 1
        hist['_maxlen'] = max(hist.get('_maxlen', 3), length)
        if state in (0, 1, 2): state_frames[state] += 1
        if state == 0:
            pop = 0
            for byi in range(8):
                pop += bin(m.io[MASK + byi]).count('1')
            if pop != length and pop != length + 1:   # +1: 食物帧的判定窗口
                mask_mismatch += 1
        prev_len, prev_state = length, state
        if TRACE:
            print(f"f{f:5d} pc={m.pc:4d} R={m.r} Z{m.z}C{m.c}N{m.n} keys={keybits} len={length}")
        if dump and f % dump == 0:
            mask = ''.join('1' if m.io[MASK + (j >> 3)] & (1 << (j & 7)) else '.' for j in range(60))
            rows = [mask[r*10:(r+1)*10] for r in range(6)]
            print(f"f{f:5d} len={length:2d} intvl={m.ram[0x42]} state={state} "
                  f"pc={m.pc:4d} insns={m.insn_count}")
            for r in rows: print('     [' + r + ']')

    for _f, ev in m.psg_events:
        psg_kinds[ev] = psg_kinds.get(ev, 0) + 1
    print('--- result ---')
    print(f"frames={f} halted={m.halted} wfi={m.wfi_count} insns={m.insn_count}")
    print(f"state frames: run={state_frames[0]} dying={state_frames[1]} waiting={state_frames[2]}")
    print(f"eats={hist['eats']} deaths={hist['deaths']} restarts={hist['restarts']} "
          f"maxlen={hist.get('_maxlen',3)}")
    print(f"psg: eat={psg_kinds.get(0,0)} init={psg_kinds.get(1,0)} die={psg_kinds.get(2,0)}")
    print(f"transitions ({len(m.transitions)}):")
    for (tf, s0, s1, ln) in m.transitions[:40]:
        print(f"  f{tf:5d}: {s0} -> {s1} (len={ln})")
    print(f"mask/len mismatches in play: {mask_mismatch}")
    print(f"sprites={sum(1 for s in m.sprites if s)} active, score_segments={m.io[SCORE]}")
    alive_ok = state_frames[0] > 100 and hist['eats'] > 0
    ok = (f >= frames) and not m.halted and alive_ok
    print('G1-STATUS: ' + ('PASS' if ok else 'FAIL'))
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
