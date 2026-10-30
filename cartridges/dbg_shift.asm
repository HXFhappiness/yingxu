; =============================================================================
; dbg_shift.asm — 移位指令判官
;   绿色 = SHLI 与 SHRI 都正确（4<<2==16 且 64>>2==16）
;   红色 = 至少一个移位没生效
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

.title "SHIFTTEST"
.entry start
.org 0

start:
    ; ---- SHLI 测试：4 << 2 应等于 16 ----
    MOVI R0, 4
    SHLI R0, 2
    CMPI R0, 16
    BNE  bad

    ; ---- SHRI 测试：64 >> 2 应等于 16 ----
    MOVI R0, 64
    SHRI R0, 2
    CMPI R0, 16
    BNE  bad

    ; ---- 都正确：绿色 ----
    MOVI R1, 0xE0
    STR  R1, [SCL]
    MOVI R1, 0x07
    STR  R1, [SCH]
    BRA  draw

bad:
    ; ---- 失败：红色 ----
    MOVI R1, 0x00
    STR  R1, [SCL]
    MOVI R1, 0xF8
    STR  R1, [SCH]

draw:
    MOVI R1, 1
    STR  R1, [SEN]
    MOVI R1, 100
    STR  R1, [SXL]
    MOVI R1, 0
    STR  R1, [SXH]
    MOVI R1, 100
    STR  R1, [SYL]
    MOVI R1, 0
    STR  R1, [SYH]
    MOVI R1, 120
    STR  R1, [SW]
    MOVI R1, 60
    STR  R1, [SHT]
    MOVI R1, 0
    STR  R1, [SCOM]

loop:
    BRA loop
