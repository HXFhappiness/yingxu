; =============================================================================
; breakout.asm — 映序卡带《打砖块》v1
; 目标机: YX-8 (映序自研 8 位处理器)
;
; 玩法: 球自动弹跳，砖块由硬件砖块层渲染 (brick_mask 0xE0-0xE7, 60 bit,
;   10 列 x 6 行, 每格 128x32 屏幕像素, 原点 (0,60))。
;   左键(KEY0)=挡板左移，右键(KEY1)=挡板右移。
;   撞砖: 消砖 + PSG=0；撞板: PSG=1；掉落: PSG=2 重发球；清屏: PSG=3 重开。
;
; 坐标系统（1/4 屏幕单位，显示时 SHLI 2 ×4）:
;   X: 16 位 (bxl 低 / bxh 高)，0..319 → 屏幕 0..1276
;   Y: 8 位，0..179 → 屏幕 0..716
;   砖块带: 游戏 y 15..62；行 = (y-15)/8 (0..5)，列 = x/32 (0..9)
;
; 精灵分配: 槽 0=挡板(120x32, y=680), 槽 2=球(16x16)
; 关键规则: LDR 不设标志！所有状态比较必须用 CMPI。
; =============================================================================
.def bxl     0x00        ; 球 X 低字节 (1/4 单位, 16 位合成 bxh:bxl)
.def bxh     0x01        ; 球 X 高字节 (0..1)
.def by      0x02        ; 球 Y (1/4 单位 0..179)
.def vxl     0x03        ; 球水平速度大小 (1..6, 1/4 单位每帧)
.def vdir    0x04        ; 球水平方向 0=右 1=左
.def vy      0x05        ; 球垂直速度 (8 位有符号, -2/0/+2)
.def pxl     0x06        ; 挡板中心 X 低
.def pxh     0x07        ; 挡板中心 X 高
.def pts      0x08        ; 已消砖计数 0..60
.def bricks  0x09        ; 剩余砖数 0..60
.def serve   0x0A        ; 发球倒计时帧数
.def state   0x0B        ; 0=进行中 1=失败 2=通关
.def bstep   0x0D        ; 球步长切换 (1/2 交替)
.def lives   0x0C        ; 剩余生命 (1..3), SCORE 口显示

.def MASK    0xE0        ; 砖块位图基址 (8 字节, 变址 [MASK+X])
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
.def RAND    0xF4
.def PSG     0xF5
.def SCORE   0xFE

.title "BREAKOUT"
.entry start
.org 0

start:
    JSR init
main:
    LDR  R0, [state]
    CMPI R0, 0
    BNE  main_end
    JSR input
    JSR update
    JSR draw
    WFI
    BRA main
main_end:
    JSR draw_end
    ; v3.8: 结束态按任意键重开
    LDR  R0, [KEYS]
    CMPI R0, 0
    BEQ  me_wait
    JSR  init
me_wait:
    WFI
    BRA main

; -----------------------------------------------------------------------------
init:
    MOVI R0, 0xFF       ; 砖块层全亮: 60 bit = 字节0..6全1 + 字节7低4位
    STR  R0, [MASK+0]
    STR  R0, [MASK+1]
    STR  R0, [MASK+2]
    STR  R0, [MASK+3]
    STR  R0, [MASK+4]
    STR  R0, [MASK+5]
    STR  R0, [MASK+6]
    MOVI R0, 0x0F
    STR  R0, [MASK+7]
    MOVI R0, 60
    STR  R0, [bricks]
    MOVI R0, 0
    STR  R0, [pts]
    MOVI R0, 3
    STR  R0, [lives]    ; 血条 3
    MOVI R0, 0
    STR  R0, [state]
    MOVI R0, 160        ; 挡板中心 160 (屏幕 640 = 1280/2)
    STR  R0, [pxl]
    MOVI R0, 0
    STR  R0, [pxh]
    JSR  serve_ball
    RTS

; 发球: 球贴挡板上方 (不嵌入), 倒计时期间跟随挡板, 结束后向上发射
serve_ball:
    MOVI R0, 166        ; 球底 166*4+16 = 680 = 挡板顶 (贴着, 不重叠)
    STR  R0, [by]
    LDR  R0, [pxl]
    STR  R0, [bxl]
    LDR  R0, [pxh]
    STR  R0, [bxh]
    MOVI R0, 0
    STR  R0, [vy]       ; 倒计时期间球不动
    LDR  R0, [RAND]
    ANDI R0, 0          ; v3.7: 球速 1 -> 4px/帧, 匀速无节流
    ADDI R0, 1
    STR  R0, [vxl]
    LDR  R0, [RAND]
    ANDI R0, 1          ; 随机方向
    STR  R0, [vdir]
    MOVI R0, 120        ; 倒计时 120 帧 (~2 s)
    STR  R0, [serve]
    RTS

; -----------------------------------------------------------------------------
input:
    LDR  R0, [KEYS]
    MOV  R1, R0
    ANDI R1, 1          ; KEY0 → 左移 3 (12 屏幕像素/帧, 全程 ~1.6s)
    BEQ  in_right
    LDR  R1, [pxl]
    LDR  R2, [pxh]
    SUBI R1, 3
    BCS  in_l_low       ; 无借位
    SUBI R2, 1          ; 借位
    BMI  in_l_clamp     ; 高字节 < 0 → 触底
    BRA  in_l_save      ; 借位后仍 >= 256, 必 > 16
in_l_low:
    LDR  R0, [pxh]      ; G5: 下限 16 只约束 16 位中心——pxh>=1 时
    CMPI R0, 0          ;     pxl<16 是合法值，旧代码在此误判导致
    BNE  in_l_save      ;     从右半场左移瞬移到最左
    CMPI R1, 16
    BCS  in_l_save
in_l_clamp:
    MOVI R1, 16         ; 中心下限 16 (左缘不出屏)
    MOVI R2, 0
in_l_save:
    STR  R1, [pxl]
    STR  R2, [pxh]
    BRA  in_right
in_right:
    LDR  R0, [KEYS]
    ANDI R0, 2          ; KEY1 → 右移 3
    BEQ  in_done
    LDR  R1, [pxl]
    LDR  R2, [pxh]
    ADDI R1, 3
    BCC  in_r_chk       ; 无进位
    ADDI R2, 1
in_r_chk:
    CMPI R2, 1
    BCC  in_r_save      ; 高字节 0 → 必 < 304
    BNE  in_r_clamp     ; 高字节 >= 2 → 越界
    CMPI R1, 48         ; 256+48 = 304
    BCC  in_r_save
in_r_clamp:
    MOVI R1, 48
    MOVI R2, 1          ; 中心上限 304 (右缘不出屏)
in_r_save:
    STR  R1, [pxl]
    STR  R2, [pxh]
in_done:
    RTS

; -----------------------------------------------------------------------------
update:
    LDR  R0, [serve]
    CMPI R0, 0
    BEQ  upd_launch
    ; G5: 发球倒计时期间球贴着挡板移动、不做常规运动——
    ;     旧代码此时仍按 vxl 横漂且嵌在挡板里, 观感即"球从板子里冒出来"
    SUBI R0, 1
    STR  R0, [serve]
    LDR  R0, [pxl]
    STR  R0, [bxl]
    LDR  R0, [pxh]
    STR  R0, [bxh]
    RTS
upd_launch:
    LDR  R0, [vy]
    CMPI R0, 0
    BNE  upd_move       ; 已发射 (vy != 0) 不再触发
    MOVI R0, 0xFF       ; v3.7: vy = -1 (向上) 一次性发射
    STR  R0, [vy]
upd_move:
    ; v4.1: 步长 1,1,1,2 循环 -> 平均 1.25 q4 = 5px/帧
    LDR  R2, [bstep]
    ADDI R2, 1
    CMPI R2, 4
    BCC  mv_cnt_ok
    MOVI R2, 0
mv_cnt_ok:
    STR  R2, [bstep]
    MOVI R3, 1                  ; 默认步长 1
    CMPI R2, 3
    BNE  mv_step_ok
    MOVI R3, 2                  ; 第 4 帧步长 2
mv_step_ok:
    MOV  R2, R3                 ; R2 = 本帧步长
    ; ---- 水平: (bxh:bxl) += step * (vdir ? -1 : +1) ----
    LDR  R1, [bxl]
    LDR  R3, [bxh]
    LDR  R4, [vdir]
    CMPI R4, 0
    BNE  mv_left
    ADD  R1, R2
    BCC  mv_st
    ADDI R3, 1
    BRA  mv_st
mv_left:
    SUB  R1, R2
    BCS  mv_st
    SUBI R3, 1
mv_st:
    STR  R1, [bxl]
    STR  R3, [bxh]
    ; ---- 垂直: vy 只表方向(±1), 幅度用本帧步长 ----
    LDR  R1, [by]
    LDR  R4, [vy]
    CMPI R4, 0
    BPL  mv_ydn
    SUB  R1, R2
    BRA  mv_yst
mv_ydn:
    ADD  R1, R2
mv_yst:
    STR  R1, [by]
    JSR  walls
    JSR  bricks_hit
    JSR  paddle_hit
    JSR  lose_chk
    RTS

; -----------------------------------------------------------------------------
walls:
    ; 水平墙: bxh==0 时 xq=bxl. 左: xq<8 且 vdir=1 → 改右 (vx<=6 防回绕)
    ;         右: xq>309 且 vdir=0 → 改左. bxh 异常(>=2 或负) → 拉回
    LDR  R0, [bxh]
    CMPI R0, 0
    BMI  w_oor_l              ; 负 = 越左界 (CMPI 生成 N, 不用 LDR 残标志)
    BEQ  w_lochk
    CMPI R0, 1
    BNE  w_oor_r
    LDR  R1, [bxl]
    CMPI R1, 54               ; 256+54 = 310 > 309
    BCC  w_top
    LDR  R2, [vdir]
    CMPI R2, 0
    BNE  w_top
    MOVI R2, 1
    STR  R2, [vdir]
    BRA  w_top
w_lochk:
    LDR  R1, [bxl]
    CMPI R1, 8
    BCC  w_lhit
    BRA  w_top
w_lhit:
    LDR  R2, [vdir]
    CMPI R2, 1
    BNE  w_top
    MOVI R2, 0
    STR  R2, [vdir]
    BRA  w_top
w_oor_r:
    MOVI R1, 61               ; 拉回 317, 方向改左
    STR  R1, [bxl]
    MOVI R0, 1
    STR  R0, [bxh]
    MOVI R2, 1
    STR  R2, [vdir]
    BRA  w_top
w_oor_l:
    MOVI R1, 2                ; 拉回 2, 方向改右
    STR  R1, [bxl]
    MOVI R0, 0
    STR  R0, [bxh]
    MOVI R2, 0
    STR  R2, [vdir]
w_top:
    ; 顶墙: vy<0 且 by < 13 → 反弹（直接比较, C=1 ⇔ by>=13）
    LDR  R0, [vy]
    CMPI R0, 0
    BPL  w_done         ; LDR 不设标志, 用 CMPI 生成 N
    LDR  R1, [by]
    CMPI R1, 13
    BCS  w_done         ; by >= 13 → 还没到顶, 不反弹
    LDR  R0, [vy]
    NEG  R0
    STR  R0, [vy]
    MOVI R0, 1
    STR  R0, [PSG]
w_done:
    RTS

; -----------------------------------------------------------------------------
; 砖块碰撞: 仅当 vy<0 且 15 <= by < 63
bricks_hit:
    LDR  R0, [vy]
    CMPI R0, 0
    BPL  bh_done        ; 向上才查砖 (LDR 不设标志)
    LDR  R0, [by]
    CMPI R0, 15
    BCC  bh_done
    CMPI R0, 63
    BCS  bh_done
    ; 列 = bxh*8 + (bxl>>5)   (xq/32)
    LDR  R1, [bxh]
    SHLI R1, 3
    LDR  R2, [bxl]
    SHRI R2, 5
    ADD  R1, R2                 ; 列 0..9
    ; 行 = (by-15)>>3          (0..5)
    LDR  R3, [by]
    SUBI R3, 15
    SHRI R3, 3
    ; idx = 行*10 + 列 = 行*8 + 行*2 + 列
    MOV  R4, R3
    SHLI R4, 3
    MOV  R5, R3
    SHLI R5, 1
    ADD  R4, R5
    ADD  R4, R1                 ; idx 0..59
    MOV  R5, R4
    ANDI R5, 7                  ; 位位置 0..7
    SHRI R4, 3                  ; 字节号 0..7
    MOV  R3, R4                 ; X(R3) = 变址字节号
    LDR  R6, [MASK+X]
    MOV  R1, R6
    MOVI R2, 7
    SUB  R2, R5                 ; 7-b
    SHL  R1, R2                 ; 目标位移到 bit7
    BPL  bh_done                ; 该砖已消
    ; 命中: 清位
    MOVI R4, 1
    SHL  R4, R5
    XOR  R6, R4
    STR  R6, [MASK+X]
    ; 反弹 + 计分
    LDR  R0, [vy]
    NEG  R0
    STR  R0, [vy]
    MOVI R0, 4          ; 撞砖音效 = 880Hz 击打音
    STR  R0, [PSG]
    LDR  R0, [pts]
    ADDI R0, 1
    STR  R0, [pts]
    LDR  R0, [bricks]
    SUBI R0, 1
    STR  R0, [bricks]
    BNE  bh_bar
    MOVI R0, 3                  ; 清屏 → 通关
    STR  R0, [PSG]
    MOVI R0, 2
    STR  R0, [state]            ; v3.7: 置通关态, 由 draw_end 画绿块
    RTS
bh_bar:
    ; 记分条 = bricks / 7 (0..8), 减 7 循环
    MOVI R1, 0                  ; R1 = 段数
bh_div:
    CMPI R0, 7
    BCC  bh_div_ok
    SUBI R0, 7
    ADDI R1, 1
    BRA  bh_div
bh_div_ok:
    STR  R1, [SCORE]
bh_done:
    RTS

; -----------------------------------------------------------------------------
; 挡板碰撞: vy>0 且 168 <= by <= 176 且 |bxq - pxq| <= 17
paddle_hit:
    LDR  R0, [vy]
    CMPI R0, 0
    BMI  ph_done        ; 向上不查 (LDR 不设标志)
    BEQ  ph_done        ; 静止 (发球倒计时) 不查
    LDR  R1, [by]
    CMPI R1, 168
    BCC  ph_done
    CMPI R1, 176
    BCS  ph_done
    ; 16 位差: (bxh:bxl) - (pxh:pxl) → (dxh:dxl)
    LDR  R1, [bxl]
    LDR  R2, [pxl]
    SUB  R1, R2                 ; C = 无借位
    MOV  R5, R1                 ; dxl
    LDR  R3, [bxh]
    LDR  R4, [pxh]
    SBC  R3, R4                 ; dxh (含借位)
    BMI  ph_neg
    ; dxh >= 0: 正差, 需 dxh==0 且 dxl <= 17
    CMPI R3, 0
    BNE  ph_done
    CMPI R5, 17
    BCS  ph_done
    BRA  ph_hit
ph_neg:
    ; dxh < 0: 负差, 需 dxh==0xFF 且 dxl >= 256-17 = 239
    CMPI R3, 0xFF
    BNE  ph_done
    CMPI R5, 239
    BCC  ph_done
ph_hit:
    LDR  R0, [vy]
    NEG  R0
    STR  R0, [vy]
    MOVI R0, 1
    STR  R0, [PSG]
ph_done:
    RTS

; -----------------------------------------------------------------------------
lose_chk:
    LDR  R0, [by]
    CMPI R0, 179
    BCC  lc_done
    MOVI R0, 2
    STR  R0, [PSG]
    LDR  R0, [lives]
    SUBI R0, 1
    STR  R0, [lives]
    BEQ  lc_over        ; lives==0 → 游戏结束
    JSR  serve_ball     ; 还有命 → 重新发球
    RTS
lc_over:
    MOVI R0, 3
    STR  R0, [PSG]      ; game over 音
    MOVI R0, 1
    STR  R0, [state]    ; v3.7: 置失败态, 由 draw_end 画红块
    RTS
lc_done:
    RTS

; -----------------------------------------------------------------------------
draw:
    ; ---- 挡板: 槽 0, 120x32, 屏幕 x = pxq*4 - 60, y = 680 ----
    ; 注意: 禁用 R2/R3 (存球坐标), 用 R6 作挡板高位临时
    LDR  R1, [pxl]
    LDR  R6, [pxh]
    MOV  R3, R1
    SHRI R3, 6                  ; 低字节高 2 位 → 高位
    SHLI R1, 2                  ; 低字节
    SHLI R6, 2
    OR   R6, R3                 ; (pxh:pxl)<<2 完成
    SUBI R1, 60                 ; -60
    BCS  pd_nob
    SUBI R6, 1
pd_nob:
    MOVI R0, 1
    STR  R0, [SEN]
    STR  R1, [SXL]
    STR  R6, [SXH]
    MOVI R1, 0xA8               ; 680 = 0x2A8
    STR  R1, [SYL]
    MOVI R1, 2
    STR  R1, [SYH]
    MOVI R1, 120
    STR  R1, [SW]
    MOVI R1, 32
    STR  R1, [SHT]
    MOVI R1, 0xFF
    STR  R1, [SCL]
    STR  R1, [SCH]              ; 白色
    MOVI R1, 0
    STR  R1, [SCOMMIT]
    ; ---- 球: 槽 2, 16x16, 屏幕 x = xq*4 - 8, y = by*4 - 8 ----
    LDR  R1, [bxl]
    LDR  R2, [bxh]
    MOV  R3, R1
    SHRI R3, 6
    SHLI R1, 2
    SHLI R2, 2
    OR   R2, R3                 ; (bxh:bxl)<<2
    SUBI R1, 8                  ; -8
    BCS  bl_nob
    SUBI R2, 1
bl_nob:
    STR  R1, [SXL]
    STR  R2, [SXH]
    LDR  R1, [by]
    MOV  R2, R1
    SHRI R2, 6                  ; by*4 的高字节
    SHLI R1, 2                  ; by*4 的低字节
    SUBI R1, 8                  ; 先减 8（球心补偿），借位进高字节
    BCS  bl_ok
    SUBI R2, 1
bl_ok:
    STR  R1, [SYL]
    STR  R2, [SYH]
    MOVI R1, 16
    STR  R1, [SW]
    STR  R1, [SHT]
    MOVI R1, 0xFF
    STR  R1, [SCL]
    STR  R1, [SCH]              ; 白色
    MOVI R1, 2
    STR  R1, [SCOMMIT]
    ; ---- 血量: 三颗心, 槽 3/4/5, 24x16 红 ----
    MOVI R3, 0
hp_loop:
    LDR  R0, [lives]
    CMP  R3, R0                 ; i - lives; C=0 ⇔ i < lives
    BCC  hp_on
    MOVI R0, 0
    STR  R0, [SEN]
    MOVI R0, 3
    ADD  R0, R3
    STR  R0, [SCOMMIT]
    BRA  hp_next
hp_on:
    MOV  R0, R3
    SHLI R0, 5
    ADDI R0, 16                 ; x = 16 + i*32 (<=80)
    STR  R0, [SXL]
    MOVI R1, 0
    STR  R1, [SXH]
    MOVI R0, 16
    STR  R0, [SYL]
    MOVI R0, 0
    STR  R0, [SYH]
    MOVI R0, 24
    STR  R0, [SW]
    MOVI R0, 16
    STR  R0, [SHT]
    MOVI R0, 0x00
    STR  R0, [SCL]
    MOVI R0, 0xF8                ; 红
    STR  R0, [SCH]
    MOVI R0, 1
    STR  R0, [SEN]
    MOVI R0, 3
    ADD  R0, R3
    STR  R0, [SCOMMIT]
hp_next:
    INC  R3
    CMPI R3, 3
    BCC  hp_loop
    ; 血量也写 SCORE 口（LED 备份显示）
    LDR  R1, [lives]
    STR  R1, [SCORE]
    RTS

; -----------------------------------------------------------------------------
draw_end:
    ; ---- 胜负提示: 4 块 120x60 拼成 240x120 居中色块 ----
    LDR  R0, [state]
    CMPI R0, 1
    BNE  de_win
    MOVI R4, 0x00               ; 红色 = 失败
    MOVI R5, 0xF8
    BRA  de_go
de_win:
    MOVI R4, 0xE0               ; 绿色 = 通关
    MOVI R5, 0x07
de_go:
    MOVI R0, 1
    STR  R0, [SEN]

    MOVI R0, 8
    STR  R0, [SXL]
    MOVI R0, 2
    STR  R0, [SXH]
    MOVI R0, 44
    STR  R0, [SYL]
    MOVI R0, 1
    STR  R0, [SYH]
    MOVI R0, 120
    STR  R0, [SW]
    MOVI R0, 60
    STR  R0, [SHT]
    STR  R4, [SCL]
    STR  R5, [SCH]
    MOVI R0, 2
    STR  R0, [SCOMMIT]
    MOVI R0, 128
    STR  R0, [SXL]
    MOVI R0, 2
    STR  R0, [SXH]
    MOVI R0, 44
    STR  R0, [SYL]
    MOVI R0, 1
    STR  R0, [SYH]
    MOVI R0, 120
    STR  R0, [SW]
    MOVI R0, 60
    STR  R0, [SHT]
    STR  R4, [SCL]
    STR  R5, [SCH]
    MOVI R0, 3
    STR  R0, [SCOMMIT]
    MOVI R0, 8
    STR  R0, [SXL]
    MOVI R0, 2
    STR  R0, [SXH]
    MOVI R0, 104
    STR  R0, [SYL]
    MOVI R0, 1
    STR  R0, [SYH]
    MOVI R0, 120
    STR  R0, [SW]
    MOVI R0, 60
    STR  R0, [SHT]
    STR  R4, [SCL]
    STR  R5, [SCH]
    MOVI R0, 4
    STR  R0, [SCOMMIT]
    MOVI R0, 128
    STR  R0, [SXL]
    MOVI R0, 2
    STR  R0, [SXH]
    MOVI R0, 104
    STR  R0, [SYL]
    MOVI R0, 1
    STR  R0, [SYH]
    MOVI R0, 120
    STR  R0, [SW]
    MOVI R0, 60
    STR  R0, [SHT]
    STR  R4, [SCL]
    STR  R5, [SCH]
    MOVI R0, 5
    STR  R0, [SCOMMIT]
    RTS
