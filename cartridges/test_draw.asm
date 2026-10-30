; =============================================================================
; test_draw.asm — 最小 CPU/IO 通路自检卡带
; 只做一件事：提交一个 200x100 的青色精灵到槽 3，然后死循环
; 用于把"CPU+程序RAM+IO 通路"与"游戏程序逻辑"彻底切开
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

.title "TESTDRAW"
.entry start
.org 0

start:
    MOVI R0, 1
    STR  R0, [SEN]      ; en = 1
    MOVI R0, 100
    STR  R0, [SXL]      ; x = 100
    MOVI R0, 0
    STR  R0, [SXH]
    MOVI R0, 100
    STR  R0, [SYL]      ; y = 100
    MOVI R0, 0
    STR  R0, [SYH]
    MOVI R0, 200
    STR  R0, [SW]       ; w = 200
    MOVI R0, 100
    STR  R0, [SHT]      ; h = 100
    MOVI R0, 0xFF
    STR  R0, [SCL]      ; color = 0x07FF cyan
    MOVI R0, 0x07
    STR  R0, [SCH]
    MOVI R0, 3
    STR  R0, [SCOM]     ; commit slot 3

loop:
    BRA loop
