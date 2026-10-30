; =============================================================================
; snake.asm — 映序首发旗舰卡带《贪吃蛇》(SNAKE) v1.2
; 目标机: YX-8 (映序自研 8 位处理器, 工程代号)
;
; v1.2 可玩性修正:
;   初始速度 8→24 帧/步（~0.4s/格），加速下限 3→10
;   食物从 64x16 改为 120x28（几乎占满 128x32 格子，更醒目）
;   其余逻辑不变（砖块位图方案，10×6 网格）
;
; 平台接口(v1.1.2 I/O 映射):
;   0xE0-0xE7 砖块位图 60bit | 0xE8-0xF0 精灵暂存 9B
;   0xF1 精灵提交(写槽号) | 0xF2 按键 | 0xF3 帧计数 | 0xF4 随机数
;   0xF5 PSG音效事件 | 0xF6 系统 | 0xFE 计分条
; =============================================================================

.def MASK    0xE0        ; 砖块位图基址 (8 字节)
.def SEN     0xE8        ; 精灵: 使能
.def SXL     0xE9        ; 精灵: X 低字节
.def SXH     0xEA        ; 精灵: X 高字节
.def SYL     0xEB        ; 精灵: Y 低字节
.def SYH     0xEC        ; 精灵: Y 高字节
.def SW      0xED        ; 精灵: 宽
.def SHT     0xEE        ; 精灵: 高
.def SCL     0xEF        ; 精灵: 颜色 RGB565 低字节
.def SCH     0xF0        ; 精灵: 颜色 RGB565 高字节 (红=F800)
.def SCOMMIT 0xF1        ; 写槽号 → 原子提交
.def KEYS    0xF2
.def FRAME   0xF3
.def RAND    0xF4
.def PSG     0xF5
.def SYS     0xF6
.def SCORE   0xFE

; ---- 数据 RAM 布局 ----
.def body    0x00        ; body[60] 环形缓冲
.def head    0x3C
.def tail    0x3D
.def length  0x3E
.def dir     0x3F        ; 0=+x 1=+y 2=-x 3=-y
.def foodc   0x40
.def timer   0x41
.def intvl   0x42
.def state   0x43        ; 0=运行 1=死亡闪烁 2=等待重开
.def fcnt    0x44
.def col     0x45
.def row     0x46
.def ncol    0x47
.def nrow    0x48
.def ncell   0x49
.def pkeys   0x4A
.def i       0x4B
.def phase   0x4C
.def flashes 0x4D

.def bittab  0x50
.def dxtab   0x58
.def dytab   0x5C

.title "SNAKE"
.entry start
.org 0

start:
    JSR init
main:
    JSR input
    JSR tick
    JSR score_upd
    WFI
    BRA main

init:
    MOVI R0, 0
    STR  R0, [body+0]
    MOVI R0, 1
    STR  R0, [body+1]
    MOVI R0, 2
    STR  R0, [body+2]
    MOVI R0, 2
    STR  R0, [head]
    MOVI R0, 0
    STR  R0, [tail]
    MOVI R0, 3
    STR  R0, [length]
    MOVI R0, 0
    STR  R0, [dir]
    MOVI R0, 2
    STR  R0, [col]
    MOVI R0, 0
    STR  R0, [row]
    MOVI R0, 24
    STR  R0, [intvl]
    STR  R0, [timer]
    MOVI R0, 0
    STR  R0, [state]
    STR  R0, [fcnt]
    STR  R0, [pkeys]
    STR  R0, [phase]
    STR  R0, [flashes]
    JSR clearmask
    MOVI R0, 0
    JSR setbit
    MOVI R0, 1
    JSR setbit
    MOVI R0, 2
    JSR setbit
    MOVI R0, 15
    STR  R0, [foodc]
    JSR drawfood
    RTS

input:
    LDR  R0, [KEYS]
    LDR  R1, [pkeys]
    STR  R0, [pkeys]
    MOV  R2, R0
    XOR  R2, R1
    AND  R2, R0
    MOV  R4, R2
    ANDI R4, 1
    BNE  turn_l
    MOV  R4, R2
    ANDI R4, 2
    BEQ  in_done
    LDR  R5, [dir]
    ADDI R5, 1
    ANDI R5, 3
    STR  R5, [dir]
    BRA  in_done
turn_l:
    LDR  R5, [dir]
    ADDI R5, 3
    ANDI R5, 3
    STR  R5, [dir]
in_done:
    RTS

tick:
    LDR  R0, [state]
    CMPI R0, 1
    BEQ  dying
    CMPI R0, 2
    BEQ  waiting
    LDR  R0, [timer]
    SUBI R0, 1
    STR  R0, [timer]
    BNE  tk_ret
    LDR  R0, [intvl]
    STR  R0, [timer]
    JSR  step
    BRA  tk_ret
dying:
    LDR  R0, [fcnt]
    SUBI R0, 1
    STR  R0, [fcnt]
    BNE  tk_ret
    LDR  R0, [phase]
    XORI R0, 1
    STR  R0, [phase]
    BNE  dy_blank
    JSR  drawfull
    BRA  dy_cnt
dy_blank:
    JSR  clearmask
dy_cnt:
    MOVI R0, 8
    STR  R0, [fcnt]
    LDR  R0, [flashes]
    SUBI R0, 1
    STR  R0, [flashes]
    BNE  tk_ret
    MOVI R0, 2
    STR  R0, [state]
    MOVI R0, 60
    STR  R0, [fcnt]
    BRA  tk_ret
waiting:
    LDR  R0, [fcnt]
    SUBI R0, 1
    STR  R0, [fcnt]
    BNE  tk_ret
    JSR  init
tk_ret:
    RTS

step:
    LDR  R3, [dir]
    LDR  R4, [dxtab+X]
    LDR  R5, [dytab+X]
    LDR  R0, [col]
    ADD  R0, R4
    STR  R0, [ncol]
    BMI  hit_wall
    CMPI R0, 10
    BEQ  hit_wall
    LDR  R0, [row]
    ADD  R0, R5
    STR  R0, [nrow]
    BMI  hit_wall
    CMPI R0, 6
    BEQ  hit_wall
    LDR  R0, [nrow]
    MOV  R1, R0
    SHLI R1, 3
    MOV  R2, R0
    SHLI R2, 1
    ADD  R1, R2
    LDR  R2, [ncol]
    ADD  R1, R2
    STR  R1, [ncell]
    MOVI R0, 0
    STR  R0, [i]
self_lp:
    LDR  R0, [i]
    LDR  R1, [length]
    CMP  R0, R1
    BCS  no_self
    LDR  R2, [tail]
    ADD  R2, R0
    ANDI R2, 0x3F
    CMPI R2, 60
    BCC  sl1
    SUBI R2, 60
sl1:
    MOV  R3, R2
    LDR  R4, [body+X]
    LDR  R5, [ncell]
    CMP  R4, R5
    BEQ  hit_wall
    LDR  R0, [i]
    ADDI R0, 1
    STR  R0, [i]
    BRA  self_lp
no_self:
    LDR  R4, [ncell]
    LDR  R5, [foodc]
    CMP  R4, R5
    BEQ  eat
    JSR  pushhead
    JSR  poptail
    RTS
eat:
    JSR  pushhead
    LDR  R0, [length]
    ADDI R0, 1
    STR  R0, [length]
    LDR  R1, [length]
    SHRI R1, 2
    MOVI R2, 24
    SUB  R2, R1
    CMPI R2, 10
    BCS  spd_ok
    MOVI R2, 10
spd_ok:
    STR  R2, [intvl]
    MOVI R0, 0
    STR  R0, [PSG]
    JSR  spawnfood
    RTS
hit_wall:
    MOVI R0, 1
    STR  R0, [state]
    MOVI R0, 8
    STR  R0, [fcnt]
    MOVI R0, 0
    STR  R0, [phase]
    MOVI R0, 8
    STR  R0, [flashes]
    MOVI R0, 2
    STR  R0, [PSG]
    RTS

pushhead:
    LDR  R0, [head]
    ADDI R0, 1
    ANDI R0, 0x3F
    CMPI R0, 60
    BCC  ph1
    SUBI R0, 60
ph1:
    STR  R0, [head]
    MOV  R3, R0
    LDR  R1, [ncell]
    STR  R1, [body+X]
    MOV  R0, R1
    JSR  setbit
    LDR  R0, [ncol]
    STR  R0, [col]
    LDR  R0, [nrow]
    STR  R0, [row]
    RTS

poptail:
    LDR  R3, [tail]
    LDR  R0, [body+X]
    JSR  clrbit
    LDR  R0, [tail]
    ADDI R0, 1
    ANDI R0, 0x3F
    CMPI R0, 60
    BCC  pt1
    SUBI R0, 60
pt1:
    STR  R0, [tail]
    RTS

setbit:
    MOV  R2, R0
    ANDI R0, 7
    MOV  R3, R0
    LDR  R1, [bittab+X]
    MOV  R0, R2
    SHRI R0, 3
    MOV  R3, R0
    LDR  R4, [MASK+X]
    OR   R4, R1
    STR  R4, [MASK+X]
    RTS

clrbit:
    MOV  R2, R0
    ANDI R0, 7
    MOV  R3, R0
    LDR  R1, [bittab+X]
    XORI R1, 0xFF
    MOV  R0, R2
    SHRI R0, 3
    MOV  R3, R0
    LDR  R4, [MASK+X]
    AND  R4, R1
    STR  R4, [MASK+X]
    RTS

clearmask:
    MOVI R5, 0
cm_lp:
    MOV  R3, R5
    MOVI R0, 0
    STR  R0, [MASK+X]
    ADDI R5, 1
    CMPI R5, 8
    BCC  cm_lp
    RTS

drawfull:
    JSR  clearmask
    MOVI R0, 0
    STR  R0, [i]
df_lp:
    LDR  R0, [i]
    LDR  R1, [length]
    CMP  R0, R1
    BCS  df_done
    LDR  R2, [tail]
    ADD  R2, R0
    ANDI R2, 0x3F
    CMPI R2, 60
    BCC  df1
    SUBI R2, 60
df1:
    MOV  R0, R2
    JSR  setbit
    LDR  R0, [i]
    ADDI R0, 1
    STR  R0, [i]
    BRA  df_lp
df_done:
    RTS

spawnfood:
    LDR  R1, [length]
    CMPI R1, 60
    BEQ  sf_rts
sf_retry:
    LDR  R0, [RAND]
    ANDI R0, 0x3F
    CMPI R0, 60
    BCS  sf_retry
    STR  R0, [foodc]
    MOVI R1, 0
    STR  R1, [i]
sf_lp:
    LDR  R1, [i]
    LDR  R2, [length]
    CMP  R1, R2
    BCS  sf_free
    LDR  R2, [tail]
    ADD  R2, R1
    ANDI R2, 0x3F
    CMPI R2, 60
    BCC  sf1
    SUBI R2, 60
sf1:
    MOV  R3, R2
    LDR  R4, [body+X]
    LDR  R5, [foodc]
    CMP  R4, R5
    BEQ  sf_retry
    LDR  R1, [i]
    ADDI R1, 1
    STR  R1, [i]
    BRA  sf_lp
sf_free:
    JSR  drawfood
sf_rts:
    RTS

drawfood:
    MOVI R0, 1
    STR  R0, [SEN]
    MOVI R0, 120
    STR  R0, [SW]
    MOVI R0, 28
    STR  R0, [SHT]
    MOVI R0, 0x00
    STR  R0, [SCL]
    MOVI R0, 0xF8
    STR  R0, [SCH]
    MOVI R0, 0
    STR  R0, [SYH]
    LDR  R2, [foodc]
    MOVI R4, 0
df_row:
    CMPI R2, 10
    BCC  df_got
    SUBI R2, 10
    ADDI R4, 1
    BRA  df_row
df_got:
    MOV  R5, R2
    ANDI R5, 1
    SHLI R5, 7
    ADDI R5, 4
    STR  R5, [SXL]
    MOV  R5, R2
    SHRI R5, 1
    STR  R5, [SXH]
    MOV  R5, R4
    SHLI R5, 5
    ADDI R5, 66
    STR  R5, [SYL]
    MOVI R0, 0
    STR  R0, [SCOMMIT]
    RTS

score_upd:
    LDR  R0, [length]
    CMPI R0, 8
    BCC  sc1
    MOVI R0, 8
sc1:
    STR  R0, [SCORE]
    RTS

.data 0x50
.byte 1, 2, 4, 8, 16, 32, 64, 128
.byte 1, 0, 255, 0
.byte 0, 1, 255, 0
