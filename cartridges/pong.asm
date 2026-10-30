; =============================================================================
; pong.asm — 映序卡带《PONG》v3（全屏版）
; 目标机: YX-8 (映序自研 8 位处理器)
;
; 玩法: 左板=玩家(KEY0 上 / KEY1 下)，右板=AI。球自动弹跳。
;
; 坐标系统（全屏 1280x720）:
;   游戏坐标 0-255 (X) 和 0-179 (Y)，显示时 SHLI 2（×4）放大
;   → 屏幕覆盖 1020×716（几乎全屏）
;   板: 2 格宽 × 16 格高（屏幕 8×64 像素）
;   球: 2 格 × 2 格（屏幕 8×8 像素）
;
; 精灵分配: 槽 0=左板, 槽 1=右板, 槽 2=球
;
; 关键规则: LDR 不设标志！所有状态比较必须用 CMPI。
; =============================================================================
.def ly      0x00        ; 左板 Y (游戏坐标 0-164, 4 对齐)
.def ry      0x01        ; 右板 Y
.def bx      0x02        ; 球 X (游戏坐标 4-252)
.def by      0x03        ; 球 Y (游戏坐标 4-176)
.def bvx     0x04        ; 球 X 速度（8位有符号：0x01=+1, 0xFF=-1）
.def bvy     0x05        ; 球 Y 速度
.def state   0x06        ; 0=等待 1=对打
.def stimer  0x07
.def pkeys   0x08

.def SEN     0xE8
.def SXL     0xE9
.def SXH     0xEA
.def SYL     0xEB
.def SYH     0xEC
.def SW      0xED
.def SHT     0xEE
.def SCL     0xEF
.def SCH     0xF0
.def SCOMMIT 0xF1
.def KEYS    0xF2
.def PSG     0xF5
.def RAND    0xF4

.title "PONG"
.entry start
.org 0

start:
    JSR init
main:
    JSR input
    JSR update
    JSR draw
    WFI
    BRA main

; -----------------------------------------------------------------------------
init:
    MOVI R0, 44         ; 左板 Y = 44（游戏坐标，×4=176 屏幕，板中心≈208）
    STR  R0, [ly]
    MOVI R0, 44
    STR  R0, [ry]
    MOVI R0, 32         ; 球 X = 32（游戏坐标，×4=128 屏幕）
    STR  R0, [bx]
    MOVI R0, 90         ; 球 Y = 90（游戏坐标，×4=360 屏幕）
    STR  R0, [by]
    MOVI R0, 1
    STR  R0, [bvx]      ; vx = +1（向右）
    MOVI R0, 1
    STR  R0, [bvy]      ; vy = +1（向下）
    MOVI R0, 0
    STR  R0, [state]
    MOVI R0, 90
    STR  R0, [stimer]
    MOVI R0, 0
    STR  R0, [pkeys]
    RTS

; -----------------------------------------------------------------------------
input:
    LDR  R0, [KEYS]
    ; KEY0 → 板上移
    MOV  R1, R0
    ANDI R1, 1
    BEQ  no_up
    LDR  R2, [ly]
    SUBI R2, 4          ; 上移 4 游戏像素（16 屏幕像素）
    BMI  up_clamp       ; < 0 → 限制
    STR  R2, [ly]
    BRA  no_up
up_clamp:
    MOVI R2, 0
    STR  R2, [ly]
no_up:
    ; KEY1 → 板下移
    MOV  R1, R0
    ANDI R1, 2
    BEQ  no_dn
    LDR  R2, [ly]
    ADDI R2, 4
    CMPI R2, 164        ; 最大 Y = 164（164*4+64=720 恰好在屏内）
    BCC  dn_ok
    MOVI R2, 164
dn_ok:
    STR  R2, [ly]
no_dn:
    RTS

; -----------------------------------------------------------------------------
update:
    LDR  R0, [state]
    CMPI R0, 1          ; 显式比较（LDR 不设标志！）
    BNE  serve_wait
    JSR  ball_move
    BRA  upd_done
serve_wait:
    LDR  R0, [stimer]
    SUBI R0, 1
    STR  R0, [stimer]
    BNE  upd_done
    MOVI R0, 1
    STR  R0, [state]
upd_done:
    RTS

; -----------------------------------------------------------------------------
ball_move:
    ; ---- X: bx += bvx（8 位环绕 = 自然有符号） ----
    LDR  R2, [bx]
    LDR  R3, [bvx]
    ADD  R2, R3
    STR  R2, [bx]
    ; 左墙: bx < 6 → 反弹
    CMPI R2, 6          ; C=1 → bx>=6 → 正常
    BCS  bm_nx          ; C=1 → 跳过
    MOVI R2, 6          ; 修正位置
    LDR  R3, [bvx]
    NEG  R3
    STR  R3, [bvx]
    MOVI R0, 1
    STR  R0, [PSG]
bm_nx:
    ; 右墙: bx > 250 → AI 失球 → 重置
    LDR  R2, [bx]
    CMPI R2, 250
    BCC  bm_nx2         ; C=0 → < 250 → 正常
    JSR  reset_ball
    RTS
bm_nx2:

    ; ---- Y: by += bvy ----
    LDR  R2, [by]
    LDR  R3, [bvy]
    ADD  R2, R3
    STR  R2, [by]
    ; 上墙: by < 4 → 反弹
    CMPI R2, 4
    BCS  bm_ny          ; C=1 → >= 4 → 正常
    MOVI R2, 4
    LDR  R3, [bvy]
    NEG  R3
    STR  R3, [bvy]
    BRA  bm_ny2
bm_ny:
    ; 下墙: by > 170 → 反弹
    LDR  R2, [by]
    CMPI R2, 170
    BCC  bm_ny2         ; C=0 → < 170 → 正常
    MOVI R2, 170
    LDR  R3, [bvy]
    NEG  R3
    STR  R3, [bvy]
bm_ny2:

    ; ---- 左板碰撞: bx < 12 且 by 在板范围 ----
    LDR  R2, [bx]
    CMPI R2, 12
    BCS  bm_done        ; C=1 → bx >= 12 → 不碰左板
    LDR  R3, [by]
    LDR  R4, [ly]
    ; 碰撞条件: by >= ly && by <= ly + 16（板高 16 游戏像素）
    SUB  R3, R4         ; R3 = by - ly（8 位环绕）
    ; by < ly → 环绕到 0x80+ → N=1 → 不碰
    BMI  bm_done
    ; by - ly >= 16 → 不碰（CMPI: C=1 → >= 16 → 跳过）
    CMPI R3, 16
    BCS  bm_done
    ; 碰到了! 确保 vx 向右（正）
    LDR  R3, [bvx]
    BMI  bm_done        ; 已经向右（不可能但保险）
    NEG  R3
    STR  R3, [bvx]
    MOVI R0, 1
    STR  R0, [PSG]
bm_done:
    RTS

; -----------------------------------------------------------------------------
reset_ball:
    MOVI R0, 32
    STR  R0, [bx]
    MOVI R0, 90
    STR  R0, [by]
    LDR  R0, [RAND]
    ANDI R0, 1
    ADDI R0, 1          ; |vx| = 1 或 2
    LDR  R1, [RAND]
    ANDI R1, 1
    BNE  rb_neg
    BRA  rb_pos
rb_neg:
    NEG  R0
rb_pos:
    STR  R0, [bvx]
    LDR  R0, [RAND]
    ANDI R0, 1
    ADDI R0, 1
    STR  R0, [bvy]
    MOVI R0, 0
    STR  R0, [state]
    MOVI R0, 90
    STR  R0, [stimer]
    MOVI R0, 2
    STR  R0, [PSG]
    RTS

; -----------------------------------------------------------------------------
draw:                    ; 三个精灵（坐标 SHLI 2 = ×4 放大到全屏）
    ; ---- 左板: 槽 0, 屏幕 X=16, Y=ly*4, 8×64 ----
    MOVI R0, 1
    STR  R0, [SEN]
    MOVI R0, 16
    STR  R0, [SXL]
    MOVI R0, 0
    STR  R0, [SXH]
    LDR  R1, [ly]
    SHLI R1, 2           ; ly × 4
    STR  R1, [SYL]
    MOVI R0, 0
    STR  R0, [SYH]
    MOVI R0, 8
    STR  R0, [SW]
    MOVI R0, 63
    STR  R0, [SHT]
    MOVI R0, 0xE0       ; RGB565 绿
    STR  R0, [SCL]
    MOVI R0, 0x07
    STR  R0, [SCH]
    MOVI R0, 0
    STR  R0, [SCOMMIT]

    ; ---- 右板: 槽 1, 屏幕 X=1208, Y=ry*4 ----
    MOVI R0, 1
    STR  R0, [SEN]
    MOVI R0, 0xB8       ; 1208 & 0xFF = 184
    STR  R0, [SXL]
    MOVI R0, 4          ; 1208 >> 8 = 4
    STR  R0, [SXH]
    LDR  R1, [ry]
    SHLI R1, 2
    STR  R1, [SYL]
    MOVI R0, 0
    STR  R0, [SYH]
    MOVI R0, 8
    STR  R0, [SW]
    MOVI R0, 63
    STR  R0, [SHT]
    MOVI R0, 0xE0
    STR  R0, [SCL]
    MOVI R0, 0x07
    STR  R0, [SCH]
    MOVI R0, 1
    STR  R0, [SCOMMIT]

    ; ---- 球: 槽 2, 屏幕 X=bx*4, Y=by*4, 8×8 ----
    MOVI R0, 1
    STR  R0, [SEN]
    LDR  R1, [bx]
    SHLI R1, 2           ; bx × 4
    STR  R1, [SXL]
    LDR  R1, [bx]
    ANDI R1, 3           ; bx 高 2 位 → SXH（处理 bx*4 的进位）
    ADDI R1, 0           ; bx 范围 4-252 → bx*4 最大 1008 < 256? 不——
    ; bx 最大 252, ×4 = 1008。1008 >> 8 = 3。所以 SXH = bx >> 6
    LDR  R1, [bx]
    SHRI R1, 6           ; bx >> 6 = 高位（0-3）
    STR  R1, [SXH]
    LDR  R1, [by]
    SHLI R1, 2           ; by × 4
    STR  R1, [SYL]
    LDR  R1, [by]
    SHRI R1, 6           ; by >> 6
    STR  R1, [SYH]
    MOVI R0, 8
    STR  R0, [SW]
    MOVI R0, 8
    STR  R0, [SHT]
    MOVI R0, 0xFF       ; RGB565 白
    STR  R0, [SCL]
    MOVI R0, 0xFF
    STR  R0, [SCH]
    MOVI R0, 2
    STR  R0, [SCOMMIT]
    RTS
