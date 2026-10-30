; =============================================================================
; invaders.asm — 映序卡带《宇宙流浪者》v3
; 目标机: YX-8 (映序自研 8 位处理器)
;
; v3 规格: 3 种敌型 × 每型 2 架 = 6 架。
;   绿队(上):  每 4 帧走 1 步, 炸弹速度 1 q8/帧 —— 慢速坦克
;   黄队(中):  每 3 帧走 1 步, 炸弹速度 2 q8/帧 —— 中速
;   红队(下):  每 2 帧走 1 步, 炸弹速度 3 q8/帧 —— 快速杀手
;   各队独立左右漂移+撞边下压; 炮台 1 q8/帧 (可控)。
;   自动开火 (冷却 45 帧); 中弹扣命 (3 命); 命尽或任意队压到 y>=64 → 重开;
;   全灭 → PSG3 + 队形重置。
;
; 坐标: 1/8 屏幕单位 (q8), 显示时 SHLI 3。屏幕 160x90 q8。
;   敌机 3x2 q8, 队内间距 7; 炮台 6x2, y=84; 弹 1x2; 炸弹 1x2。
; 数据布局: 每架一份 SX/SY (小队坐标按架复制, 绕开单变址寄存器限制),
;   队级 TDIR/TTICK/DIV/BSPD 按 3 项存。
; 关键规则: LDR 不设标志! 比较前必须 CMPI。ADD/SUB 的 C=进位/无借位。
; =============================================================================
.def ALIVE   0x00        ; alive[0..5]
.def SX      0x06        ; 每架 x (SX[2t]=SX[2t+1]=队 x)
.def SY      0x0C        ; 每架 y
.def TDIR    0x12        ; 队方向 [6] 每架复制 (0=右 1=左)
.def TTICK   0x18        ; 队移动分频计数 [6] 每架复制
.def DIV     0x1E        ; 队速度分频 [6] = 3/3/2/2/1/1
.def BSPD    0x24        ; 队炸弹速度 [6] = 1/1/2/2/3/3
.def px      0x2A        ; 炮台左上 xq
.def bx      0x2F        ; 子弹 xq
.def by      0x30        ; 子弹 yq
.def bactive 0x31
.def mx      0x32        ; 炸弹 xq
.def my      0x33        ; 炸弹 yq
.def mactive 0x34
.def bspd_cur 0x35       ; 当前炸弹速度 (不能叫 bspd: 与 BSPD 撞名)
.def bomb_cd 0x36
.def fire_cd 0x37
.def kills   0x38
.def lives   0x39
.def state   0x3A        ; 0=进行中 1=失败 2=通关

.def MASK    0xE0
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

.title "INVADERS"
.entry start
.org 0

start:
    JSR init
main:
    LDR  R0, [state]
    CMPI R0, 0
    BNE  main_end
    JSR input
    JSR try_fire
    JSR squads
    JSR move_bullet
    JSR move_bomb
    JSR collisions
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
    MOVI R0, 0                  ; 清砖块位图 8 字节（上局残留）
    MOVI R3, 0
ini_m:
    STR  R0, [MASK+X]
    INC  R3
    CMPI R3, 8
    BCC  ini_m
    MOVI R0, 1                  ; 6 架全活
    MOVI R3, 0
ini_a:
    STR  R0, [ALIVE+X]
    INC  R3
    CMPI R3, 6
    BCC  ini_a
    MOVI R0, 4                  ; 队 x: 4 / 10 / 16 (错开), 第二架 +7
    STR  R0, [SX]
    ADDI R0, 7
    STR  R0, [SX+1]
    MOVI R0, 10
    STR  R0, [SX+2]
    ADDI R0, 7
    STR  R0, [SX+3]
    MOVI R0, 16
    STR  R0, [SX+4]
    ADDI R0, 7
    STR  R0, [SX+5]
    MOVI R0, 8                  ; 队 y: 8 / 16 / 24 (三排)
    STR  R0, [SY]
    STR  R0, [SY+1]
    MOVI R0, 16
    STR  R0, [SY+2]
    STR  R0, [SY+3]
    MOVI R0, 24
    STR  R0, [SY+4]
    STR  R0, [SY+5]
    MOVI R0, 0                  ; 方向/计数清零 (每架复制)
    STR  R0, [TDIR]
    STR  R0, [TDIR+1]
    STR  R0, [TDIR+2]
    STR  R0, [TDIR+3]
    STR  R0, [TDIR+4]
    STR  R0, [TDIR+5]
    STR  R0, [TTICK]
    STR  R0, [TTICK+1]
    STR  R0, [TTICK+2]
    STR  R0, [TTICK+3]
    STR  R0, [TTICK+4]
    STR  R0, [TTICK+5]
    MOVI R0, 3                  ; v3.9: 绿3 黄2 红1 (三档区分)
    STR  R0, [DIV]
    STR  R0, [DIV+1]
    MOVI R0, 2
    STR  R0, [DIV+2]
    STR  R0, [DIV+3]
    MOVI R0, 1
    STR  R0, [DIV+4]
    STR  R0, [DIV+5]
    MOVI R0, 1                  ; v4.2: 炸弹速度 1/1/2 (8px 与 16px/帧)
    STR  R0, [BSPD]
    STR  R0, [BSPD+1]
    STR  R0, [BSPD+2]
    STR  R0, [BSPD+3]
    MOVI R0, 2
    STR  R0, [BSPD+4]
    STR  R0, [BSPD+5]
    MOVI R0, 0
    STR  R0, [bactive]
    STR  R0, [mactive]
    STR  R0, [fire_cd]
    STR  R0, [kills]
    MOVI R0, 60                 ; 首枚炸弹延迟
    STR  R0, [bomb_cd]
    MOVI R0, 77                 ; 炮台中心 80 → 左上 77
    STR  R0, [px]
    MOVI R0, 3
    STR  R0, [lives]
    MOVI R0, 0
    STR  R0, [state]
    RTS

; -----------------------------------------------------------------------------
input:
    LDR  R0, [KEYS]
    ANDI R0, 3
    LDR  R1, [px]
    MOV  R2, R0
    ANDI R2, 1                  ; KEY0 左
    BEQ  in_r
    CMPI R1, 4
    BCC  in_r
    SUBI R1, 2                  ; v3.9: 2 q8/帧 (16 px/帧)
in_r:
    ANDI R0, 2                  ; KEY1 右
    BEQ  in_store
    CMPI R1, 150
    BCS  in_store
    ADDI R1, 2                  ; v3.9: 2 q8/帧 (16 px/帧)
in_store:
    STR  R1, [px]
    RTS

; -----------------------------------------------------------------------------
try_fire:
    LDR  R0, [bactive]
    CMPI R0, 0
    BNE  tf_done
    LDR  R1, [fire_cd]
    CMPI R1, 0
    BNE  tf_tick
    MOVI R0, 1
    STR  R0, [bactive]
    LDR  R0, [px]
    ADDI R0, 2
    STR  R0, [bx]
    MOVI R0, 82
    STR  R0, [by]
    ; 开火不发声（按要求）
    MOVI R0, 45
    STR  R0, [fire_cd]
    RTS
tf_tick:
    SUBI R1, 1
    STR  R1, [fire_cd]
tf_done:
    RTS

; -----------------------------------------------------------------------------
move_bullet:
    LDR  R0, [bactive]
    CMPI R0, 0
    BEQ  mb_done
    LDR  R1, [by]
    SUBI R1, 2
    BCS  mb_ok
    MOVI R1, 0
    STR  R1, [bactive]          ; 出顶失活
    RTS
mb_ok:
    STR  R1, [by]
mb_done:
    RTS

; -----------------------------------------------------------------------------
; 三支小队独立漂移: X 按 0/2/4 步进 (= 每队首架下标), 全部按架访问
squads:
    MOVI R3, 0                  ; X = 队首架下标 (0/2/4)
sq_loop:
    LDR  R0, [TTICK+X]
    ADDI R0, 1
    STR  R0, [TTICK+X]
    LDR  R2, [DIV+X]
    SUB  R2, R0                 ; DIV - TICK
    BEQ  sq_step                ; 相等 → 该队走一步
    BRA  sq_next
sq_step:
    MOVI R0, 0
    STR  R0, [TTICK+X]
    LDR  R1, [SX+X]
    ADDI R1, 1                  ; v3.4: 始终向右, 穿过屏幕
    CMPI R1, 154                ; x >= 154 → 出右边, 从左边重新进入
    BCS  sq_wrap
    BRA  sq_store
sq_wrap:
    MOVI R1, 0
    STR  R1, [SX+X]
    ADDI R1, 10
    STR  R1, [SX+1+X]
    JSR  descend_t              ; 每穿越一次下压一行
    BRA  sq_next
sq_store:
    STR  R1, [SX+X]
    ADDI R1, 10
    STR  R1, [SX+1+X]
sq_next:
    INC  R3
    INC  R3                     ; X += 2 (下一队首架)
    CMPI R3, 6
    BCC  sq_loop
    RTS

descend_t:
    LDR  R0, [SY+X]
    ADDI R0, 2
    STR  R0, [SY+X]
    STR  R0, [SY+1+X]
    CMPI R0, 64                 ; 压到 y>=64 → 失败
    BCC  des_done
    JSR  lose_life
des_done:
    RTS

; -----------------------------------------------------------------------------
move_bomb:
    LDR  R0, [mactive]
    CMPI R0, 0
    BNE  mbm_move
    LDR  R0, [bomb_cd]
    CMPI R0, 0
    BNE  mbm_tick
    ; 随机选一架活敌投弹
    LDR  R0, [RAND]
    ANDI R0, 0x07
    CMPI R0, 6
    BCS  mbm_reset              ; 索引越界 → 跳过
    MOV  R3, R0
    LDR  R1, [ALIVE+X]
    CMPI R1, 0
    BEQ  mbm_reset
    ; 炸弹从该机中心落下, 速度 = 该型 BSPD
    LDR  R1, [SX+X]
    ADDI R1, 3                  ; v3.4: 48px 宽的中心
    STR  R1, [mx]
    LDR  R1, [SY+X]
    ADDI R1, 5                  ; v3.4: 32px 高, 从下缘落
    STR  R1, [my]
    LDR  R0, [BSPD+X]
    STR  R0, [bspd_cur]
    MOVI R0, 1
    STR  R0, [mactive]
mbm_reset:
    MOVI R0, 40
    STR  R0, [bomb_cd]
    RTS
mbm_tick:
    SUBI R0, 1
    STR  R0, [bomb_cd]
    RTS
mbm_move:
    LDR  R1, [my]
    LDR  R2, [bspd_cur]
    ADD  R1, R2                 ; 按型别速度下落
    STR  R1, [my]
    CMPI R1, 86
    BCC  mbm_done
    MOVI R0, 0
    STR  R0, [mactive]
mbm_done:
    RTS

; -----------------------------------------------------------------------------
collisions:
    ; ---- 子弹 vs 敌机 (6) ----
    LDR  R0, [bactive]
    CMPI R0, 0
    BEQ  col_bomb
    LDR  R6, [bx]
    LDR  R7, [by]
    MOVI R3, 0
col_bloop:
    LDR  R0, [ALIVE+X]
    CMPI R0, 0
    BEQ  col_bnext
    ; ix = SX[i], iy = SY[i]
    LDR  R1, [SX+X]
    SUB  R1, R6                 ; R1 = ix - bx
    BCS  col_bdx
    NEG  R1
col_bdx:
    CMPI R1, 8                  ; v4.0: 64px 宽, 判定 <8q8
    BCS  col_bnext
    LDR  R1, [SY+X]
    MOV  R4, R1
    SUB  R4, R7                 ; R4 = iy - by
    BCS  col_bdy
    NEG  R4
col_bdy:
    CMPI R4, 5                  ; v3.4: 32px 高, 纵向 <5q8
    BCS  col_bnext
    ; 命中!
    MOVI R0, 0
    STR  R0, [ALIVE+X]
    STR  R0, [bactive]
    STR  R0, [SEN]              ; 关闭该机精灵槽 (槽号 = i+2)
    MOV  R0, R3
    ADDI R0, 2
    STR  R0, [SCOMMIT]
    MOVI R0, 1
    STR  R0, [SEN]
    MOVI R0, 4          ; 击落音效 = 880Hz 击打音
    STR  R0, [PSG]
    LDR  R0, [kills]
    ADDI R0, 1
    STR  R0, [kills]
    JSR  check_win
    RTS
col_bnext:
    INC  R3
    CMPI R3, 6
    BCC  col_bloop

col_bomb:
    ; ---- 炸弹 vs 炮台 ----
    LDR  R0, [mactive]
    CMPI R0, 0
    BEQ  col_done
    LDR  R1, [my]
    CMPI R1, 82
    BCC  col_done
    LDR  R2, [mx]
    LDR  R0, [px]
    ADDI R0, 3                  ; 炮台中心 = px+3
    SUB  R2, R0
    BCS  col_ddx
    NEG  R2
col_ddx:
    CMPI R2, 4
    BCS  col_done
    MOVI R0, 0
    STR  R0, [mactive]
    JSR  lose_life
col_done:
    RTS

check_win:
    MOVI R3, 0
    MOVI R1, 0
cw_loop:
    LDR  R0, [ALIVE+X]
    ADD  R1, R0
    INC  R3
    CMPI R3, 6
    BCC  cw_loop
    CMPI R1, 0
    BNE  cw_done
    ; v3.7: 全灭 → 通关态
    MOVI R0, 3
    STR  R0, [PSG]
    MOVI R0, 2
    STR  R0, [state]
    RTS
    MOVI R0, 0
    STR  R0, [bactive]
    MOVI R3, 0
cw_reset:
    MOVI R0, 1
    STR  R0, [ALIVE+X]
    INC  R3
    CMPI R3, 6
    BCC  cw_reset
    MOVI R0, 4
    STR  R0, [SX]
    ADDI R0, 7
    STR  R0, [SX+1]
    MOVI R0, 10
    STR  R0, [SX+2]
    ADDI R0, 7
    STR  R0, [SX+3]
    MOVI R0, 16
    STR  R0, [SX+4]
    ADDI R0, 7
    STR  R0, [SX+5]
    MOVI R0, 8
    STR  R0, [SY]
    STR  R0, [SY+1]
    MOVI R0, 16
    STR  R0, [SY+2]
    STR  R0, [SY+3]
    MOVI R0, 24
    STR  R0, [SY+4]
    STR  R0, [SY+5]
    MOVI R0, 0
    STR  R0, [TDIR]
    STR  R0, [TDIR+1]
    STR  R0, [TDIR+2]
cw_done:
    RTS

; -----------------------------------------------------------------------------
lose_life:
    MOVI R0, 2
    STR  R0, [PSG]
    LDR  R0, [lives]
    SUBI R0, 1
    STR  R0, [lives]
    CMPI R0, 0
    BNE  ll_clear
    MOVI R0, 1
    STR  R0, [state]            ; v3.7: 失败态
    RTS
ll_clear:
    MOVI R0, 0
    STR  R0, [bactive]
    STR  R0, [mactive]
    MOVI R0, 40
    STR  R0, [fire_cd]
    RTS

; -----------------------------------------------------------------------------
draw:
    ; ---- 炮台 槽0: 48x16 @ (px*8, 672) ----
    LDR  R1, [px]
    MOV  R2, R1
    SHRI R2, 5
    SHLI R1, 3
    MOVI R0, 1
    STR  R0, [SEN]
    STR  R1, [SXL]
    STR  R2, [SXH]
    MOVI R0, 0x98               ; 664
    STR  R0, [SYL]
    MOVI R0, 2
    STR  R0, [SYH]
    MOVI R0, 48
    STR  R0, [SW]
    MOVI R0, 48
    STR  R0, [SHT]
    MOVI R0, 0xFF
    STR  R0, [SCL]
    MOVI R0, 0x07               ; 青
    STR  R0, [SCH]
    MOVI R0, 0
    STR  R0, [SCOMMIT]
    ; ---- 子弹 槽1: 8x16 ----
    LDR  R0, [bactive]
    CMPI R0, 0
    BEQ  dr_nob
    LDR  R1, [bx]
    MOV  R2, R1
    SHRI R2, 5
    SHLI R1, 3
    STR  R1, [SXL]
    STR  R2, [SXH]
    LDR  R1, [by]
    MOV  R2, R1
    SHRI R2, 5
    SHLI R1, 3
    STR  R1, [SYL]
    STR  R2, [SYH]
    MOVI R0, 12
    STR  R0, [SW]
    MOVI R0, 24
    STR  R0, [SHT]
    MOVI R0, 0xFF
    STR  R0, [SCL]
    STR  R0, [SCH]
    MOVI R0, 1
    STR  R0, [SCOMMIT]
    BRA  dr_bomb
dr_nob:
    MOVI R0, 0
    STR  R0, [SEN]
    MOVI R0, 1
    STR  R0, [SCOMMIT]
    MOVI R0, 1
    STR  R0, [SEN]
dr_bomb:
    ; ---- 炸弹 槽14: 8x16 ----
    LDR  R0, [mactive]
    CMPI R0, 0
    BEQ  dr_nom
    LDR  R1, [mx]
    MOV  R2, R1
    SHRI R2, 5
    SHLI R1, 3
    STR  R1, [SXL]
    STR  R2, [SXH]
    LDR  R1, [my]
    MOV  R2, R1
    SHRI R2, 5
    SHLI R1, 3
    STR  R1, [SYL]
    STR  R2, [SYH]
    MOVI R0, 12
    STR  R0, [SW]
    MOVI R0, 24
    STR  R0, [SHT]
    MOVI R0, 0xE0
    STR  R0, [SCL]
    MOVI R0, 0xFF
    STR  R0, [SCH]
    MOVI R0, 14
    STR  R0, [SCOMMIT]
    BRA  dr_block
dr_nom:
    MOVI R0, 0
    STR  R0, [SEN]
    MOVI R0, 14
    STR  R0, [SCOMMIT]
    MOVI R0, 1
    STR  R0, [SEN]
dr_block:
    ; ---- 敌机 6 架: 槽 2..7, 颜色按型别 ----
    MOVI R3, 0
dr_loop:
    LDR  R0, [ALIVE+X]
    CMPI R0, 0
    BEQ  dr_next
    LDR  R1, [SX+X]             ; ix
    LDR  R4, [SY+X]             ; iy
    MOV  R7, R1
    SHRI R7, 5
    SHLI R1, 3
    STR  R1, [SXL]
    STR  R7, [SXH]
    MOV  R7, R4
    SHRI R7, 5
    SHLI R4, 3
    STR  R4, [SYL]
    STR  R7, [SYH]
    MOVI R0, 64
    STR  R0, [SW]
    MOVI R0, 40
    STR  R0, [SHT]
    MOV  R5, R3
    SHRI R5, 1                  ; 型别 = i>>1
    CMPI R5, 1
    BEQ  dr_c1
    BCS  dr_c2
    MOVI R0, 0xE0               ; 型0 绿 0x07E0
    STR  R0, [SCL]
    MOVI R0, 0x07
    STR  R0, [SCH]
    BRA  dr_commit
dr_c1:
    MOVI R0, 0xE0               ; 型1 黄 0xFFE0
    STR  R0, [SCL]
    MOVI R0, 0xFF
    STR  R0, [SCH]
    BRA  dr_commit
dr_c2:
    MOVI R0, 0x00               ; 型2 红 0xF800
    STR  R0, [SCL]
    MOVI R0, 0xF8
    STR  R0, [SCH]
dr_commit:
    MOV  R0, R3
    ADDI R0, 2
    STR  R0, [SCOMMIT]
dr_next:
    INC  R3
    CMPI R3, 6
    BCC  dr_loop
    ; ---- 血量: 三颗心, 槽 8/9/10, 24x16 红 ----
    MOVI R3, 0
ihp_loop:
    LDR  R0, [lives]
    CMP  R3, R0
    BCC  ihp_on
    MOVI R0, 0
    STR  R0, [SEN]
    MOVI R0, 8
    ADD  R0, R3
    STR  R0, [SCOMMIT]
    BRA  ihp_next
ihp_on:
    MOV  R0, R3
    SHLI R0, 5
    ADDI R0, 16
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
    MOVI R0, 0xF8
    STR  R0, [SCH]
    MOVI R0, 1
    STR  R0, [SEN]
    MOVI R0, 8
    ADD  R0, R3
    STR  R0, [SCOMMIT]
ihp_next:
    INC  R3
    CMPI R3, 3
    BCC  ihp_loop
    ; ---- 计分条: kills/2 段 ----
    LDR  R0, [kills]
    SHRI R0, 1
    CMPI R0, 9
    BCC  dr_sc
    MOVI R0, 9
dr_sc:
    STR  R0, [SCORE]
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
