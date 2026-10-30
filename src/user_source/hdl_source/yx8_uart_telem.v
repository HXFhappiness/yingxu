`timescale 1ns / 1ps
`default_nettype none

// yx8_uart_telem - compact fixed-template status line over UART 115200 8N1.
// One report = 3 lines, sent every 0.2 s. Pure diagnostics, temporary.
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

    function [7:0] char_at; input [8:0] p;
        case (p)
            9'd0: char_at = 8'd65;
            9'd1: char_at = 8'd32;
            9'd2: char_at = 8'd83;
            9'd3: char_at = 8'd69;
            9'd4: char_at = 8'd69;
            9'd5: char_at = 8'd78;
            9'd6: char_at = 8'd61;
            9'd7: char_at = hx(pad_seen[3 -: 4]);
            9'd8: char_at = 8'd32;
            9'd9: char_at = 8'd66;
            9'd10: char_at = 8'd85;
            9'd11: char_at = 8'd83;
            9'd12: char_at = 8'd89;
            9'd13: char_at = 8'd61;
            9'd14: char_at = hx(pad_busy[3 -: 4]);
            9'd15: char_at = 8'd32;
            9'd16: char_at = 8'd69;
            9'd17: char_at = 8'd82;
            9'd18: char_at = 8'd82;
            9'd19: char_at = 8'd61;
            9'd20: char_at = hx(pad_err[3 -: 4]);
            9'd21: char_at = 8'd32;
            9'd22: char_at = 8'd68;
            9'd23: char_at = 8'd78;
            9'd24: char_at = 8'd69;
            9'd25: char_at = 8'd61;
            9'd26: char_at = hx(pad_dne[3 -: 4]);
            9'd27: char_at = 8'd32;
            9'd28: char_at = 8'd80;
            9'd29: char_at = 8'd79;
            9'd30: char_at = 8'd82;
            9'd31: char_at = 8'd61;
            9'd32: char_at = hx(pad_por[3 -: 4]);
            9'd33: char_at = 8'd32;
            9'd34: char_at = 8'd70;
            9'd35: char_at = 8'd76;
            9'd36: char_at = 8'd85;
            9'd37: char_at = 8'd61;
            9'd38: char_at = hx(pad_flu[3 -: 4]);
            9'd39: char_at = 8'd32;
            9'd40: char_at = 8'd75;
            9'd41: char_at = 8'd73;
            9'd42: char_at = 8'd76;
            9'd43: char_at = 8'd61;
            9'd44: char_at = hx(pad_kil[3 -: 4]);
            9'd45: char_at = 8'd32;
            9'd46: char_at = 8'd82;
            9'd47: char_at = 8'd69;
            9'd48: char_at = 8'd84;
            9'd49: char_at = 8'd61;
            9'd50: char_at = hx(pad_ret[3 -: 4]);
            9'd51: char_at = 8'd32;
            9'd52: char_at = 8'd87;
            9'd53: char_at = 8'd70;
            9'd54: char_at = 8'd84;
            9'd55: char_at = 8'd61;
            9'd56: char_at = hx(pad_wft[3 -: 4]);
            9'd57: char_at = 8'd32;
            9'd58: char_at = 8'd71;
            9'd59: char_at = 8'd77;
            9'd60: char_at = 8'd61;
            9'd61: char_at = hx(pad_gm[3 -: 4]);
            9'd62: char_at = 8'd32;
            9'd63: char_at = 8'd67;
            9'd64: char_at = 8'd65;
            9'd65: char_at = 8'd61;
            9'd66: char_at = hx(pad_ca[3 -: 4]);
            9'd67: char_at = 8'd10;
            9'd68: char_at = 8'd66;
            9'd69: char_at = 8'd32;
            9'd70: char_at = 8'd67;
            9'd71: char_at = 8'd84;
            9'd72: char_at = 8'd82;
            9'd73: char_at = 8'd76;
            9'd74: char_at = 8'd61;
            9'd75: char_at = hx(pad_ctrl[3 -: 4]);
            9'd76: char_at = 8'd32;
            9'd77: char_at = 8'd73;
            9'd78: char_at = 8'd78;
            9'd79: char_at = 8'd73;
            9'd80: char_at = 8'd84;
            9'd81: char_at = 8'd61;
            9'd82: char_at = hx(pad_init[3 -: 4]);
            9'd83: char_at = 8'd32;
            9'd84: char_at = 8'd82;
            9'd85: char_at = 8'd83;
            9'd86: char_at = 8'd80;
            9'd87: char_at = 8'd61;
            9'd88: char_at = hx(pad_rsp[39 -: 4]);
            9'd89: char_at = hx(pad_rsp[35 -: 4]);
            9'd90: char_at = hx(pad_rsp[31 -: 4]);
            9'd91: char_at = hx(pad_rsp[27 -: 4]);
            9'd92: char_at = hx(pad_rsp[23 -: 4]);
            9'd93: char_at = hx(pad_rsp[19 -: 4]);
            9'd94: char_at = hx(pad_rsp[15 -: 4]);
            9'd95: char_at = hx(pad_rsp[11 -: 4]);
            9'd96: char_at = hx(pad_rsp[7 -: 4]);
            9'd97: char_at = hx(pad_rsp[3 -: 4]);
            9'd98: char_at = 8'd32;
            9'd99: char_at = 8'd82;
            9'd100: char_at = 8'd68;
            9'd101: char_at = 8'd61;
            9'd102: char_at = hx(pad_rd[3 -: 4]);
            9'd103: char_at = 8'd32;
            9'd104: char_at = 8'd82;
            9'd105: char_at = 8'd68;
            9'd106: char_at = 8'd84;
            9'd107: char_at = 8'd61;
            9'd108: char_at = hx(pad_rdt[7 -: 4]);
            9'd109: char_at = hx(pad_rdt[3 -: 4]);
            9'd110: char_at = 8'd32;
            9'd111: char_at = 8'd68;
            9'd112: char_at = 8'd73;
            9'd113: char_at = 8'd86;
            9'd114: char_at = 8'd61;
            9'd115: char_at = hx(pad_div[7 -: 4]);
            9'd116: char_at = hx(pad_div[3 -: 4]);
            9'd117: char_at = 8'd32;
            9'd118: char_at = 8'd83;
            9'd119: char_at = 8'd80;
            9'd120: char_at = 8'd73;
            9'd121: char_at = 8'd75;
            9'd122: char_at = 8'd61;
            9'd123: char_at = hx(pad_spik[3 -: 4]);
            9'd124: char_at = 8'd32;
            9'd125: char_at = 8'd67;
            9'd126: char_at = 8'd78;
            9'd127: char_at = 8'd84;
            9'd128: char_at = 8'd61;
            9'd129: char_at = hx(pad_cnt[3 -: 4]);
            9'd130: char_at = 8'd32;
            9'd131: char_at = 8'd83;
            9'd132: char_at = 8'd69;
            9'd133: char_at = 8'd76;
            9'd134: char_at = 8'd61;
            9'd135: char_at = hx(pad_sel[3 -: 4]);
            9'd136: char_at = 8'd32;
            9'd137: char_at = 8'd65;
            9'd138: char_at = 8'd68;
            9'd139: char_at = 8'd83;
            9'd140: char_at = 8'd61;
            9'd141: char_at = hx(pad_ads[3 -: 4]);
            9'd142: char_at = 8'd32;
            9'd143: char_at = 8'd68;
            9'd144: char_at = 8'd68;
            9'd145: char_at = 8'd83;
            9'd146: char_at = 8'd61;
            9'd147: char_at = hx(pad_dds[3 -: 4]);
            9'd148: char_at = 8'd32;
            9'd149: char_at = 8'd67;
            9'd150: char_at = 8'd83;
            9'd151: char_at = 8'd78;
            9'd152: char_at = 8'd61;
            9'd153: char_at = hx(pad_csn[3 -: 4]);
            9'd154: char_at = 8'd32;
            9'd155: char_at = 8'd77;
            9'd156: char_at = 8'd79;
            9'd157: char_at = 8'd83;
            9'd158: char_at = 8'd61;
            9'd159: char_at = hx(pad_mos[3 -: 4]);
            9'd160: char_at = 8'd32;
            9'd161: char_at = 8'd83;
            9'd162: char_at = 8'd67;
            9'd163: char_at = 8'd75;
            9'd164: char_at = 8'd61;
            9'd165: char_at = hx(pad_sck[3 -: 4]);
            9'd166: char_at = 8'd32;
            9'd167: char_at = 8'd77;
            9'd168: char_at = 8'd73;
            9'd169: char_at = 8'd83;
            9'd170: char_at = 8'd79;
            9'd171: char_at = 8'd61;
            9'd172: char_at = hx(pad_miso[3 -: 4]);
            9'd173: char_at = 8'd10;
            9'd174: char_at = 8'd67;
            9'd175: char_at = 8'd32;
            9'd176: char_at = 8'd83;
            9'd177: char_at = 8'd83;
            9'd178: char_at = 8'd84;
            9'd179: char_at = 8'd61;
            9'd180: char_at = hx(pad_sst[15 -: 4]);
            9'd181: char_at = hx(pad_sst[11 -: 4]);
            9'd182: char_at = hx(pad_sst[7 -: 4]);
            9'd183: char_at = hx(pad_sst[3 -: 4]);
            9'd184: char_at = 8'd32;
            9'd185: char_at = 8'd83;
            9'd186: char_at = 8'd78;
            9'd187: char_at = 8'd88;
            9'd188: char_at = 8'd61;
            9'd189: char_at = hx(pad_snx[15 -: 4]);
            9'd190: char_at = hx(pad_snx[11 -: 4]);
            9'd191: char_at = hx(pad_snx[7 -: 4]);
            9'd192: char_at = hx(pad_snx[3 -: 4]);
            9'd193: char_at = 8'd32;
            9'd194: char_at = 8'd83;
            9'd195: char_at = 8'd68;
            9'd196: char_at = 8'd78;
            9'd197: char_at = 8'd61;
            9'd198: char_at = hx(pad_sdn[15 -: 4]);
            9'd199: char_at = hx(pad_sdn[11 -: 4]);
            9'd200: char_at = hx(pad_sdn[7 -: 4]);
            9'd201: char_at = hx(pad_sdn[3 -: 4]);
            9'd202: char_at = 8'd32;
            9'd203: char_at = 8'd65;
            9'd204: char_at = 8'd67;
            9'd205: char_at = 8'd67;
            9'd206: char_at = 8'd61;
            9'd207: char_at = hx(pad_acc[11 -: 4]);
            9'd208: char_at = hx(pad_acc[7 -: 4]);
            9'd209: char_at = hx(pad_acc[3 -: 4]);
            9'd210: char_at = 8'd32;
            9'd211: char_at = 8'd79;
            9'd212: char_at = 8'd70;
            9'd213: char_at = 8'd70;
            9'd214: char_at = 8'd61;
            9'd215: char_at = hx(pad_off[31 -: 4]);
            9'd216: char_at = hx(pad_off[27 -: 4]);
            9'd217: char_at = hx(pad_off[23 -: 4]);
            9'd218: char_at = hx(pad_off[19 -: 4]);
            9'd219: char_at = hx(pad_off[15 -: 4]);
            9'd220: char_at = hx(pad_off[11 -: 4]);
            9'd221: char_at = hx(pad_off[7 -: 4]);
            9'd222: char_at = hx(pad_off[3 -: 4]);
            9'd223: char_at = 8'd32;
            9'd224: char_at = 8'd86;
            9'd225: char_at = 8'd76;
            9'd226: char_at = 8'd68;
            9'd227: char_at = 8'd61;
            9'd228: char_at = hx(pad_vld[3 -: 4]);
            9'd229: char_at = 8'd32;
            9'd230: char_at = 8'd87;
            9'd231: char_at = 8'd50;
            9'd232: char_at = 8'd70;
            9'd233: char_at = 8'd61;
            9'd234: char_at = hx(pad_w2f[3 -: 4]);
            9'd235: char_at = 8'd32;
            9'd236: char_at = 8'd82;
            9'd237: char_at = 8'd50;
            9'd238: char_at = 8'd69;
            9'd239: char_at = 8'd61;
            9'd240: char_at = hx(pad_r2e[3 -: 4]);
            9'd241: char_at = 8'd32;
            9'd242: char_at = 8'd72;
            9'd243: char_at = 8'd66;
            9'd244: char_at = 8'd61;
            9'd245: char_at = hx(pad_hb[3 -: 4]);
            9'd246: char_at = 8'd10;
            9'd247: char_at = 8'd68;
            9'd248: char_at = 8'd32;
            9'd249: char_at = 8'd77;
            9'd250: char_at = 8'd73;
            9'd251: char_at = 8'd83;
            9'd252: char_at = 8'd69;
            9'd253: char_at = 8'd61;
            9'd254: char_at = hx(pad_mise[15 -: 4]);
            9'd255: char_at = hx(pad_mise[11 -: 4]);
            9'd256: char_at = hx(pad_mise[7 -: 4]);
            9'd257: char_at = hx(pad_mise[3 -: 4]);
            9'd258: char_at = 8'd32;
            9'd259: char_at = 8'd83;
            9'd260: char_at = 8'd67;
            9'd261: char_at = 8'd69;
            9'd262: char_at = 8'd61;
            9'd263: char_at = hx(pad_sce[15 -: 4]);
            9'd264: char_at = hx(pad_sce[11 -: 4]);
            9'd265: char_at = hx(pad_sce[7 -: 4]);
            9'd266: char_at = hx(pad_sce[3 -: 4]);
            9'd267: char_at = 8'd32;
            9'd268: char_at = 8'd32;
            9'd269: char_at = 8'd83;
            9'd270: char_at = 8'd87;
            9'd271: char_at = 8'd61;
            9'd272: char_at = hx(pad_sw[7:4]);
            9'd273: char_at = hx(pad_sw[3:0]);
            9'd274: char_at = 8'd32;
            9'd275: char_at = 8'd76;
            9'd276: char_at = 8'd83;
            9'd277: char_at = 8'd61;
            9'd278: char_at = hx(pad_ls[3:0]);
            9'd279: char_at = 8'd32;
            9'd280: char_at = 8'd87;
            9'd281: char_at = 8'd67;
            9'd282: char_at = 8'd61;
            9'd283: char_at = hx(pad_wc[9:8]);
            9'd284: char_at = hx(pad_wc[7:4]);
            9'd285: char_at = hx(pad_wc[3:0]);
            9'd286: char_at = 8'd32;
            9'd287: char_at = 8'd66;
            9'd288: char_at = 8'd85;
            9'd289: char_at = 8'd61;
            9'd290: char_at = hx(pad_cbu[3:0]);
            9'd291: char_at = 8'd32;
            9'd292: char_at = 8'd83;
            9'd293: char_at = 8'd80;
            9'd294: char_at = 8'd61;
            9'd295: char_at = hx(pad_sprc[15 -: 4]);
            9'd296: char_at = hx(pad_sprc[11 -: 4]);
            9'd297: char_at = hx(pad_sprc[7 -: 4]);
            9'd298: char_at = hx(pad_sprc[3 -: 4]);
            9'd299: char_at = 8'd32;
            9'd300: char_at = 8'd70;
            9'd301: char_at = 8'd61;
            9'd302: char_at = hx(pad_cfl);
            9'd303: char_at = 8'd32;
            9'd304: char_at = 8'd80;
            9'd305: char_at = 8'd67;
            9'd306: char_at = 8'd61;
            9'd307: char_at = hx({2'b0, pad_pc[9:8]});
            9'd308: char_at = hx(pad_pc[7:4]);
            9'd309: char_at = hx(pad_pc[3:0]);
            9'd310: char_at = 8'd32;
            9'd311: char_at = 8'd68;
            9'd312: char_at = 8'd87;
            9'd313: char_at = 8'd61;
            9'd314: char_at = hx(pad_dwc[15 -: 4]);
            9'd315: char_at = hx(pad_dwc[11 -: 4]);
            9'd316: char_at = hx(pad_dwc[7 -: 4]);
            9'd317: char_at = hx(pad_dwc[3 -: 4]);
            9'd318: char_at = 8'd32;
            9'd319: char_at = 8'd73;
            9'd320: char_at = 8'd48;
            9'd321: char_at = 8'd61;
            9'd322: char_at = hx(pad_p0[23 -: 4]);
            9'd323: char_at = hx(pad_p0[19 -: 4]);
            9'd324: char_at = hx(pad_p0[15 -: 4]);
            9'd325: char_at = hx(pad_p0[11 -: 4]);
            9'd326: char_at = hx(pad_p0[7  -: 4]);
            9'd327: char_at = hx(pad_p0[3  -: 4]);
            9'd328: char_at = 8'd32;
            9'd329: char_at = 8'd82;
            9'd330: char_at = 8'd67;
            9'd331: char_at = 8'd61;
            9'd332: char_at = hx(pad_rc[15 -: 4]);
            9'd333: char_at = hx(pad_rc[11 -: 4]);
            9'd334: char_at = hx(pad_rc[7 -: 4]);
            9'd335: char_at = hx(pad_rc[3 -: 4]);
            9'd336: char_at = 8'd32;
            9'd337: char_at = 8'd73;
            9'd338: char_at = 8'd49;
            9'd339: char_at = 8'd61;
            9'd340: char_at = hx(pad_p18[23 -: 4]);
            9'd341: char_at = hx(pad_p18[19 -: 4]);
            9'd342: char_at = hx(pad_p18[15 -: 4]);
            9'd343: char_at = hx(pad_p18[11 -: 4]);
            9'd344: char_at = hx(pad_p18[7  -: 4]);
            9'd345: char_at = hx(pad_p18[3  -: 4]);
            9'd346: char_at = 8'd10;
            default: char_at = 8'd32;
        endcase
    endfunction

    reg [24:0] tick;
    reg [8:0]  baud, pos;
    reg [3:0]  st;
    reg [2:0]  bitidx;
    reg [7:0]  shifter;

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
                          pos <= 9'd0; shifter <= char_at(9'd0);
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
                              shifter <= char_at(pos + 9'd1);
                              st <= 4'd1;
                          end
                        end else baud <= baud + 9'd1;
                default: st <= 4'd0;
            endcase
        end
    end

endmodule

`default_nettype wire