; =============================================================================
; selftest.asm — 板上 dram 读写自检（结果用颜色表达，一眼可读）
;   读回 == 0x5A -> 绿块；否则 -> 红块
; 生成后用 tools/_rom_from_asm.py 转成 Verilog 组合 ROM
; =============================================================================
.def SEN     0xE8
.def SXL     0xE9
.def SXH     0xEA
.def SYL     0xEB
.def SYH     0xEC
.def SW      0xED
.def SHT     0xEE
.def SCL     0xEF
.def SCH     0xF0
.def SCOM    0xF1
.def TMP     0x20

.title "DRAMTEST"
.entry start
.org 0

start:
    MOVI R1, 0x5A
    STR  R1, [TMP]          ; 写入 dram[0x20]
    LDR  R2, [TMP]          ; 读回
    CMPI R2, 0x5A
    BEQ  good

    ; ---- 读回不对：红色 ----
    MOVI R1, 0x00
    STR  R1, [SCL]
    MOVI R1, 0xF8
    STR  R1, [SCH]
    BRA  setup

good:
    ; ---- 读回正确：绿色 ----
    MOVI R1, 0xE0
    STR  R1, [SCL]
    MOVI R1, 0x07
    STR  R1, [SCH]

setup:
    MOVI R1, 1
    STR  R1, [SEN]          ; en = 1
    MOVI R1, 100
    STR  R1, [SXL]          ; x = 100
    MOVI R1, 0
    STR  R1, [SXH]
    MOVI R1, 100
    STR  R1, [SYL]          ; y = 100
    MOVI R1, 0
    STR  R1, [SYH]
    MOVI R1, 120
    STR  R1, [SW]           ; w = 120
    MOVI R1, 60
    STR  R1, [SHT]          ; h = 60
    MOVI R1, 0
    STR  R1, [SCOM]         ; 提交槽 0

loop:
    BRA loop
