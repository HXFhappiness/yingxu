`timescale 1ns / 1ps
`default_nettype none

// yx8_uart_telem - compact fixed-template status line over UART 115200 8N1.
// Four A/B/C/D lines, 115200 8N1; 0.2 s gap between complete reports.
// D11: constant format ROM, one shared hexadecimal encoder; original wire format.
module yx8_uart_telem (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_seen, i_busy, i_err, i_dne, i_por, i_flu, i_wft, i_gm, i_ca,
    input  wire [3:0]  i_kil, i_ret,
    input  wire [2:0]  i_ctrl,
    input  wire [3:0]  i_init,
    input  wire [39:0] i_rsp,
    input  wire [2:0]  i_rd,
    input  wire [7:0]  i_rdt,
    input  wire [5:0]  i_div,
    input  wire        i_spik,
    input  wire [3:0]  i_cnt,
    input  wire [1:0]  i_sel,
    input  wire        i_ads, i_dds, i_csn, i_mos, i_sck, i_miso,
    input  wire [10:0] i_acc,
    input  wire [31:0] i_off,
    input  wire        i_vld, i_w2f, i_r2e, i_hb,
    input  wire        i_sst_p, i_snx_p, i_sdn_p,
    input  wire [15:0] i_mise, i_sce,
    input  wire [7:0]  i_sw,
    input  wire [2:0]  i_ls,
    input  wire [9:0]  i_wc,
    input  wire        i_cbu,
    input  wire [15:0] i_sprc,
    input  wire [3:0]  i_cfl,
    input  wire [9:0]  i_pc,
    input  wire [15:0] i_dwc,
    input  wire [23:0] i_p0,
    input  wire [15:0] i_rc,
    input  wire [23:0] i_p18,
    output wire        o_tx
);

    localparam [24:0] REPORT_CLKS = 25'd10_000_000; // 0.2 s at 50 MHz
    localparam [8:0]  BAUD_DIV    = 9'd434;         // 50e6 / 115200
    localparam [8:0]  LEN         = 9'd347;

    reg [15:0] c_sst, c_snx, c_sdn;
    reg        d_sst, d_snx, d_sdn;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            c_sst <= 16'd0; c_snx <= 16'd0; c_sdn <= 16'd0;
            d_sst <= 1'b0;  d_snx <= 1'b0;  d_sdn <= 1'b0;
        end else begin
            d_sst <= i_sst_p; d_snx <= i_snx_p; d_sdn <= i_sdn_p;
            if (i_sst_p && !d_sst) c_sst <= c_sst + 16'd1;
            if (i_snx_p && !d_snx) c_snx <= c_snx + 16'd1;
            if (i_sdn_p && !d_sdn) c_sdn <= c_sdn + 16'd1;
        end
    end

    wire [3:0] pad_seen = {3'd0, i_seen};
    wire [3:0] pad_busy = {3'd0, i_busy};
    wire [3:0] pad_err = {3'd0, i_err};
    wire [3:0] pad_dne = {3'd0, i_dne};
    wire [3:0] pad_por = {3'd0, i_por};
    wire [3:0] pad_flu = {3'd0, i_flu};
    wire [3:0] pad_kil = i_kil;
    wire [3:0] pad_ret = i_ret;
    wire [3:0] pad_wft = {3'd0, i_wft};
    wire [3:0] pad_gm = {3'd0, i_gm};
    wire [3:0] pad_ca = {3'd0, i_ca};
    wire [3:0] pad_ctrl = {1'd0, i_ctrl};
    wire [3:0] pad_init = i_init;
    wire [39:0] pad_rsp = i_rsp;
    wire [3:0] pad_rd = {1'd0, i_rd};
    wire [7:0] pad_rdt = i_rdt;
    wire [7:0] pad_div = {2'd0, i_div};
    wire [3:0] pad_spik = {3'd0, i_spik};
    wire [3:0] pad_cnt = i_cnt;
    wire [3:0] pad_sel = {2'd0, i_sel};
    wire [3:0] pad_ads = {3'd0, i_ads};
    wire [3:0] pad_dds = {3'd0, i_dds};
    wire [3:0] pad_csn = {3'd0, i_csn};
    wire [3:0] pad_mos = {3'd0, i_mos};
    wire [3:0] pad_sck = {3'd0, i_sck};
    wire [3:0] pad_miso = {3'd0, i_miso};
    wire [15:0] pad_sst = c_sst;
    wire [15:0] pad_snx = c_snx;
    wire [15:0] pad_sdn = c_sdn;
    wire [11:0] pad_acc = {1'd0, i_acc};
    wire [31:0] pad_off = i_off;
    wire [3:0] pad_vld = {3'd0, i_vld};
    wire [3:0] pad_w2f = {3'd0, i_w2f};
    wire [3:0] pad_r2e = {3'd0, i_r2e};
    wire [3:0] pad_hb = {3'd0, i_hb};
    wire [15:0] pad_mise = i_mise;
    wire [7:0]  pad_sw = i_sw;
    wire [3:0]  pad_ls = {1'b0, i_ls};
    wire [9:0]  pad_wc = i_wc;
    wire [3:0]  pad_cbu = {3'b0, i_cbu};
    wire [15:0] pad_sprc = i_sprc;
    wire [3:0]  pad_cfl = i_cfl;
    wire [9:0]  pad_pc  = i_pc;
    wire [15:0] pad_dwc = i_dwc;
    wire [23:0] pad_p0  = i_p0;
    wire [15:0] pad_rc  = i_rc;
    wire [23:0] pad_p18 = i_p18;
    wire [15:0] pad_sce = i_sce;

    function [7:0] hx; input [3:0] n;
        hx = (n < 4'd10) ? (8'd48 + {4'd0,n}) : (8'd65 + {4'd0,n} - 8'd10);
    endfunction

    // All hexadecimal digits share one live-data nibble selector/encoder.
    function [3:0] nibble_at; input [6:0] n;
        reg [511:0] packed_digits;
        begin
            packed_digits={84'd0,
                pad_p18[3  -: 4],
                pad_p18[7  -: 4],
                pad_p18[11 -: 4],
                pad_p18[15 -: 4],
                pad_p18[19 -: 4],
                pad_p18[23 -: 4],
                pad_rc[3 -: 4],
                pad_rc[7 -: 4],
                pad_rc[11 -: 4],
                pad_rc[15 -: 4],
                pad_p0[3  -: 4],
                pad_p0[7  -: 4],
                pad_p0[11 -: 4],
                pad_p0[15 -: 4],
                pad_p0[19 -: 4],
                pad_p0[23 -: 4],
                pad_dwc[3 -: 4],
                pad_dwc[7 -: 4],
                pad_dwc[11 -: 4],
                pad_dwc[15 -: 4],
                pad_pc[3:0],
                pad_pc[7:4],
                {2'b0, pad_pc[9:8]},
                pad_cfl,
                pad_sprc[3 -: 4],
                pad_sprc[7 -: 4],
                pad_sprc[11 -: 4],
                pad_sprc[15 -: 4],
                pad_cbu[3:0],
                pad_wc[3:0],
                pad_wc[7:4],
                {2'b00,pad_wc[9:8]},
                pad_ls[3:0],
                pad_sw[3:0],
                pad_sw[7:4],
                pad_sce[3 -: 4],
                pad_sce[7 -: 4],
                pad_sce[11 -: 4],
                pad_sce[15 -: 4],
                pad_mise[3 -: 4],
                pad_mise[7 -: 4],
                pad_mise[11 -: 4],
                pad_mise[15 -: 4],
                pad_hb[3 -: 4],
                pad_r2e[3 -: 4],
                pad_w2f[3 -: 4],
                pad_vld[3 -: 4],
                pad_off[3 -: 4],
                pad_off[7 -: 4],
                pad_off[11 -: 4],
                pad_off[15 -: 4],
                pad_off[19 -: 4],
                pad_off[23 -: 4],
                pad_off[27 -: 4],
                pad_off[31 -: 4],
                pad_acc[3 -: 4],
                pad_acc[7 -: 4],
                pad_acc[11 -: 4],
                pad_sdn[3 -: 4],
                pad_sdn[7 -: 4],
                pad_sdn[11 -: 4],
                pad_sdn[15 -: 4],
                pad_snx[3 -: 4],
                pad_snx[7 -: 4],
                pad_snx[11 -: 4],
                pad_snx[15 -: 4],
                pad_sst[3 -: 4],
                pad_sst[7 -: 4],
                pad_sst[11 -: 4],
                pad_sst[15 -: 4],
                pad_miso[3 -: 4],
                pad_sck[3 -: 4],
                pad_mos[3 -: 4],
                pad_csn[3 -: 4],
                pad_dds[3 -: 4],
                pad_ads[3 -: 4],
                pad_sel[3 -: 4],
                pad_cnt[3 -: 4],
                pad_spik[3 -: 4],
                pad_div[3 -: 4],
                pad_div[7 -: 4],
                pad_rdt[3 -: 4],
                pad_rdt[7 -: 4],
                pad_rd[3 -: 4],
                pad_rsp[3 -: 4],
                pad_rsp[7 -: 4],
                pad_rsp[11 -: 4],
                pad_rsp[15 -: 4],
                pad_rsp[19 -: 4],
                pad_rsp[23 -: 4],
                pad_rsp[27 -: 4],
                pad_rsp[31 -: 4],
                pad_rsp[35 -: 4],
                pad_rsp[39 -: 4],
                pad_init[3 -: 4],
                pad_ctrl[3 -: 4],
                pad_ca[3 -: 4],
                pad_gm[3 -: 4],
                pad_wft[3 -: 4],
                pad_ret[3 -: 4],
                pad_kil[3 -: 4],
                pad_flu[3 -: 4],
                pad_por[3 -: 4],
                pad_dne[3 -: 4],
                pad_err[3 -: 4],
                pad_busy[3 -: 4],
                pad_seen[3 -: 4]};
            nibble_at=packed_digits[{n,2'b00}+:4];
        end
    endfunction

    reg [24:0] tick;
    reg [8:0]  baud, pos;
    reg [3:0]  st;
    reg [2:0]  bitidx;
    reg [7:0]  shifter;

    // One synchronous 512x8 constant ROM replaces the wide character mux.
    // During each 4340-clock UART byte, prefetch the following format token.
    // A token is either literal ASCII or {1, dense_nibble_index[6:0]}.
    (* ram_style="block" *) reg [7:0] format_rom[0:511];
    reg [7:0] format_token;integer format_init;
    initial begin
        for(format_init=0;format_init<512;format_init=format_init+1)format_rom[format_init]=8'd32;
        format_rom[0]=8'd65;
        format_rom[1]=8'd32;
        format_rom[2]=8'd83;
        format_rom[3]=8'd69;
        format_rom[4]=8'd69;
        format_rom[5]=8'd78;
        format_rom[6]=8'd61;
        format_rom[7]=8'h80;
        format_rom[8]=8'd32;
        format_rom[9]=8'd66;
        format_rom[10]=8'd85;
        format_rom[11]=8'd83;
        format_rom[12]=8'd89;
        format_rom[13]=8'd61;
        format_rom[14]=8'h81;
        format_rom[15]=8'd32;
        format_rom[16]=8'd69;
        format_rom[17]=8'd82;
        format_rom[18]=8'd82;
        format_rom[19]=8'd61;
        format_rom[20]=8'h82;
        format_rom[21]=8'd32;
        format_rom[22]=8'd68;
        format_rom[23]=8'd78;
        format_rom[24]=8'd69;
        format_rom[25]=8'd61;
        format_rom[26]=8'h83;
        format_rom[27]=8'd32;
        format_rom[28]=8'd80;
        format_rom[29]=8'd79;
        format_rom[30]=8'd82;
        format_rom[31]=8'd61;
        format_rom[32]=8'h84;
        format_rom[33]=8'd32;
        format_rom[34]=8'd70;
        format_rom[35]=8'd76;
        format_rom[36]=8'd85;
        format_rom[37]=8'd61;
        format_rom[38]=8'h85;
        format_rom[39]=8'd32;
        format_rom[40]=8'd75;
        format_rom[41]=8'd73;
        format_rom[42]=8'd76;
        format_rom[43]=8'd61;
        format_rom[44]=8'h86;
        format_rom[45]=8'd32;
        format_rom[46]=8'd82;
        format_rom[47]=8'd69;
        format_rom[48]=8'd84;
        format_rom[49]=8'd61;
        format_rom[50]=8'h87;
        format_rom[51]=8'd32;
        format_rom[52]=8'd87;
        format_rom[53]=8'd70;
        format_rom[54]=8'd84;
        format_rom[55]=8'd61;
        format_rom[56]=8'h88;
        format_rom[57]=8'd32;
        format_rom[58]=8'd71;
        format_rom[59]=8'd77;
        format_rom[60]=8'd61;
        format_rom[61]=8'h89;
        format_rom[62]=8'd32;
        format_rom[63]=8'd67;
        format_rom[64]=8'd65;
        format_rom[65]=8'd61;
        format_rom[66]=8'h8A;
        format_rom[67]=8'd10;
        format_rom[68]=8'd66;
        format_rom[69]=8'd32;
        format_rom[70]=8'd67;
        format_rom[71]=8'd84;
        format_rom[72]=8'd82;
        format_rom[73]=8'd76;
        format_rom[74]=8'd61;
        format_rom[75]=8'h8B;
        format_rom[76]=8'd32;
        format_rom[77]=8'd73;
        format_rom[78]=8'd78;
        format_rom[79]=8'd73;
        format_rom[80]=8'd84;
        format_rom[81]=8'd61;
        format_rom[82]=8'h8C;
        format_rom[83]=8'd32;
        format_rom[84]=8'd82;
        format_rom[85]=8'd83;
        format_rom[86]=8'd80;
        format_rom[87]=8'd61;
        format_rom[88]=8'h8D;
        format_rom[89]=8'h8E;
        format_rom[90]=8'h8F;
        format_rom[91]=8'h90;
        format_rom[92]=8'h91;
        format_rom[93]=8'h92;
        format_rom[94]=8'h93;
        format_rom[95]=8'h94;
        format_rom[96]=8'h95;
        format_rom[97]=8'h96;
        format_rom[98]=8'd32;
        format_rom[99]=8'd82;
        format_rom[100]=8'd68;
        format_rom[101]=8'd61;
        format_rom[102]=8'h97;
        format_rom[103]=8'd32;
        format_rom[104]=8'd82;
        format_rom[105]=8'd68;
        format_rom[106]=8'd84;
        format_rom[107]=8'd61;
        format_rom[108]=8'h98;
        format_rom[109]=8'h99;
        format_rom[110]=8'd32;
        format_rom[111]=8'd68;
        format_rom[112]=8'd73;
        format_rom[113]=8'd86;
        format_rom[114]=8'd61;
        format_rom[115]=8'h9A;
        format_rom[116]=8'h9B;
        format_rom[117]=8'd32;
        format_rom[118]=8'd83;
        format_rom[119]=8'd80;
        format_rom[120]=8'd73;
        format_rom[121]=8'd75;
        format_rom[122]=8'd61;
        format_rom[123]=8'h9C;
        format_rom[124]=8'd32;
        format_rom[125]=8'd67;
        format_rom[126]=8'd78;
        format_rom[127]=8'd84;
        format_rom[128]=8'd61;
        format_rom[129]=8'h9D;
        format_rom[130]=8'd32;
        format_rom[131]=8'd83;
        format_rom[132]=8'd69;
        format_rom[133]=8'd76;
        format_rom[134]=8'd61;
        format_rom[135]=8'h9E;
        format_rom[136]=8'd32;
        format_rom[137]=8'd65;
        format_rom[138]=8'd68;
        format_rom[139]=8'd83;
        format_rom[140]=8'd61;
        format_rom[141]=8'h9F;
        format_rom[142]=8'd32;
        format_rom[143]=8'd68;
        format_rom[144]=8'd68;
        format_rom[145]=8'd83;
        format_rom[146]=8'd61;
        format_rom[147]=8'hA0;
        format_rom[148]=8'd32;
        format_rom[149]=8'd67;
        format_rom[150]=8'd83;
        format_rom[151]=8'd78;
        format_rom[152]=8'd61;
        format_rom[153]=8'hA1;
        format_rom[154]=8'd32;
        format_rom[155]=8'd77;
        format_rom[156]=8'd79;
        format_rom[157]=8'd83;
        format_rom[158]=8'd61;
        format_rom[159]=8'hA2;
        format_rom[160]=8'd32;
        format_rom[161]=8'd83;
        format_rom[162]=8'd67;
        format_rom[163]=8'd75;
        format_rom[164]=8'd61;
        format_rom[165]=8'hA3;
        format_rom[166]=8'd32;
        format_rom[167]=8'd77;
        format_rom[168]=8'd73;
        format_rom[169]=8'd83;
        format_rom[170]=8'd79;
        format_rom[171]=8'd61;
        format_rom[172]=8'hA4;
        format_rom[173]=8'd10;
        format_rom[174]=8'd67;
        format_rom[175]=8'd32;
        format_rom[176]=8'd83;
        format_rom[177]=8'd83;
        format_rom[178]=8'd84;
        format_rom[179]=8'd61;
        format_rom[180]=8'hA5;
        format_rom[181]=8'hA6;
        format_rom[182]=8'hA7;
        format_rom[183]=8'hA8;
        format_rom[184]=8'd32;
        format_rom[185]=8'd83;
        format_rom[186]=8'd78;
        format_rom[187]=8'd88;
        format_rom[188]=8'd61;
        format_rom[189]=8'hA9;
        format_rom[190]=8'hAA;
        format_rom[191]=8'hAB;
        format_rom[192]=8'hAC;
        format_rom[193]=8'd32;
        format_rom[194]=8'd83;
        format_rom[195]=8'd68;
        format_rom[196]=8'd78;
        format_rom[197]=8'd61;
        format_rom[198]=8'hAD;
        format_rom[199]=8'hAE;
        format_rom[200]=8'hAF;
        format_rom[201]=8'hB0;
        format_rom[202]=8'd32;
        format_rom[203]=8'd65;
        format_rom[204]=8'd67;
        format_rom[205]=8'd67;
        format_rom[206]=8'd61;
        format_rom[207]=8'hB1;
        format_rom[208]=8'hB2;
        format_rom[209]=8'hB3;
        format_rom[210]=8'd32;
        format_rom[211]=8'd79;
        format_rom[212]=8'd70;
        format_rom[213]=8'd70;
        format_rom[214]=8'd61;
        format_rom[215]=8'hB4;
        format_rom[216]=8'hB5;
        format_rom[217]=8'hB6;
        format_rom[218]=8'hB7;
        format_rom[219]=8'hB8;
        format_rom[220]=8'hB9;
        format_rom[221]=8'hBA;
        format_rom[222]=8'hBB;
        format_rom[223]=8'd32;
        format_rom[224]=8'd86;
        format_rom[225]=8'd76;
        format_rom[226]=8'd68;
        format_rom[227]=8'd61;
        format_rom[228]=8'hBC;
        format_rom[229]=8'd32;
        format_rom[230]=8'd87;
        format_rom[231]=8'd50;
        format_rom[232]=8'd70;
        format_rom[233]=8'd61;
        format_rom[234]=8'hBD;
        format_rom[235]=8'd32;
        format_rom[236]=8'd82;
        format_rom[237]=8'd50;
        format_rom[238]=8'd69;
        format_rom[239]=8'd61;
        format_rom[240]=8'hBE;
        format_rom[241]=8'd32;
        format_rom[242]=8'd72;
        format_rom[243]=8'd66;
        format_rom[244]=8'd61;
        format_rom[245]=8'hBF;
        format_rom[246]=8'd10;
        format_rom[247]=8'd68;
        format_rom[248]=8'd32;
        format_rom[249]=8'd77;
        format_rom[250]=8'd73;
        format_rom[251]=8'd83;
        format_rom[252]=8'd69;
        format_rom[253]=8'd61;
        format_rom[254]=8'hC0;
        format_rom[255]=8'hC1;
        format_rom[256]=8'hC2;
        format_rom[257]=8'hC3;
        format_rom[258]=8'd32;
        format_rom[259]=8'd83;
        format_rom[260]=8'd67;
        format_rom[261]=8'd69;
        format_rom[262]=8'd61;
        format_rom[263]=8'hC4;
        format_rom[264]=8'hC5;
        format_rom[265]=8'hC6;
        format_rom[266]=8'hC7;
        format_rom[267]=8'd32;
        format_rom[268]=8'd32;
        format_rom[269]=8'd83;
        format_rom[270]=8'd87;
        format_rom[271]=8'd61;
        format_rom[272]=8'hC8;
        format_rom[273]=8'hC9;
        format_rom[274]=8'd32;
        format_rom[275]=8'd76;
        format_rom[276]=8'd83;
        format_rom[277]=8'd61;
        format_rom[278]=8'hCA;
        format_rom[279]=8'd32;
        format_rom[280]=8'd87;
        format_rom[281]=8'd67;
        format_rom[282]=8'd61;
        format_rom[283]=8'hCB;
        format_rom[284]=8'hCC;
        format_rom[285]=8'hCD;
        format_rom[286]=8'd32;
        format_rom[287]=8'd66;
        format_rom[288]=8'd85;
        format_rom[289]=8'd61;
        format_rom[290]=8'hCE;
        format_rom[291]=8'd32;
        format_rom[292]=8'd83;
        format_rom[293]=8'd80;
        format_rom[294]=8'd61;
        format_rom[295]=8'hCF;
        format_rom[296]=8'hD0;
        format_rom[297]=8'hD1;
        format_rom[298]=8'hD2;
        format_rom[299]=8'd32;
        format_rom[300]=8'd70;
        format_rom[301]=8'd61;
        format_rom[302]=8'hD3;
        format_rom[303]=8'd32;
        format_rom[304]=8'd80;
        format_rom[305]=8'd67;
        format_rom[306]=8'd61;
        format_rom[307]=8'hD4;
        format_rom[308]=8'hD5;
        format_rom[309]=8'hD6;
        format_rom[310]=8'd32;
        format_rom[311]=8'd68;
        format_rom[312]=8'd87;
        format_rom[313]=8'd61;
        format_rom[314]=8'hD7;
        format_rom[315]=8'hD8;
        format_rom[316]=8'hD9;
        format_rom[317]=8'hDA;
        format_rom[318]=8'd32;
        format_rom[319]=8'd73;
        format_rom[320]=8'd48;
        format_rom[321]=8'd61;
        format_rom[322]=8'hDB;
        format_rom[323]=8'hDC;
        format_rom[324]=8'hDD;
        format_rom[325]=8'hDE;
        format_rom[326]=8'hDF;
        format_rom[327]=8'hE0;
        format_rom[328]=8'd32;
        format_rom[329]=8'd82;
        format_rom[330]=8'd67;
        format_rom[331]=8'd61;
        format_rom[332]=8'hE1;
        format_rom[333]=8'hE2;
        format_rom[334]=8'hE3;
        format_rom[335]=8'hE4;
        format_rom[336]=8'd32;
        format_rom[337]=8'd73;
        format_rom[338]=8'd49;
        format_rom[339]=8'd61;
        format_rom[340]=8'hE5;
        format_rom[341]=8'hE6;
        format_rom[342]=8'hE7;
        format_rom[343]=8'hE8;
        format_rom[344]=8'hE9;
        format_rom[345]=8'hEA;
        format_rom[346]=8'd10;
    end
    always @(posedge i_clk) format_token<=format_rom[pos+9'd1];

    assign o_tx = (st == 4'd1) ? 1'b0 :
                  (st == 4'd2) ? shifter[bitidx] : 1'b1;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            st <= 4'd0; baud <= 9'd0; bitidx <= 3'd0; shifter <= 8'd0;
            pos <= 9'd0; tick <= REPORT_CLKS;
        end else begin
            if (tick != 25'd0) tick <= tick - 25'd1;
            case (st)
                4'd0: if (tick == 25'd0) begin
                          pos <= 9'd0; shifter <= 8'd65; // first literal is A
                          baud <= 9'd0; st <= 4'd1;
                        end
                4'd1: if (baud == BAUD_DIV - 9'd1) begin
                          baud <= 9'd0; bitidx <= 3'd0; st <= 4'd2;
                        end else baud <= baud + 9'd1;
                4'd2: if (baud == BAUD_DIV - 9'd1) begin
                          baud <= 9'd0;
                          if (bitidx == 3'd7) st <= 4'd3;
                          else bitidx <= bitidx + 3'd1;
                        end else baud <= baud + 9'd1;
                4'd3: if (baud == BAUD_DIV - 9'd1) begin
                          baud <= 9'd0;
                          if (pos == LEN - 9'd1) begin
                              st <= 4'd0; tick <= REPORT_CLKS;
                          end else begin
                              pos <= pos + 9'd1;
                              shifter <= format_token[7] ? hx(nibble_at(format_token[6:0])):format_token;
                              st <= 4'd1;
                          end
                        end else baud <= baud + 9'd1;
                default: st <= 4'd0;
            endcase
        end
    end

endmodule

`default_nettype wire