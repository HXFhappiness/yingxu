// =============================================================================
// yx8_cart_soc.v ? v2.1: YX-8 ?????????????
//
// v2-A: YX-8 CPU ? sys_clk(50M) ?? pix_clk(73.33M)??????????
//       CDC ??????v2.1: ?? v2 ????????loaded_s ?????
//       entry ??? 0?dram ????????
//
// ???
//   sys_clk ??SD ??? FSM + ?? RAM A ????? + ????? + ?????
//   pix_clk ??????? FSM?A???? LUTRAM dram?? YX-8 CPU ? I/O ??
//               ? ????????/ ???? / PSG ??
//
// ?????????? .yxc ???? 3 ??/???? prog_ram[768..]?
//   ??? {data_addr, data_len} ? prog_ram[1023]?loaded ????????
//   CPU ?????? FSM ???? RAM B ?????? dram??????? CPU?
//   ?? dram ????????????/CPU ????+ ????LUTRAM ????
//
// ????32B??'YXCA' | ver | flags | entry16 | code_words16 | data_len16
//               | data_addr8 | ...??...
// ???????? 'YXCA'?code<=768 ??768..1022 ????????????
//   ???? dram(0x00..0xDF) ??????? ? ?? loaded?LED1 ?????
// =============================================================================
`timescale 1ns / 1ps

module yx8_cart_soc_v2 #(
    // Starvation watchdog (sys_clk cycles): 0.5 s @ 50 MHz.
    // A healthy read delivers bytes continuously per sector, so it never trips;
    // it only fires when the restart pulse was swallowed / the stream broke.
    parameter [27:0] WD_CYCLES = 28'd36_000_000
) (
    input  wire        sys_clk,         // 50 MHz?SD ????
    input  wire        pix_clk,         // 73.33 MHz?CPU + ???
    input  wire        pix_rst,         // ?????
    input  wire        sys_rst,         // ?????

    input  wire        en,              // ?????????
    input  wire        sd_ready,        // SD ????
    input  wire [7:0]  sd_data,
    input  wire        sd_valid,
    input  wire        key0_n,
    input  wire        key1_n,
    input  wire        pix_frame_tick,
    input  wire        reload,
    input  wire        test_mode,     // SW0: built-in CPU self test          // image switch (e.g. SW6 game select): reload
    output wire        cart_restart,
    output wire        cart_busy,
    output reg         cart_seen,       // sticky: a stream byte reached the loader
    output wire [2:0]  cart_lstate,     // debug: loader FSM state
    output wire [9:0]  cart_wcnt,       // debug: code words loaded
    output wire        cart_en_dbg,     // debug: en (cart selected)
    output reg  [15:0] cart_spr_cnt,    // debug: sprite commits since reset
    output wire [3:0]  cart_flags,      // debug: {cpu_on, up_done, loaded_s, en}
    output wire [9:0]  cart_pc,         // debug: CPU next_pc
    output wire [23:0] cart_prog0,      // debug: readback of program word 0
    output wire        cart_ready,      // flow control: SD stream may advance
    output reg  [15:0] cart_retire,     // debug: retired instruction count
    output wire [23:0] cart_p18,        // debug: readback of program word 18
    output reg  [15:0] cart_dw_cnt,     // debug: CPU data writes
    output wire        cart_hb,

    // ???????pix_clk ??? CDC?
    output reg         spr_we,
    output reg  [3:0]  spr_slot,
    output reg         spr_en,
    output reg  [10:0] spr_x,
    output reg  [9:0]  spr_y,
    output reg  [6:0]  spr_w,
    output reg  [5:0]  spr_h,
    output reg  [23:0] spr_color,
    output reg  [59:0] brick_mask,
    output reg         ev_hit,
    output reg         ev_paddle,
    output reg         ev_lose,
    output reg         ev_win,

    output wire [7:0]  cart_score
);

    // Selection is a reset boundary, not merely a loader-start permission.
    (* async_reg="true" *) reg [1:0] selected_sys,selected_pix;
    always @(posedge sys_clk)begin
        if(sys_rst)selected_sys<=0;else selected_sys<={selected_sys[0],en};
    end
    always @(posedge pix_clk)begin
        if(pix_rst)selected_pix<=0;else selected_pix<={selected_pix[0],en};
    end
    wire cart_sys_rst=sys_rst || !selected_sys[1];
    wire cart_pix_rst=pix_rst || !selected_pix[1];
    reg request_toggle,request_meta,request_sync,request_seen,request_pulse;
    reg stream_armed;
    always @(posedge pix_clk)begin
        if(cart_pix_rst)request_toggle<=0;
        else if(restart_pend)request_toggle<=~request_toggle;
    end
    always @(posedge sys_clk)begin
        if(cart_sys_rst)begin
            request_meta<=0;request_sync<=0;request_seen<=0;request_pulse<=0;stream_armed<=0;
        end else begin
            request_meta<=request_toggle;request_sync<=request_meta;request_pulse<=0;
            if(request_sync!=request_seen)begin
                request_seen<=request_sync;request_pulse<=1;stream_armed<=1;
            end
        end
    end

    // ==== ?? RAM?????A=sys ??B=pix ?? ==============================
    // ??????? ram_dual_port_simple ???TD ????? BRAM??
    // ???????FSM ? 1 ? we ?? + ??/??????????? loaded_s
    // ???????CPU ??????????
    localparam [9:0] DATA_BASE = 10'd768;   // ??????
    localparam [9:0] META_ADDR = 10'd1023;  // {data_addr, data_len[15:0]}

    // ---- 1024-deep async byte FIFO: SD stream (sys_clk) -> loader (pix_clk) ----
    // The probe streams a whole 512-byte sector back-to-back at sys_clk rate, so
    // the loader must be decoupled from it. 1024 entries > one sector burst, so
    // nothing is ever lost and no ready backpressure is required.
    reg  [7:0]   bq_mem [0:1023];
    reg  [10:0]  bq_wp, bq_rp;
    reg  [10:0]  bq_wg, bq_rg;
    reg  [10:0]  bq_wg_m, bq_wg_s;

    wire [10:0]  bq_wp_nxt = bq_wp + 11'd1;
    wire [10:0]  bq_rp_nxt = bq_rp + 11'd1;
    wire [10:0]  bq_wg_nxt = bq_wp_nxt ^ (bq_wp_nxt >> 1);
    wire [10:0]  bq_rg_nxt = bq_rp_nxt ^ (bq_rp_nxt >> 1);
    wire         bq_empty  = (bq_rg == bq_wg_s);

    always @(posedge sys_clk) begin
        if (cart_sys_rst || por) begin
            bq_wp <= 11'd0;
            bq_wg <= 11'd0;
        end
        else if (sd_valid && stream_armed) begin
            bq_mem[bq_wp[9:0]] <= sd_data;
            bq_wp         <= bq_wp_nxt;
            bq_wg         <= bq_wg_nxt;
        end
    end

    reg [7:0] bq_q;        // registered read data
    reg       bq_q_v;      // one-cycle strobe: a byte is ready

    always @(posedge pix_clk) begin
        if (cart_pix_rst) begin
            bq_rp    <= 11'd0;
            bq_rg    <= 11'd0;
            bq_wg_m  <= 11'd0;
            bq_wg_s  <= 11'd0;
            bq_q     <= 8'd0;
            bq_q_v   <= 1'b0;
        end
        else begin
            bq_wg_m <= bq_wg;
            bq_wg_s <= bq_wg_m;
            if (!bq_empty) begin
                bq_q     <= bq_mem[bq_rp[9:0]];
                bq_q_v   <= 1'b1;
                bq_rp    <= bq_rp_nxt;
                bq_rg    <= bq_rg_nxt;
            end
            else begin
                bq_q_v   <= 1'b0;
            end
        end
    end

    assign cart_ready = 1'b1;

    // 回读地址切换延后 4 拍：否则会抢走 L_META 对地址 1023 的写入
    reg [3:0] ld_dly;
    always @(posedge pix_clk) begin
        if (cart_pix_rst) ld_dly <= 4'd0;
        else         ld_dly <= {ld_dly[2:0], loaded_s};
    end

    reg        prog_we;
    reg [9:0]  prog_waddr;
    reg [23:0] prog_wdata;
    wire [23:0] instr_r;
    wire [23:0] prog_dbg;

    // Program RAM: BOTH ports on pix_clk (single clock) so TD infers a plain
    // BRAM. The loader runs on sys_clk and hands words over with a toggle
    // handshake (see below) instead of writing across clock domains.
    // Program memory: single clock (pix_clk) on both ports, registered read.
    // Fetch is aligned by presenting the NEXT pc (b_raddr = cpu_next_pc), so the
    // registered data is exactly the instruction for the pc the CPU advances to.
    ram_dual_port_simple #(.data_width(24), .data_num(1024)) u_prog (
        .douta(prog_dbg  ),
        .doutb(instr_r   ),
        .dina (prog_wdata),
        .addra(ld_dly[3] ? 10'd18 : prog_waddr),
        .addrb(raddr_q   ),
        .wea  (prog_we   ),
        .clka (pix_clk   ),
        .clkb (pix_clk   )
    );



    // ---------------- built-in CPU self test (test_mode) ----------------
    // Writes a fixed 16-word program into the program RAM and starts the CPU.
    // Program: set sprite staging, commit slot 0, then spin.
    localparam [15:0] TEST_WORDS = 16'd27;
    localparam [11:0] TEST_ENTRY = 12'd0;

    function [23:0] test_word;
        input [5:0] i;
        begin
            case (i)
            5'd0 : test_word = 24'h2C0101;   // MOVI R1,0x01  (stage 1)
            5'd1 : test_word = 24'h3201FE;   // STR  R1,[0xFE]
            5'd2 : test_word = 24'h2C0111;   // MOVI R1,0x11
            5'd3 : test_word = 24'h3201E8;   // STR  R1,[0xE8]  SEN=1
            5'd4 : test_word = 24'h2C0140;   // MOVI R1,0x40
            5'd5 : test_word = 24'h3201E9;   // STR  R1,[0xE9]  xlo
            5'd6 : test_word = 24'h2C0100;   // MOVI R1,0
            5'd7 : test_word = 24'h3201EA;   // STR  R1,[0xEA]  xhi
            5'd8 : test_word = 24'h2C0140;   // MOVI R1,0x40
            5'd9 : test_word = 24'h3201EB;   // STR  R1,[0xEB]  ylo
            5'd10: test_word = 24'h2C0100;   // MOVI R1,0
            5'd11: test_word = 24'h3201EC;   // STR  R1,[0xEC]  yhi
            5'd12: test_word = 24'h2C0170;   // MOVI R1,0x70  (w=112)
            5'd13: test_word = 24'h3201ED;   // STR  R1,[0xED]
            5'd14: test_word = 24'h2C0120;   // MOVI R1,0x20  (h=32)
            5'd15: test_word = 24'h3201EE;   // STR  R1,[0xEE]
            5'd16: test_word = 24'h2C01FF;   // MOVI R1,0xFF
            5'd17: test_word = 24'h3201EF;   // STR  R1,[0xEF]  color lo
            5'd18: test_word = 24'h2C0107;   // MOVI R1,0x07
            5'd19: test_word = 24'h3201F0;   // STR  R1,[0xF0]  color hi
            5'd20: test_word = 24'h2C0103;   // MOVI R1,0x03  (stage 2: staging done)
            5'd21: test_word = 24'h3201FE;   // STR  R1,[0xFE]
            5'd22: test_word = 24'h2C0100;   // MOVI R1,0  (slot 0)
            5'd23: test_word = 24'h3201F1;   // STR  R1,[0xF1]  COMMIT
            5'd24: test_word = 24'h2C0107;   // MOVI R1,0x07  (stage 3: commit done)
            5'd25: test_word = 24'h3201FE;   // STR  R1,[0xFE]
            5'd26: test_word = 24'h460001;   // BRA self (spin)
            default: test_word = 24'h000000;
            endcase
        end
    endfunction

    reg [5:0]  tst_idx;
    reg        tst_busy;
    wire       tst_run = test_mode && !tst_busy;

    // ==== sys_clk ??.yxc ??? =============================================
    localparam [2:0] L_IDLE = 3'd0, L_HDR = 3'd1, L_CODE = 3'd2,
                     L_DATA = 3'd3, L_DONE = 3'd4, L_META = 3'd5, L_FILL = 3'd6;
    reg [2:0]  lstate;
    reg [4:0]  hdr_idx;
    reg [27:0] hdr_idle;   // watchdog: re-arm the SD read if no byte arrives (~4 s)
    reg [31:0] magic_r;
    reg [15:0] entry_r, words_r, dlen_r;
    reg [7:0]  daddr_r;
    reg [1:0]  bph;
    reg [7:0]  b0, b1;
    reg [9:0]  wcnt;
    reg [9:0]  fill_idx;   // 清零填充指针
    reg        fill_p1;    // G4: 填充相位 1（代码尾→数据区前）；0 = 相位 2（数据区后→1022）
    reg [9:0]  dwidx;                       // ????????
    reg [15:0] dcnt;                        // ?????????? 3?
    reg        loaded_s, restart_pend;
    reg [19:0] por_cnt;

    always @(posedge sys_clk) begin
        if (por_cnt != 20'd999_999) por_cnt <= por_cnt + 20'd1;
    end
    wire por = (por_cnt != 20'd999_999);

    assign cart_restart = request_pulse; // full SYS-clock pulse from pixel toggle
    assign cart_busy    = en & ~loaded_s;
    assign cart_lstate  = lstate;
    assign cart_wcnt    = wcnt;
    assign cart_en_dbg  = en;   // LED1: ???/??(??) = ??

    always @(posedge pix_clk) begin
        if (cart_pix_rst || por) begin
            lstate <= L_IDLE; loaded_s <= 1'b0; restart_pend <= 1'b0;
            cart_seen <= 1'b0;
            tst_idx  <= 6'd0;
            tst_busy <= 1'b0;
            hdr_idx <= 5'd0; hdr_idle <= 16'd0; magic_r <= 32'd0; bph <= 2'd0;
            wcnt <= 10'd0; dwidx <= 10'd0; dcnt <= 16'd0; fill_idx <= 10'd0; fill_p1 <= 1'b0;
            entry_r <= 16'd0; words_r <= 16'd0; dlen_r <= 16'd0; daddr_r <= 8'd0;
            b0 <= 8'd0; b1 <= 8'd0;
            prog_we <= 1'b0; prog_waddr <= 10'd0; prog_wdata <= 24'd0;
        end
        else if (reload) begin
            // cart image switch: drop current image, re-parse header from L_IDLE
            lstate <= L_IDLE; loaded_s <= 1'b0; restart_pend <= 1'b0;
            hdr_idx <= 5'd0; bph <= 2'd0; magic_r <= 32'd0;
            wcnt <= 10'd0; dwidx <= 10'd0; dcnt <= 16'd0;
            hdr_idle <= WD_CYCLES;
            prog_we <= 1'b0;
        end
        else begin
            // Pulse defaults: cleared here, re-set later in this same block when a
            // one-cycle pulse is really needed (later assignment wins).
            restart_pend <= 1'b0;
            prog_we      <= 1'b0;
            // built-in CPU self test: write a fixed program, then start the CPU
            if (tst_run) begin
                if (tst_idx < 5'd27) begin
                    prog_we    <= 1'b1;
                    prog_waddr <= {4'd0, tst_idx};
                    prog_wdata <= test_word(tst_idx);
                    tst_idx    <= tst_idx + 6'd1;
                end
                else begin
                    loaded_s <= 1'b1;
                    lstate   <= L_DONE;
                    tst_busy <= 1'b1;
                end
            end
            // sticky diagnostic: did any stream byte reach the loader?
            if (sd_valid && lstate != L_IDLE) cart_seen <= 1'b1;
            // Re-arm watchdog: sd_seen is sticky, so the one-shot L_IDLE restart
            // pulse can collide with an in-flight photo read (probe ~busy swallows
            // it). If no stream byte arrives for WD_CYCLES in L_HDR/L_CODE/L_DATA,
            // go back to L_IDLE and re-pulse restart until the stream really runs.
            if (lstate == L_HDR || lstate == L_CODE || lstate == L_DATA) begin
                if (bq_q_v)                 hdr_idle <= WD_CYCLES;
                else if (hdr_idle != 28'd0)   hdr_idle <= hdr_idle - 28'd1;
                else begin
                    lstate       <= L_IDLE;
                    hdr_idle     <= WD_CYCLES;
                    restart_pend <= 1'b1;
                end
            end
            if (!tst_run) case (lstate)
            L_IDLE: begin
                if (en && sd_ready && !loaded_s) begin
                    restart_pend <= 1'b1;
                    hdr_idle <= WD_CYCLES;
                    hdr_idx <= 5'd0; bph <= 2'd0;
                    wcnt <= 10'd0; dwidx <= 10'd0; dcnt <= 16'd0;
                    magic_r <= 32'd0;
                    lstate <= L_HDR;
                end
            end
            L_HDR: if (bq_q_v) begin
                if (hdr_idx < 5'd4)
                    magic_r <= {magic_r[23:0], bq_q};
                case (hdr_idx)
                5'd6:  entry_r[7:0]  <= bq_q;
                5'd7:  entry_r[15:8] <= bq_q;
                5'd8:  words_r[7:0]  <= bq_q;
                5'd9:  words_r[15:8] <= bq_q;
                5'd10: dlen_r[7:0]   <= bq_q;
                5'd11: dlen_r[15:8]  <= bq_q;
                5'd12: daddr_r       <= bq_q;
                default: ;
                endcase
                hdr_idx <= hdr_idx + 5'd1;
                if (hdr_idx == 5'd4 && magic_r != 32'h5958_4341) begin
                    lstate <= L_DONE;            // 'YXCA' ??????4???4???? ??
                end
                else if (hdr_idx == 5'd31) begin
                    if (words_r == 16'd0 || words_r > 16'd768 ||
                        daddr_r >= 8'hE0 || dlen_r > 16'd224 ||
                        {1'b0, daddr_r} + {1'b0, dlen_r[7:0]} > 9'h0E0)
                        lstate <= L_DONE;        // ???? ? ???LED1 ???
                    else lstate <= L_CODE;
                end
            end
            L_CODE: if (bq_q_v) begin
                case (bph)
                2'd0: begin b0 <= bq_q; bph <= 2'd1; end
                2'd1: begin b1 <= bq_q; bph <= 2'd2; end
                default: begin
                    prog_we    <= 1'b1;
                    prog_waddr <= wcnt;
                    prog_wdata <= {b0, b1, bq_q};   // {op, A, B}???? op ???
                    wcnt <= wcnt + 10'd1;
                    bph  <= 2'd0;
                    if (wcnt + 10'd1 == words_r[9:0])
                        lstate <= L_META;              // ??????????
                end
                endcase
            end
            L_FILL: begin
                // 两段式清零：[代码尾..767] 与 [数据区后..1022]，跳过数据打包区，
                // 保留 1023 的元数据字（NOP 编码，可安全执行）。尾字路径也必须
                // 走到这里——否则程序区外是未定义内容（G4: snake 跑飞的帮凶）。
                prog_we    <= 1'b1;
                prog_waddr <= fill_idx;
                prog_wdata <= 24'h000000;
                if (fill_p1) begin
                    if (fill_idx >= DATA_BASE - 10'd1) begin
                        fill_p1  <= 1'b0;
                        fill_idx <= DATA_BASE + dwidx;   // 跳过数据区
                    end
                    else fill_idx <= fill_idx + 10'd1;
                end
                else begin
                    if (fill_idx >= 10'd1022) begin
                        loaded_s <= 1'b1;
                        lstate   <= L_DONE;
                    end
                    else fill_idx <= fill_idx + 10'd1;
                end
            end
            L_META: begin                              // 元数据字（独占一拍）
                prog_we    <= 1'b1;
                prog_waddr <= META_ADDR;
                // G4: 编码 {8'h00, daddr, dlen[7:0]}——op=0x00=NOP。旧编码
                // {daddr, dlen[15:8], dlen[7:0]} 的 op=daddr，daddr=0x50 时
                // 恰好是 JMP，CPU 跑飞撞上它会被弹回 0x200 永远出不来。
                // dlen ≤ 224（加载校验保证），8 位足够。
                prog_wdata <= {8'h00, daddr_r, dlen_r[7:0]};
                fill_idx <= (wcnt < DATA_BASE) ? wcnt : DATA_BASE;
                fill_p1  <= (wcnt < DATA_BASE);
                if (dlen_r != 16'd0) lstate <= L_DATA;
                else lstate <= L_FILL;
            end
            L_DATA: if (bq_q_v) begin
                case (bph)
                2'd0: begin
                    b0 <= bq_q; bph <= 2'd1;
                    if (dcnt + 16'd1 >= dlen_r) begin       // 1 字节尾
                        prog_we    <= 1'b1;
                        prog_waddr <= DATA_BASE + dwidx;
                        prog_wdata <= {bq_q, 8'h00, 8'h00};
                        fill_idx <= (wcnt < DATA_BASE) ? wcnt : (DATA_BASE + dwidx + 10'd1);
                        fill_p1  <= (wcnt < DATA_BASE);
                        lstate <= L_FILL;                   // G4: 尾字也必须填充
                    end
                end
                2'd1: begin
                    b1 <= bq_q; bph <= 2'd2;
                    if (dcnt + 16'd2 >= dlen_r) begin       // 2 字节尾
                        prog_we    <= 1'b1;
                        prog_waddr <= DATA_BASE + dwidx;
                        prog_wdata <= {b0, bq_q, 8'h00};
                        fill_idx <= (wcnt < DATA_BASE) ? wcnt : (DATA_BASE + dwidx + 10'd1);
                        fill_p1  <= (wcnt < DATA_BASE);
                        lstate <= L_FILL;
                    end
                end
                default: begin
                    prog_we    <= 1'b1;
                    prog_waddr <= DATA_BASE + dwidx;
                    prog_wdata <= {b0, b1, bq_q};
                    dwidx <= dwidx + 10'd1;
                    bph   <= 2'd0;
                    dcnt  <= dcnt + 16'd3;
                    if (dcnt + 16'd3 >= dlen_r) begin
                        fill_idx <= (wcnt < DATA_BASE) ? wcnt : (DATA_BASE + dwidx + 10'd1);
                        fill_p1  <= (wcnt < DATA_BASE);
                        lstate   <= L_FILL;
                    end
                end
                endcase
            end
            default: ;
            endcase
        end
    end

    // ==== pix_clk ??loaded ?? + ????? + CPU ==========================

    reg loaded_m, loaded_p;
    always @(posedge pix_clk) begin
        loaded_m <= loaded_s;
        loaded_p <= loaded_m;
    end

    // ?? RAM B ???????? FSM???? CPU ???instr_r = doutb?
    reg  [9:0]  up_raddr;
    wire        up_done;
    wire [9:0]  b_raddr = up_done ? cpu_next_pc[9:0] : up_raddr;
    // 取指地址先打一拍：BRAM 输出再寄存一拍 => 总延迟确定 2 拍（与 CPU 的 S_WAIT 对齐）
    reg  [9:0]  raddr_q;
    always @(posedge pix_clk) begin
        if (cart_pix_rst) raddr_q <= 10'd0;
        else         raddr_q <= b_raddr;
    end

    // ---- ????? FSM?CPU ????? B ?? dram ??? -------------------
    localparam [2:0] UP_IDLE = 3'd0, UP_META0 = 3'd1, UP_META1 = 3'd2,
                     UP_FETCH = 3'd3, UP_W0 = 3'd4, UP_W1 = 3'd5,
                     UP_W2 = 3'd6, UP_DONE = 3'd7;
    reg [2:0]  up_state;
    reg [7:0]  up_da;        // dram ???
    reg [15:0] up_cnt;       // ?????
    reg [15:0] up_dlen;
    reg [9:0]  up_wc;        // ????
    reg [3:0]  up_dly;        // settle delay before sampling META?

    assign up_done = (up_state == UP_DONE);

    wire        up_we    = (up_state == UP_W0 || up_state == UP_W1 || up_state == UP_W2)
                           && (up_cnt < up_dlen);
    wire [7:0]  up_dbyte = (up_state == UP_W0) ? instr_r[23:16] :
                           (up_state == UP_W1) ? instr_r[15:8] :
                                                 instr_r[7:0];

    always @(posedge pix_clk) begin
        if (cart_pix_rst) begin
            up_state <= UP_IDLE; up_da <= 8'd0; up_cnt <= 16'd0; up_dly <= 4'd0;
            up_dlen <= 16'd0; up_wc <= 10'd0; up_raddr <= 10'd0;
        end
        else begin
            case (up_state)
            UP_IDLE: if (loaded_p) begin
                if (up_dly != 4'd15) up_dly <= up_dly + 4'd1;
                else begin
                    up_raddr <= META_ADDR;
                    up_state <= UP_META0;
                end
            end
            UP_META0: up_state <= UP_META1;          // instr_r ????????
            UP_META1: begin                          // instr_r = {8'h00, addr, len}
                up_dlen <= {8'h00, instr_r[7:0]};    // G4: 元数据 NOP 编码
                up_da   <= instr_r[15:8];
                up_cnt  <= 16'd0;
                up_wc   <= 10'd0;
                if (instr_r[7:0] == 8'd0) up_state <= UP_DONE;
                else begin
                    up_raddr <= DATA_BASE;
                    up_state <= UP_FETCH;
                end
            end
            UP_FETCH: up_state <= UP_W0;             // instr_r ????????
            UP_W0: begin
                if (up_cnt < up_dlen) begin up_da <= up_da + 8'd1; up_cnt <= up_cnt + 16'd1; end
                up_state <= UP_W1;
            end
            UP_W1: begin
                if (up_cnt < up_dlen) begin up_da <= up_da + 8'd1; up_cnt <= up_cnt + 16'd1; end
                up_state <= UP_W2;
            end
            UP_W2: begin
                if (up_cnt < up_dlen) begin up_da <= up_da + 8'd1; up_cnt <= up_cnt + 16'd1; end
                if (up_cnt >= up_dlen) up_state <= UP_DONE;
                else begin
                    up_wc    <= up_wc + 10'd1;
                    up_raddr <= DATA_BASE + up_wc + 10'd1;
                    up_state <= UP_FETCH;
                end
            end
            default: up_state <= UP_DONE;
            endcase
        end
    end

    // ---- ?? RAM?pix ???? + ????LUTRAM? ---------------------------
    reg [7:0] dram [0:223];

    // ---- YX-8 CPU ------------------------------------------------------------
    wire [7:0]  cpu_daddr, cpu_dwdata, cpu_drdata;
    wire        cpu_dwe, cpu_halted, cpu_retire;
    wire [15:0] cpu_pc;
    wire [15:0] cpu_next_pc;
    // up_done ??? 2 ???? CPU????? B ????????
    // prog[entry] ??????????????????????????
    reg up_done_d, up_done_d2;
    always @(posedge pix_clk) begin
        up_done_d  <= up_done;
        up_done_d2 <= up_done_d;
    end
    wire        cpu_rst = cart_pix_rst || !loaded_p || !up_done_d2;
    // First fetched instruction (diagnostic): latch once the CPU leaves reset.
    reg [3:0]  fi_dly;
    reg [23:0] first_instr;
    always @(posedge pix_clk) begin
        if (cart_pix_rst) begin
            fi_dly      <= 4'd0;
            first_instr <= 24'd0;
        end
        else if (fi_dly != 4'd15) begin
            fi_dly <= fi_dly + 4'd1;
        end
        else if (fi_dly == 4'd15) begin
            first_instr <= instr_r;   // latched once (fi_dly stops advancing)
        end
    end


    // ---------------- combinational test ROM (no RAM involved) ----------------
    function [23:0] rom_instr;
        input [5:0] i;
        begin
            case (i)
            6'd0 : rom_instr = 24'h2C0120;   // MOVI R1,32      ; x=32
            6'd1 : rom_instr = 24'h3201E9;   // STR R1,[SXL]
            6'd2 : rom_instr = 24'h2C0100;   // MOVI R1,0
            6'd3 : rom_instr = 24'h3201EA;   // STR R1,[SXH]
            6'd4 : rom_instr = 24'h2C0164;   // MOVI R1,100     ; y=100
            6'd5 : rom_instr = 24'h3201EB;   // STR R1,[SYL]
            6'd6 : rom_instr = 24'h2C0100;   // MOVI R1,0
            6'd7 : rom_instr = 24'h3201EC;   // STR R1,[SYH]
            6'd8 : rom_instr = 24'h2C0130;   // MOVI R1,48      ; w=48
            6'd9 : rom_instr = 24'h3201ED;   // STR R1,[SW]
            6'd10: rom_instr = 24'h2C0130;   // MOVI R1,48      ; h=48
            6'd11: rom_instr = 24'h3201EE;   // STR R1,[SHT]
            6'd12: rom_instr = 24'h2C01E0;   // MOVI R1,0xE0    ; green
            6'd13: rom_instr = 24'h3201EF;   // STR R1,[SCL]
            6'd14: rom_instr = 24'h2C0107;   // MOVI R1,0x07
            6'd15: rom_instr = 24'h3201F0;   // STR R1,[SCH]
            6'd16: rom_instr = 24'h2C0101;   // MOVI R1,1       ; SEN=1
            6'd17: rom_instr = 24'h3201E8;   // STR R1,[SEN]
            6'd18: rom_instr = 24'h2C0100;   // MOVI R1,0       ; slot 0
            6'd19: rom_instr = 24'h3201F1;   // STR R1,[SCOMMIT]
            6'd20: rom_instr = 24'h2C0104;   // MOVI R1,4
            6'd21: rom_instr = 24'h280105;   // SHLI R1,5  (4<<5 = 128 if shifts work)
            6'd22: rom_instr = 24'h000000;   // NOP (do not clobber R1)
            6'd23: rom_instr = 24'h000000;   // NOP (do not clobber R1)
            6'd24: rom_instr = 24'h000000;   // NOP (do not clobber R1)
            6'd25: rom_instr = 24'h3201E9;   // STR R1,[SXL]
            6'd26: rom_instr = 24'h2C0100;   // MOVI R1,0
            6'd27: rom_instr = 24'h3201EA;   // STR R1,[SXH]
            6'd28: rom_instr = 24'h2C018C;   // MOVI R1,140     ; y=140
            6'd29: rom_instr = 24'h3201EB;   // STR R1,[SYL]
            6'd30: rom_instr = 24'h2C0100;   // MOVI R1,0
            6'd31: rom_instr = 24'h3201EC;   // STR R1,[SYH]
            6'd32: rom_instr = 24'h2C01F0;   // MOVI R1,0xE0    ; yellow
            6'd33: rom_instr = 24'h3201EF;   // STR R1,[SCL]
            6'd34: rom_instr = 24'h2C01FF;   // MOVI R1,0xFF
            6'd35: rom_instr = 24'h3201F0;   // STR R1,[SCH]
            6'd36: rom_instr = 24'h2C0101;   // MOVI R1,1
            6'd37: rom_instr = 24'h3201E8;   // STR R1,[SEN]
            6'd38: rom_instr = 24'h2C0101;   // MOVI R1,1       ; slot 1
            6'd39: rom_instr = 24'h3201F1;   // STR R1,[SCOMMIT]
            6'd40: rom_instr = 24'h460000;   // BRA spin
            default: rom_instr = 24'h000000;
            endcase
        end
    endfunction

    wire [23:0] instr_cpu = test_mode ? rom_instr(cpu_pc[5:0]) : instr_r;

    yx8_cpu u_cpu (
        .clk(pix_clk), .rst(cpu_rst),
        .entry(entry_r[9:0]),
        .instr(instr_cpu), .next_pc(cpu_next_pc),
        .daddr(cpu_daddr), .dwdata(cpu_dwdata), .dwe(cpu_dwe),
        .drdata(cpu_drdata),
        .frame_tick(pix_frame_tick), .halted(cpu_halted), .retire(cpu_retire), .pc_out(cpu_pc)
    );

    // ---- I/O ???pix_clk ??? CPU ??? ---------------------------------
    reg [7:0]  mask_b [0:7];integer mask_reset_i;
    reg        s_en;
    reg [10:0] s_x;
    reg [9:0]  s_y;
    reg [6:0]  s_w;
    reg [5:0]  s_h;
    reg [15:0] s_c565;
    reg [7:0]  frame_cnt;
    reg [7:0]  lfsr;
    reg [7:0]  cart_score_r;
    reg        hb_r;
    reg        wipe_act;    // G4: 重载精灵表清扫
    reg [4:0]  wipe_cnt;
    reg        loaded_q;

    wire cpu_on_i = !cpu_rst;
    assign cart_flags = {cpu_on_i, up_done, loaded_s, en};
    assign cart_pc    = cpu_pc[9:0];
    assign cart_prog0 = first_instr;
    assign cart_p18    = instr_r;

    wire cpu_on = !cpu_rst;
    // G4 修复：CPU 在 S_WAIT 等待拍 dwe/io 译码仍然有效（下一条指令已就位），
    // 访存副作用必须用 retire 门控到执行拍——否则精灵提交双发、LFSR 双步进。
    wire io_we  = cpu_on && cpu_retire && cpu_dwe && (cpu_daddr >= 8'hE0);
    wire ram_we = cpu_on && cpu_retire && cpu_dwe && (cpu_daddr <  8'hE0);

    wire [7:0] cop     = instr_r[23:16];
    wire       cpu_ldr = (cop == 8'h30) || (cop == 8'h31);
    wire       lfsr_rd = cpu_on && cpu_retire && cpu_ldr && (cpu_daddr == 8'hF4);

    // ?????pix_clk ??
    reg k0m, k0s, k1m, k1s;
    always @(posedge pix_clk) begin
        k0m <= ~key0_n; k0s <= k0m;
        k1m <= ~key1_n; k1s <= k1m;
    end

    wire lfsr_fb = lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[4];

    // ? mux?LDR ?????????
    reg [7:0] io_rd;
    always @(*) begin
        case (cpu_daddr)
        8'hE0: io_rd = mask_b[0];   8'hE1: io_rd = mask_b[1];
        8'hE2: io_rd = mask_b[2];   8'hE3: io_rd = mask_b[3];
        8'hE4: io_rd = mask_b[4];   8'hE5: io_rd = mask_b[5];
        8'hE6: io_rd = mask_b[6];   8'hE7: io_rd = mask_b[7];
        8'hE8: io_rd = {7'b0, s_en};
        8'hE9: io_rd = s_x[7:0];    8'hEA: io_rd = {5'b0, s_x[10:8]};
        8'hEB: io_rd = s_y[7:0];    8'hEC: io_rd = {6'b0, s_y[9:8]};
        8'hED: io_rd = s_w;         8'hEE: io_rd = {2'b0, s_h};
        8'hEF: io_rd = s_c565[7:0]; 8'hF0: io_rd = s_c565[15:8];
        8'hF2: io_rd = {6'b0, k1s, k0s};
        8'hF3: io_rd = frame_cnt;
        8'hF4: io_rd = lfsr;
        8'hF6: io_rd = 8'h80;       // ?????v2 ????
        default: io_rd = 8'h00;
        endcase
    end

    wire mask_we = io_we && (cpu_daddr <= 8'hE7);

    assign cpu_drdata = (cpu_daddr < 8'hE0) ? dram[cpu_daddr[7:0]] : io_rd;

    always @(posedge pix_clk) begin
        if (cart_pix_rst) begin
            s_en <= 1'b0; s_x <= 11'd0; s_y <= 10'd0; s_w <= 7'd0; s_h <= 6'd0;
            s_c565 <= 16'd0;
            frame_cnt <= 8'd0; lfsr <= 8'hAC;
            cart_score_r <= 8'd0; hb_r <= 1'b0;
            cart_spr_cnt <= 16'd0;
            cart_dw_cnt   <= 16'd0;
            cart_retire  <= 16'd0;
            wipe_act <= 1'b0; wipe_cnt <= 5'd0; loaded_q <= 1'b0;
            spr_we <= 1'b0; spr_slot <= 4'd0; spr_en <= 1'b0;
            spr_x <= 11'd0; spr_y <= 10'd0; spr_w <= 7'd0; spr_h <= 6'd0;
            spr_color <= 24'd0; brick_mask <= 60'd0;
            for(mask_reset_i=0;mask_reset_i<8;mask_reset_i=mask_reset_i+1)mask_b[mask_reset_i]<=0;
            ev_hit <= 1'b0; ev_paddle <= 1'b0; ev_lose <= 1'b0; ev_win <= 1'b0;
        end
        else begin
            spr_we <= 1'b0;
            ev_hit <= 1'b0; ev_paddle <= 1'b0; ev_lose <= 1'b0; ev_win <= 1'b0;

            if (io_we) begin
                case (cpu_daddr)
                8'hE8: s_en       <= cpu_dwdata[0];
                8'hE9: s_x[7:0]   <= cpu_dwdata;
                8'hEA: s_x[10:8]  <= cpu_dwdata[2:0];
                8'hEB: s_y[7:0]   <= cpu_dwdata;
                8'hEC: s_y[9:8]   <= cpu_dwdata[1:0];
                8'hED: s_w        <= cpu_dwdata[6:0];
                8'hEE: s_h        <= cpu_dwdata[5:0];
                8'hEF: s_c565[7:0]  <= cpu_dwdata;
                8'hF0: s_c565[15:8] <= cpu_dwdata;
                8'hF1: begin       // ?? ? ???????
                    spr_we   <= 1'b1;
                    cart_spr_cnt <= cart_spr_cnt + 16'd1;
                    spr_slot <= cpu_dwdata[3:0];
                    spr_en   <= s_en;
                    spr_x    <= s_x;
                    spr_y    <= s_y;
                    spr_w    <= s_w;
                    spr_h    <= s_h;
                    spr_color <= {s_c565[15:11], s_c565[15:13],
                                  s_c565[10:5],  s_c565[10:9],
                                  s_c565[4:0],   s_c565[4:2]};
                end
                8'hF5: if (cpu_dwdata != 8'd0) begin
                    // G6: 码 1=撞板(440Hz) 2=失败(220) 3=通关(1320) 4=击打(880)
                    ev_paddle <= en && (cpu_dwdata == 8'd1);
                    ev_lose   <= en && (cpu_dwdata == 8'd2);
                    ev_win    <= en && (cpu_dwdata == 8'd3);
                    ev_hit    <= en && (cpu_dwdata == 8'd4);
                end
                8'hFE: cart_score_r <= cpu_dwdata;
                default: ;
                endcase
            end

            if (cpu_dwe && cpu_on_i) cart_dw_cnt <= cart_dw_cnt + 16'd1;
            if (cpu_retire)          cart_retire <= cart_retire + 16'd1;
            if (mask_we) mask_b[cpu_daddr[2:0]] <= cpu_dwdata;
            brick_mask <= {mask_b[7][3:0], mask_b[6], mask_b[5], mask_b[4],
                           mask_b[3], mask_b[2], mask_b[1], mask_b[0]};

            // ??? / LFSR / ??
            if (pix_frame_tick) frame_cnt <= frame_cnt + 8'd1;
            if (lfsr_rd)        lfsr      <= {lfsr[6:0], lfsr_fb};
            hb_r <= frame_cnt[4];

            // G4: 重载瞬间清扫 16 个精灵槽（置于块尾，后写覆盖）。SW6 换槽只
            // 换 LBA、不改变 game_sel2，wrapper 的擦除逻辑不会触发——旧游戏
            // 的最后一帧会永久留在精灵表里（invaders→breakout 残像实测）。
            if (loaded_q && !loaded_p) begin
                wipe_act <= 1'b1;
                wipe_cnt <= 5'd0;
            end
            else if (wipe_act) begin
                spr_we    <= 1'b1;
                spr_slot  <= wipe_cnt[3:0];
                spr_en    <= 1'b0;
                spr_x     <= 11'd0;
                spr_y     <= 10'd0;
                spr_w     <= 7'd0;
                spr_h     <= 6'd0;
                spr_color <= 24'd0;
                if (wipe_cnt[3:0] == 4'd15) wipe_act <= 1'b0;
                wipe_cnt <= wipe_cnt + 5'd1;
            end
            loaded_q <= loaded_p;
        end
    end

    // dram ????? FSM ????? CPU ????????????
    always @(posedge pix_clk) begin
        if (up_we)       dram[up_da]      <= up_dbyte;
        else if (ram_we) dram[cpu_daddr]  <= cpu_dwdata;
    end

    assign cart_score = cart_score_r;

endmodule
