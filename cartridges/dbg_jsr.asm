; =============================================================================
; dbg_jsr.asm — 验证 JSR/RTS + dram 写读
;   JSR setpx  -> 子程序把 77 写进 [0x10]
;   LDR 读回   -> 用读回值 * 8 作为精灵 x 坐标
;   读回 = 77   -> 方块出现在屏幕中央偏左 (x≈616)
;   读回 = 0    -> 方块在左上角
; =============================================================================
.def PX      0x10
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

.title "JSRTEST"
.entry start
.org 0

start:
    JSR  setpx
    LDR  R1, [PX]           ; R1 = px（若 JSR/RTS 正常应为 77）
    MOV  R2, R1
    SHRI R2, 5              ; 高位
    SHLI R1, 3              ; 低位 = px*8
    STR  R1, [SXL]
    STR  R2, [SXH]

    MOVI R1, 1
    STR  R1, [SEN]
    MOVI R1, 100
    STR  R1, [SYL]          ; y = 100
    MOVI R1, 0
    STR  R1, [SYH]
    MOVI R1, 120
    STR  R1, [SW]
    MOVI R1, 60
    STR  R1, [SHT]
    MOVI R1, 0xE0           ; 绿色
    STR  R1, [SCL]
    MOVI R1, 0x07
    STR  R1, [SCH]
    MOVI R1, 0
    STR  R1, [SCOM]

loop:
    BRA loop

; ---- 子程序：写 77 到 PX ----
setpx:
    MOVI R0, 77
    STR  R0, [PX]
    RTS
