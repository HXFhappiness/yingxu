#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =============================================================================
# yxa.py — YX-8 卡带汇编器 (映序)
# 单文件，零依赖。用法: python yxa.py game.asm game.yxc [--list game.lst]
#
# YX-8: 8 位数据、R0-R7（X=R3 别名）、Z/C/N 标志、定长 24 位指令 [op][A][B]。
# 程序按"字"编址；分支偏移相对 (分支地址+1)。
# .yxc 头: YXCA | ver | flags | entry16 | code_words16 | data_len16 | data_addr8
# =============================================================================
import re, sys, os

REGX = {f'R{i}': i for i in range(8)}
REGX['X'] = 3

ALU_RR = {'ADD':0x10,'ADC':0x11,'SUB':0x12,'SBC':0x13,'AND':0x14,'OR':0x15,
          'XOR':0x16,'CMP':0x17,'SHL':0x18,'SHR':0x19,'ROL':0x1A,'ROR':0x1B,'MOV':0x1C}
ALU_1R = {'INC':0x1D,'DEC':0x1E,'NEG':0x1F}
ALU_IM = {'ADDI':0x20,'ADCI':0x21,'SUBI':0x22,'SBCI':0x23,'ANDI':0x24,'ORI':0x25,
          'XORI':0x26,'CMPI':0x27,'SHLI':0x28,'SHRI':0x29,'MOVI':0x2C,'LDI':0x2C}
MEM_   = {'LDR':0x30,'STR':0x32}          # +1 = 变址形式 [addr+X]
BR_    = {'BEQ':0x40,'BNE':0x41,'BCS':0x42,'BCC':0x43,'BMI':0x44,'BPL':0x45,'BRA':0x46}
JMP_   = {'JMP':0x50,'JSR':0x51}
NIL_   = {'NOP':0x00,'CLC':0x01,'SEC':0x02,'WFI':0x03,'RTS':0x04,'HLT':0x05}

class AsmError(Exception):
    def __init__(self, msg, line=None):
        super().__init__(f"line {line}: {msg}" if line else msg)

def die(msg, line=None):
    raise AsmError(msg, line)

def split_ops(s):
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch in '[(': depth += 1
        if ch in ')]': depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur); cur = ''
        else:
            cur += ch
    if cur.strip() != '' or out:
        out.append(cur)
    return [x.strip() for x in out if x.strip() != '']

class Assembler:
    def __init__(self, text):
        self.lines = text.split('\n')
        self.symbols = {}
        self.cptr = 0
        self.dptr = -1
        self.code = []          # list of dict or None (gaps filled later)
        self.code_map = {}
        self.data = []
        self.data_start = None  # 首个数据字节的地址 → 写入 .yxc 头
        self.data_bytes_by_addr = {}
        self.title = 'YX-CART'
        self.entry = 0
        self.entry_set = False

    # ---- 表达式求值 ----
    def eval(self, expr, line):
        s = expr.strip()
        i = 0
        n = len(s)
        def ws():
            nonlocal i
            while i < n and s[i].isspace(): i += 1
        def factor():
            nonlocal i
            ws()
            if i < n and s[i] == '-':
                i += 1; return -factor()
            if i < n and s[i] == '(':
                i += 1; v = expr_()
                ws()
                if i >= n or s[i] != ')': die(f"missing ')' in '{expr}'", line)
                i += 1; return v
            m = re.match(r'^[A-Za-z_.][\w.]*', s[i:])
            if m:
                tok = m.group(0).upper(); i += len(m.group(0))
                if tok not in self.symbols: die(f"unknown symbol '{tok}'", line)
                return self.symbols[tok]
            m = re.match(r'^(0x[0-9a-fA-F]+|0b[01]+|\d+)', s[i:])
            if m:
                tok = m.group(0); i += len(tok)
                if tok.lower().startswith('0x'): return int(tok, 16)
                if tok.lower().startswith('0b'): return int(tok[2:], 2)
                return int(tok)
            die(f"bad expression '{expr}'", line)
        def term():
            return factor()
        def expr_():
            nonlocal i
            v = term(); ws()
            while i < n and s[i] in '+-':
                op = s[i]; i += 1
                r = term()
                v = v + r if op == '+' else v - r
                ws()
            return v
        v = expr_(); ws()
        if i != n: die(f"junk at end of expression '{expr}'", line)
        return v

    def reg(self, tok, line):
        t = tok.upper()
        if t not in REGX: die(f"expected register, got '{tok}'", line)
        return REGX[t]

    def byte_of(self, v, what, line):
        if v is None or not (-128 <= v <= 255):
            die(f"{what} out of range (-128..255): {v}", line)
        return v & 0xFF

    # ---- 单行处理 ----
    def process(self, raw, idx, emit):
        line = idx + 1
        s = raw.split(';', 1)[0].strip()
        if not s: return
        # 标签（仅第一遍定义；第二遍跳过）
        while True:
            m = re.match(r'^([A-Za-z_]\w*)\s*:\s*', s)
            if not m: break
            if not emit:
                name = m.group(1).upper()
                if name in self.symbols: die(f"duplicate symbol '{name}'", line)
                self.symbols[name] = self.dptr if self.dptr >= 0 else self.cptr
            s = s[m.end():].strip()
        if not s: return

        toks = s.split()
        head = toks[0].upper()
        rest = s[len(toks[0]):].strip()

        # 伪指令
        if head.startswith('.'):
            if head == '.DEF':
                m = re.match(r'^(\w+)\s*,\s*(.+)$', rest)
                if not m:
                    m = re.match(r'^(\w+)\s+(.+)$', rest)
                if not m: die('usage: .def NAME, expr', line)
                self.symbols[m.group(1).upper()] = self.eval(m.group(2), line)
                return
            if head == '.ORG':
                a = self.eval(rest, line)
                if self.dptr >= 0: die('.org inside data section not supported', line)
                self.cptr = a
                return
            if head == '.DATA':
                a = self.eval(rest, line)
                if a > 0xDF: die('data address > 0xDF', line)
                self.dptr = a
                return
            if head == '.BYTE':
                for e in split_ops(rest):
                    v = self.eval(e, line)
                    if emit:
                        b = self.byte_of(v, '.byte value', line)
                        self.data.append(b)
                        if self.data_start is None: self.data_start = self.dptr
                        self.data_bytes_by_addr[self.dptr] = b
                    self.dptr += 1
                return
            if head == '.ASCII':
                m = re.match(r'^"([^"]*)"$', rest)
                if not m: die('usage: .ascii "text"', line)
                for ch in m.group(1):
                    if emit:
                        b = self.byte_of(ord(ch), '.ascii char', line)
                        self.data.append(b)
                        if self.data_start is None: self.data_start = self.dptr
                        self.data_bytes_by_addr[self.dptr] = b
                    self.dptr += 1
                return
            if head == '.TITLE' or head == '.ENTRY':
                if head == '.TITLE':
                    if emit:
                        m = re.match(r'^"([^"]*)"$', rest)
                        if m: self.title = m.group(1)
                else:
                    if emit:
                        self.entry = self.eval(rest, line)
                        self.entry_set = True
                return
            die(f"unknown directive '{head}'", line)

        if head == 'TITLE':
            if emit:
                m = re.match(r'^"([^"]*)"$', rest)
                if m: self.title = m.group(1)
            return
        if head == 'ENTRY':
            if emit:
                self.entry = self.eval(rest, line)
                self.entry_set = True
            return

        ops = split_ops(rest)
        L = line

        def emit_word(op, a, b):
            if emit: self.code_map[self.cptr] = (op, a, b, L, s.strip())
            self.cptr += 1

        if head in NIL_:
            if ops: die(f"{head} takes no operand", L)
            emit_word(NIL_[head], 0, 0); return
        if head in BR_:
            if len(ops) != 1: die(f"{head} needs one label/offset", L)
            if emit:
                target = self.eval(ops[0], L)
                off = target - (self.cptr + 1)
                if not (-128 <= off <= 127): die(f"branch out of range ({off})", L)
                emit_word(BR_[head], 0, off & 0xFF)
            else:
                self.cptr += 1
            return
        if head in JMP_:
            if len(ops) != 1: die(f"{head} needs one target", L)
            if emit:
                t = self.eval(ops[0], L)
                emit_word(JMP_[head], t & 0xFF, 0)
                emit_word(0x00, (t >> 8) & 0xFF, 0)
            else:
                self.cptr += 2
            return
        if head in ALU_RR:
            if len(ops) != 2: die(f"{head} needs dst, src", L)
            emit_word(ALU_RR[head], self.reg(ops[0], L), self.reg(ops[1], L)); return
        if head in ALU_1R:
            if len(ops) != 1: die(f"{head} needs one register", L)
            emit_word(ALU_1R[head], self.reg(ops[0], L), 0); return
        if head in ALU_IM:
            if len(ops) != 2: die(f"{head} needs dst, imm", L)
            r = self.reg(ops[0], L)
            if emit:
                v = self.eval(ops[1], L)
                emit_word(ALU_IM[head], r, self.byte_of(v, 'immediate', L))
            else:
                self.cptr += 1
            return
        if head in MEM_:
            if len(ops) != 2: die(f"{head} needs reg, [addr]", L)
            r = self.reg(ops[0], L)
            maddr = ops[1]
            if not (maddr.startswith('[') and maddr.endswith(']')):
                die(f"memory operand must be bracketed: '{maddr}'", L)
            inner = maddr[1:-1].strip()
            indexed = False
            m2 = re.search(r'(\+|,)\s*X$', inner, re.IGNORECASE)
            if m2:
                indexed = True
                inner = inner[:m2.start()].strip()
            if emit:
                a = self.eval(inner, L)
                emit_word(MEM_[head] + (1 if indexed else 0), r, self.byte_of(a, 'address', L))
            else:
                self.cptr += 1
            return
        die(f"unknown instruction '{head}'", L)

    def assemble(self):
        for i, ln in enumerate(self.lines): self.process(ln, i, emit=False)
        self.cptr = 0; self.dptr = -1
        self.data = []; self.data_start = None; self.data_bytes_by_addr = {}
        for i, ln in enumerate(self.lines): self.process(ln, i, emit=True)
        nwords = (max(self.code_map) + 1) if self.code_map else 0
        self.words = [self.code_map.get(i, (0, 0, 0, 0, '(fill)')) for i in range(nwords)]
        if not self.entry_set: self.entry = 0
        return self

def write_yxc(asm, path):
    data_len = len(asm.data)
    buf = bytearray(0x20 + len(asm.words) * 3 + data_len)
    buf[0:4] = b'YXCA'
    buf[4] = 1                                   # version
    buf[5] = 1 if data_len else 0                # flags: has DATA
    buf[6:8]   = asm.entry.to_bytes(2, 'little')
    buf[8:10]  = len(asm.words).to_bytes(2, 'little')
    buf[10:12] = data_len.to_bytes(2, 'little')
    buf[12]    = (asm.data_start if asm.data_start is not None else 0) & 0xFF
    title = asm.title[:16].encode('ascii', 'replace')
    buf[0x10:0x10+len(title)] = title
    o = 0x20
    for (op, a, b, _L, _s) in asm.words:
        buf[o] = op; buf[o+1] = a; buf[o+2] = b; o += 3
    for b in asm.data:
        buf[o] = b; o += 1
    with open(path, 'wb') as f:
        f.write(bytes(buf))

def write_list(asm, path):
    with open(path, 'w', encoding='utf-8') as f:
        f.write(f"; YX-8 listing — {len(asm.words)} words, data {len(asm.data)} B "
                f"@0x{(asm.data_start or 0):02X}, entry {asm.entry}\n")
        for i, (op, a, b, L, s) in enumerate(asm.words):
            f.write(f"{i:4d}: {op:02X} {a:02X} {b:02X}  | {L:4d} {s}\n")

def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print('usage: python yxa.py in.asm out.yxc [--list out.lst]'); sys.exit(2)
    inp, outp = args[0], args[1]
    lst = args[args.index('--list') + 1] if '--list' in args else None
    try:
        with open(inp, 'r', encoding='utf-8') as f:
            text = f.read()
        asm = Assembler(text).assemble()
    except AsmError as e:
        print(f"yxa: error: {e}"); sys.exit(1)
    write_yxc(asm, outp)
    if lst: write_list(asm, lst)
    ds = asm.data_start or 0
    print(f"yxa: {outp} — {len(asm.words)} words ({len(asm.words)*3} B code), "
          f"{len(asm.data)} B data @0x{ds:02X}, entry={asm.entry}, title=\"{asm.title}\"")

if __name__ == '__main__':
    main()
