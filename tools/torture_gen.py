#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""torture_gen.py — YX-8 随机程序生成器（共生验证压力测试）
用法: python torture_gen.py seed out.asm

生成规则保证两个执行模型始终可比：
  - 只发合法操作码；
  - JSR 仅指向子程序（子程序体为直线代码 + RTS，无嵌套调用/无跳出跳转）
    → 运行时栈深恒平衡，不触发 64 深度回绕差异；
  - JMP/分支目标限于程序内标签（<1024，且不落入双字指令的第二字；
    标签只放在单字指令或双字指令首字前）；
  - STR 禁写 0xF6（系统口 bit7 会停机）；其余地址随意；
  - 尾部 HLT 保证可终止（也可被分支提前命中）。
"""
import random, sys

def main():
    if len(sys.argv) < 3:
        print('usage: python torture_gen.py seed out.asm'); sys.exit(2)
    rng = random.Random(int(sys.argv[1]))
    out_path = sys.argv[2]

    ALU_RR = ['ADD','ADC','SUB','SBC','AND','OR','XOR','CMP','SHL','SHR','ROL','ROR','MOV']
    ALU_IM = ['ADDI','ADCI','SUBI','SBCI','ANDI','ORI','XORI','CMPI','SHLI','SHRI','MOVI']
    BR     = ['BEQ','BNE','BCS','BCC','BMI','BPL','BRA']

    lines = []
    lines.append('.title "TORTURE"')
    lines.append('.entry start')
    lines.append('.org 0')
    lines.append('start:')
    lines.append('    JMP L0')      # 入口直接跳主程序（子程序池在后面，禁止直落）
    lines.append('')

    # 子程序池：直线 + RTS（无 JSR/无分支 → 栈严格平衡）
    lines.append('')
    for s in range(4):
        lines.append(f'SUB{s}:')
        for _ in range(rng.randint(2, 5)):
            lines.append('    ' + rng.choice([
                f'{rng.choice(ALU_RR)} R{rng.randrange(8)}, R{rng.randrange(8)}',
                f'{rng.choice(ALU_IM)} R{rng.randrange(8)}, 0x{rng.randrange(256):02X}',
                f'LDR R{rng.randrange(8)}, [0x{rng.randrange(0x100):02X}]',
                f'LDR R{rng.randrange(8)}, [0x{rng.randrange(0x80):02X}+X]',
            ]))
        lines.append('    RTS')
        lines.append('')

    # 主程序：每块 12 条左右 + 块首标签
    NLABEL = 40
    body = []
    labels = [f'L{k}' for k in range(NLABEL)]
    def rand_addr(exclude_sys=True):
        while True:
            a = rng.randrange(0x100)
            if exclude_sys and a == 0xF6: continue
            return a
    for k in range(NLABEL):
        body.append(f'{labels[k]}:')
        for _ in range(rng.randint(8, 14)):
            r = rng.random()
            if r < 0.30:
                body.append(f'    {rng.choice(ALU_RR)} R{rng.randrange(8)}, R{rng.randrange(8)}')
            elif r < 0.34:
                body.append(f'    {rng.choice(["INC","DEC","NEG"])} R{rng.randrange(8)}')
            elif r < 0.55:
                body.append(f'    {rng.choice(ALU_IM)} R{rng.randrange(8)}, 0x{rng.randrange(256):02X}'
                            if rng.random() < 0.7 else
                            f'    {rng.choice(ALU_IM)} R{rng.randrange(8)}, -{rng.randrange(1,128)}')
            elif r < 0.62:
                body.append(f'    LDR R{rng.randrange(8)}, [0x{rand_addr():02X}]')
            elif r < 0.69:
                body.append(f'    LDR R{rng.randrange(8)}, [0x{rand_addr(False):02X}+X]')
            elif r < 0.78:
                body.append(f'    STR R{rng.randrange(8)}, [0x{rand_addr():02X}]')
            elif r < 0.83:
                body.append(f'    STR R{rng.randrange(8)}, [0x{rand_addr():02X}+X]')
            elif r < 0.93:
                # 分支：目标选邻近标签（±5 块 ≈ ±70 字，留足 ±127 余量）
                lo = max(0, k - 5); hi = min(NLABEL - 1, k + 5)
                body.append(f'    {rng.choice(BR)} {labels[rng.randint(lo, hi)]}')
            elif r < 0.97:
                body.append(f'    JMP {labels[rng.randrange(NLABEL)]}')
            elif r < 0.972:
                body.append('    JMP HALTX')       # 稀有：覆盖 HLT 停机路径
            elif r < 0.985:
                body.append(f'    JSR SUB{rng.randrange(4)}')
            elif r < 0.995:
                body.append('    WFI')
            else:
                body.append(rng.choice(['    NOP', '    CLC', '    SEC']))
    body.append('HALTX:')
    body.append('    HLT')
    # 兜底循环
    body.append(f'{labels[-1]}X:')
    body.append(f'    JMP {labels[0]}')
    body.append('    HLT')
    lines += body

    with open(out_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    print(f'torture_gen: {len(lines)} lines -> {out_path}')

if __name__ == '__main__':
    main()
