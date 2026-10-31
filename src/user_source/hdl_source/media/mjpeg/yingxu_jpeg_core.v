`timescale 1ns/1ps
`default_nettype none
// SOF0, 640x480, interleaved YCbCr 4:2:0. Dynamic DQT/DHT and DRI/RST.
// Five synchronous inferred RAMs including IDCT/RGB submodules; no frame RAM.
module yingxu_jpeg_core #(parameter integer MAX_CYCLES=8_000_000)(
    input wire clk,rst,start,input wire [15:0] frame_bytes,
    input wire [7:0] byte_data,input wire byte_valid,output wire byte_ready,
    output wire pixel_valid,input wire pixel_ready,output wire [15:0] pixel,
    output wire [9:0] pixel_x,output wire [8:0] pixel_y,
    output reg busy,done,error,output reg [7:0] error_code,
    output reg [31:0] cycles
);
    localparam H_IDLE=0,H_SOI0=1,H_SOI1=2,H_FF=3,H_MARK=4,H_LENH=5,H_LENL=6,
        H_SKIP=7,H_QINFO=8,H_QDATA=9,H_HTINFO=10,H_COUNTS=11,H_SYMBOLS=12,
        H_SOF=13,H_SOS=14,H_DRI=15,H_RUN=16,H_FINISH=17,H_COUNTHIGH=18;
    localparam E_WAITBANK=0,E_CLEAR=1,E_HINIT=2,E_HBIT=3,E_HCHECK=4,E_SYMWAIT=5,
        E_SYMBOL=6,E_AMP=7,E_QWAIT=8,E_QMUL=9,E_STORE=10,E_READY=11,
        E_RST=12,E_EOI=13,E_FINISH=14,E_STOREHI=15,E_HLO=16;
    reg [4:0] hs;reg [4:0] es;
    reg [4:0] header_after;reg [5:0] desc_write_index;reg [15:0] desc_write_high,hfirst;
    reg [15:0] length_r,seg_left,frame_length;
    reg [16:0] seen;
    reg [7:0] marker;
    reg [6:0] index;
    reg sof_seen;
    reg [1:0] qvalid;reg [3:0] hvalid;
    reg qy,qc,dy,ay,dc,ac;
    reg qtable;
    reg [1:0] htable;
    reg [4:0] hlength;
    reg [17:0] build_code;
    reg [8:0] htotal,hindex;
    reg [255:0] symbol_seen;
    reg [15:0] restart_interval,restart_count;
    reg [2:0] restart_number;
    // Packed symbol layout: DC0 @0, DC1 @16, AC0 @64, AC1 @320;
    // two zigzag-order DQTs @576,640. This fits ONE 1024x8 RAM.
    reg [7:0] tables[0:1023];
    reg [9:0] table_addr;reg [7:0] table_q;
    reg [15:0] descriptors[0:127];
    reg [15:0] desc_q;
    reg [15:0] coeff[0:255];
    reg [15:0] coeff_q;
    wire [7:0] coeff_raddr;
    reg bank;reg [1:0] locked;
    reg [6:0] clear_index;
    reg [2:0] block_slot;
    reg [10:0] mcu_index;
    reg [5:0] mx;reg [4:0] my;
    reg ac_phase;
    reg [6:0] coefficient_index;
    reg [3:0] amplitude_size;
    reg [16:0] hcode;reg [3:0] hlen;
    reg signed [15:0] predictor[0:2];
    reg signed [15:0] quantized;
    reg signed [23:0] dequantized;
    reg [31:0] bitbuf;reg [5:0] bit_count;
    reg ff_pending,marker_pending;reg [7:0] pending_marker;
    reg entropy_finished,pixels_finished;
    wire [1:0] component_id=block_slot<4 ? 2'd0 : block_slot==4 ? 2'd1 : 2'd2;
    wire selected_hid=ac_phase ? (block_slot<4 ? ay:ac) : (block_slot<4 ? dy:dc);
    wire [1:0] selected_ht={ac_phase,selected_hid};
    function automatic [9:0] symbol_base(input [1:0] tid);
        begin symbol_base=tid[1] ? (tid[0] ? 10'd320:10'd64) : (tid[0] ? 10'd16:10'd0);end
    endfunction
    function automatic [5:0] zigzag(input [5:0] k);
        begin case(k)
            6'd0: zigzag=6'd0;
            6'd1: zigzag=6'd1;
            6'd2: zigzag=6'd8;
            6'd3: zigzag=6'd16;
            6'd4: zigzag=6'd9;
            6'd5: zigzag=6'd2;
            6'd6: zigzag=6'd3;
            6'd7: zigzag=6'd10;
            6'd8: zigzag=6'd17;
            6'd9: zigzag=6'd24;
            6'd10: zigzag=6'd32;
            6'd11: zigzag=6'd25;
            6'd12: zigzag=6'd18;
            6'd13: zigzag=6'd11;
            6'd14: zigzag=6'd4;
            6'd15: zigzag=6'd5;
            6'd16: zigzag=6'd12;
            6'd17: zigzag=6'd19;
            6'd18: zigzag=6'd26;
            6'd19: zigzag=6'd33;
            6'd20: zigzag=6'd40;
            6'd21: zigzag=6'd48;
            6'd22: zigzag=6'd41;
            6'd23: zigzag=6'd34;
            6'd24: zigzag=6'd27;
            6'd25: zigzag=6'd20;
            6'd26: zigzag=6'd13;
            6'd27: zigzag=6'd6;
            6'd28: zigzag=6'd7;
            6'd29: zigzag=6'd14;
            6'd30: zigzag=6'd21;
            6'd31: zigzag=6'd28;
            6'd32: zigzag=6'd35;
            6'd33: zigzag=6'd42;
            6'd34: zigzag=6'd49;
            6'd35: zigzag=6'd56;
            6'd36: zigzag=6'd57;
            6'd37: zigzag=6'd50;
            6'd38: zigzag=6'd43;
            6'd39: zigzag=6'd36;
            6'd40: zigzag=6'd29;
            6'd41: zigzag=6'd22;
            6'd42: zigzag=6'd15;
            6'd43: zigzag=6'd23;
            6'd44: zigzag=6'd30;
            6'd45: zigzag=6'd37;
            6'd46: zigzag=6'd44;
            6'd47: zigzag=6'd51;
            6'd48: zigzag=6'd58;
            6'd49: zigzag=6'd59;
            6'd50: zigzag=6'd52;
            6'd51: zigzag=6'd45;
            6'd52: zigzag=6'd38;
            6'd53: zigzag=6'd31;
            6'd54: zigzag=6'd39;
            6'd55: zigzag=6'd46;
            6'd56: zigzag=6'd53;
            6'd57: zigzag=6'd60;
            6'd58: zigzag=6'd61;
            6'd59: zigzag=6'd54;
            6'd60: zigzag=6'd47;
            6'd61: zigzag=6'd55;
            6'd62: zigzag=6'd62;
            6'd63: zigzag=6'd63;
            default: zigzag=0;
        endcase end
    endfunction
    wire pipe_rst=rst || start || error;
    wire idct_busy,idct_done,sample_valid;
    wire [5:0] sample_index;wire [7:0] sample_value;
    wire [1:0] mcu_free;
    wire idct_start=busy && hs==H_RUN && es==E_READY && !idct_busy &&
        (block_slot!=0 || mcu_free[mcu_index[0]]);
    reg idct_coeff_bank,idct_mcu_bank;
    reg [2:0] idct_slot;
    reg [5:0] idct_mx;reg [4:0] idct_my;
    yingxu_jpeg_idct u_idct(.clk(clk),.rst(pipe_rst),.start(idct_start),.bank(bank),
        .busy(idct_busy),.done(idct_done),.coeff_addr(coeff_raddr),.coeff_data(coeff_q),
        .sample_valid(sample_valid),.sample_addr(sample_index),.sample_data(sample_value));
    wire rgb_valid;wire [15:0] rgb_pixel;wire [9:0] rgb_x;wire [8:0] rgb_y;
    yingxu_jpeg_rgb u_rgb(.clk(clk),.rst(pipe_rst),.sample_valid(sample_valid),
        .sample_bank(idct_mcu_bank),.sample_block(idct_slot),.sample_index(sample_index),
        .sample_data(sample_value),.mcu_done(idct_done && idct_slot==5),
        .mcu_x(idct_mx),.mcu_y(idct_my),.bank_free(mcu_free),
        .pixel_valid(rgb_valid),.pixel_ready(pixel_ready && !error),.pixel(rgb_pixel),
        .pixel_x(rgb_x),.pixel_y(rgb_y));
    assign pixel_valid=rgb_valid && !error;
    assign pixel=rgb_pixel;assign pixel_x=rgb_x;assign pixel_y=rgb_y;
    wire hdata=(hs==H_SKIP || hs==H_QINFO || hs==H_QDATA || hs==H_HTINFO ||
        hs==H_COUNTS || hs==H_SYMBOLS || hs==H_SOF || hs==H_SOS || hs==H_DRI);
    assign byte_ready=busy && !error && seen<frame_length &&
        (hs==H_RUN ? (!marker_pending && bit_count<=16) : (hs!=H_IDLE && hs!=H_FINISH && hs!=H_COUNTHIGH));
    wire accept=byte_valid && byte_ready;
    wire append=accept && hs==H_RUN && (ff_pending ? byte_data==0 : byte_data!=255);
    wire [7:0] append_byte=ff_pending ? 8'hFF:byte_data;
    wire [3:0] take=(hs==H_RUN && es==E_HBIT && bit_count!=0) ? 4'd1 :
        (hs==H_RUN && es==E_AMP && bit_count>=amplitude_size) ? amplitude_size:4'd0;
    wire reset_bits=(hs==H_RUN && (es==E_RST || es==E_EOI) && marker_pending);
    wire [15:0] amp_mask=(16'd1<<amplitude_size)-1'b1;
    wire [15:0] amp_bits=(bitbuf>>(bit_count-amplitude_size)) & amp_mask;
    wire pad_ok=bit_count<=7 && (bitbuf & ((32'd1<<bit_count)-1'b1))==((32'd1<<bit_count)-1'b1);
    wire [16:0] code_limit={1'b0,hfirst}+{9'd0,desc_q[15:8]};
    wire coeff_we=busy && hs==H_RUN && ((es==E_CLEAR && !locked[bank]) || es==E_STORE || es==E_STOREHI);
    wire [7:0] coeff_waddr=es==E_CLEAR ? {bank,clear_index} : {bank,zigzag(coefficient_index[5:0]),(es==E_STOREHI)};
    wire [15:0] coeff_wdata=es==E_CLEAR ? 16'd0:es==E_STORE ? dequantized[15:0]:{{8{dequantized[23]}},dequantized[23:16]};
    wire table_we=accept && (hs==H_QDATA || hs==H_SYMBOLS);
    wire [9:0] table_waddr=hs==H_QDATA ? 10'd576+{3'd0,qtable,6'd0}+{3'd0,index} : symbol_base(htable)+{1'b0,hindex};
    wire desc_we=(accept && hs==H_COUNTS) || hs==H_COUNTHIGH;
    wire [6:0] desc_waddr=hs==H_COUNTHIGH ? {desc_write_index,1'b1}:{htable,hlength[3:0],1'b0};
    wire [15:0] desc_wdata=hs==H_COUNTHIGH ? desc_write_high:build_code[15:0];
    // All wide values use two <=16-bit words in ONE physical BRAM per RAM.
    always @(posedge clk) begin
        table_q<=tables[table_addr];
        desc_q<=descriptors[{selected_ht,hlen,(es==E_HLO)}];
        coeff_q<=coeff[coeff_raddr];
        if(coeff_we) coeff[coeff_waddr]<=coeff_wdata;
        if(table_we) tables[table_waddr]<=byte_data;
        if(desc_we) descriptors[desc_waddr]<=desc_wdata;
    end
    always @(posedge clk) begin
        if(pipe_rst) begin bitbuf<=0;bit_count<=0;ff_pending<=0;marker_pending<=0;pending_marker<=0;end
        else begin
            if(append) bitbuf<=(bitbuf<<8)|{24'd0,append_byte};
            if(reset_bits) begin bit_count<=0;marker_pending<=0;ff_pending<=0;end
            else bit_count<=bit_count-take+(append ? 6'd8:6'd0);
            if(accept && hs==H_RUN) begin
                if(ff_pending) begin
                    if(byte_data==0) ff_pending<=0;
                    else if(byte_data!=255) begin marker_pending<=1;pending_marker<=byte_data;ff_pending<=0;end
                end else if(byte_data==255) ff_pending<=1;
            end
        end
    end
    task fail(input [7:0] code);
        begin error<=1;error_code<=code;busy<=0;done<=1;hs<=H_IDLE;end
    endtask
    reg signed [31:0] amplitude,predicted;
    reg [15:0] seglen;
    reg [8:0] counts_total;
    always @(posedge clk) begin
        if(rst) begin
            header_after<=H_COUNTS;desc_write_index<=0;desc_write_high<=0;hfirst<=0;
            hs<=H_IDLE;es<=E_WAITBANK;busy<=0;done<=0;error<=0;error_code<=0;cycles<=0;
            seen<=0;frame_length<=0;length_r<=0;seg_left<=0;marker<=0;index<=0;
            sof_seen<=0;qvalid<=0;hvalid<=0;qy<=0;qc<=0;dy<=0;ay<=0;dc<=0;ac<=0;
            qtable<=0;htable<=0;hlength<=0;build_code<=0;htotal<=0;hindex<=0;symbol_seen<=0;
            restart_interval<=0;restart_count<=0;restart_number<=0;table_addr<=0;
            bank<=0;locked<=0;clear_index<=0;block_slot<=0;mcu_index<=0;mx<=0;my<=0;
            ac_phase<=0;coefficient_index<=0;amplitude_size<=0;hcode<=0;hlen<=0;
            predictor[0]<=0;predictor[1]<=0;predictor[2]<=0;quantized<=0;dequantized<=0;
            entropy_finished<=0;pixels_finished<=0;idct_coeff_bank<=0;idct_mcu_bank<=0;
            idct_slot<=0;idct_mx<=0;idct_my<=0;
        end else begin
            done<=0;
            if(start && !busy) begin
                busy<=1;error<=0;error_code<=0;cycles<=0;seen<=0;frame_length<=frame_bytes;
                hs<=H_SOI0;es<=E_WAITBANK;sof_seen<=0;qvalid<=0;hvalid<=0;
                restart_interval<=0;restart_count<=0;restart_number<=0;locked<=0;bank<=0;
                block_slot<=0;mcu_index<=0;mx<=0;my<=0;ac_phase<=0;
                entropy_finished<=0;pixels_finished<=0;
                predictor[0]<=0;predictor[1]<=0;predictor[2]<=0;
                if(frame_bytes<4) fail(8'h01);
            end else if(busy) begin
                cycles<=cycles+1'b1;
                if(pixel_valid && pixel_ready && pixel_x==639 && pixel_y==479) pixels_finished<=1;
                if(idct_done) locked[idct_coeff_bank]<=0;
                if(idct_start) begin
                    locked[bank]<=1;idct_coeff_bank<=bank;idct_mcu_bank<=mcu_index[0];
                    idct_slot<=block_slot;idct_mx<=mx;idct_my<=my;
                end
                if(hs==H_COUNTHIGH) hs<=header_after;
                if(accept) begin
                    seen<=seen+1'b1;
                    if(hdata) seg_left<=seg_left-1'b1;
                    case(hs)
                        H_SOI0: if(byte_data==255) hs<=H_SOI1;else fail(8'h02);
                        H_SOI1: if(byte_data==8'hD8) hs<=H_FF;else fail(8'h02);
                        H_FF: if(byte_data==255) hs<=H_MARK;else fail(8'h03);
                        H_MARK: begin
                            if(byte_data!=255) begin
                                marker<=byte_data;hs<=H_LENH;
                                if(!(byte_data==8'hDB || byte_data==8'hC0 || byte_data==8'hC4 ||
                                     byte_data==8'hDA || byte_data==8'hDD || byte_data==8'hFE ||
                                     byte_data[7:4]==4'hE)) fail(8'h04);
                            end
                        end
                        H_LENH: begin length_r[15:8]<=byte_data;hs<=H_LENL;end
                        H_LENL: begin
                            seglen={length_r[15:8],byte_data};
                            seg_left<=seglen-2;index<=0;
                            if(seglen<2 || seen+seglen-1>frame_length) fail(8'h05);
                            else case(marker)
                                8'hDB: hs<=H_QINFO;
                                8'hC4: hs<=H_HTINFO;
                                8'hC0: if(seglen==17 && !sof_seen) hs<=H_SOF;else fail(8'h06);
                                8'hDA: if(seglen==12 && sof_seen) hs<=H_SOS;else fail(8'h07);
                                8'hDD: if(seglen==4) hs<=H_DRI;else fail(8'h08);
                                default: hs<=seglen==2 ? H_FF:H_SKIP;
                            endcase
                        end
                        H_SKIP: if(seg_left==1) hs<=H_FF;
                        H_QINFO: begin
                            if(byte_data>1 || seg_left<65) fail(8'h09);
                            else begin qtable<=byte_data[0];index<=0;hs<=H_QDATA;end
                        end
                        H_QDATA: begin
                            if(byte_data==0) fail(8'h0A);
                            else if(index==63) begin qvalid[qtable]<=1;hs<=seg_left==1 ? H_FF:H_QINFO;end
                            else index<=index+1'b1;
                        end
                        H_HTINFO: begin
                            if(byte_data[7:5]!=0 || byte_data[3:1]!=0 || seg_left<18) fail(8'h0B);
                            else begin
                                htable<={byte_data[4],byte_data[0]};hlength<=0;build_code<=0;htotal<=0;
                                symbol_seen<=0;hs<=H_COUNTS;
                            end
                        end
                        H_COUNTS: begin
                            counts_total=htotal+{1'b0,byte_data};
                            hs<=H_COUNTHIGH;header_after<=H_COUNTS;
                            desc_write_index<={htable,hlength[3:0]};desc_write_high<={byte_data,htotal[7:0]};
                            if((byte_data!=0 && build_code+byte_data >= (18'd1<<(hlength+1'b1))) ||
                               counts_total>(htable[1] ? 162:12)) fail(8'h0C);
                            else begin
                                build_code<=(build_code+byte_data)<<1;htotal<=counts_total;
                                hlength<=hlength+1'b1;
                                if(hlength==15) begin
                                    if(counts_total==0 || seg_left<=counts_total) fail(8'h0D);
                                    else begin hindex<=0;header_after<=H_SYMBOLS;end
                                end
                            end
                        end
                        H_SYMBOLS: begin
                            if(symbol_seen[byte_data] || (!htable[1] && byte_data>11) ||
                               (htable[1] && byte_data!=0 && byte_data!=240 &&
                                (byte_data[3:0]==0 || byte_data[3:0]>10))) fail(8'h0E);
                            else begin
                                symbol_seen[byte_data]<=1;hindex<=hindex+1'b1;
                                if(hindex+1'b1==htotal) begin hvalid[htable]<=1;hs<=seg_left==1 ? H_FF:H_HTINFO;end
                            end
                        end
                        H_SOF: begin
                            index<=index+1'b1;
                            case(index)
                                0: if(byte_data!=8) fail(8'h10);
                                1: if(byte_data!=1) fail(8'h10);
                                2: if(byte_data!=8'hE0) fail(8'h10);
                                3: if(byte_data!=2) fail(8'h10);
                                4: if(byte_data!=8'h80) fail(8'h10);
                                5: if(byte_data!=3) fail(8'h10);
                                6: if(byte_data!=1) fail(8'h10);
                                7: if(byte_data!=8'h22) fail(8'h10);
                                8: begin qy<=byte_data[0];if(byte_data>1) fail(8'h10);end
                                9: if(byte_data!=2) fail(8'h10);
                                10: if(byte_data!=8'h11) fail(8'h10);
                                11: begin qc<=byte_data[0];if(byte_data>1) fail(8'h10);end
                                12: if(byte_data!=3) fail(8'h10);
                                13: if(byte_data!=8'h11) fail(8'h10);
                                14: if(byte_data!={7'd0,qc}) fail(8'h10);else begin sof_seen<=1;hs<=H_FF;end
                                default: fail(8'h10);
                            endcase
                        end
                        H_SOS: begin
                            index<=index+1'b1;
                            case(index)
                                0: if(byte_data!=3) fail(8'h11);
                                1: if(byte_data!=1) fail(8'h11);
                                2: begin
                                    dy<=byte_data[4];ay<=byte_data[0];
                                    if(byte_data[7:5]!=0 || byte_data[3:1]!=0 || !hvalid[{1'b0,byte_data[4]}] ||
                                        !hvalid[{1'b1,byte_data[0]}]) fail(8'h12);
                                end
                                3: if(byte_data!=2) fail(8'h11);
                                4: begin
                                    dc<=byte_data[4];ac<=byte_data[0];
                                    if(byte_data[7:5]!=0 || byte_data[3:1]!=0 || !hvalid[{1'b0,byte_data[4]}] ||
                                        !hvalid[{1'b1,byte_data[0]}]) fail(8'h12);
                                end
                                5: if(byte_data!=3) fail(8'h11);
                                6: if(byte_data!={3'd0,dc,3'd0,ac}) fail(8'h11);
                                7: if(byte_data!=0) fail(8'h11);
                                8: if(byte_data!=63) fail(8'h11);
                                9: if(byte_data!=0 || !qvalid[qy] || !qvalid[qc]) fail(8'h12);
                                    else begin hs<=H_RUN;es<=E_WAITBANK;clear_index<=0;end
                                default: fail(8'h11);
                            endcase
                        end
                        H_DRI: if(index==0) begin restart_interval[15:8]<=byte_data;index<=1;end
                            else begin restart_interval[7:0]<=byte_data;hs<=H_FF;end
                        default: begin end
                    endcase
                end
                if(hs==H_RUN) case(es)
                    E_WAITBANK: if(!locked[bank]) begin clear_index<=0;es<=E_CLEAR;end
                    E_CLEAR: if(!locked[bank]) begin
                        clear_index<=clear_index+1'b1;
                        if(clear_index==127) begin ac_phase<=0;coefficient_index<=0;es<=E_HINIT;end
                    end
                    E_HINIT: begin hcode<=0;hlen<=0;es<=E_HBIT;end
                    E_HBIT: if(bit_count!=0) begin hcode<={hcode[15:0],bitbuf[bit_count-1'b1]};es<=E_HLO;end
                        else if(marker_pending || seen==frame_length) fail(8'h20);
                    E_HLO: begin hfirst<=desc_q;es<=E_HCHECK;end
                    E_HCHECK: begin
                        if(desc_q[15:8]!=0 && hcode>={1'b0,hfirst} && hcode<code_limit) begin
                            table_addr<=symbol_base(selected_ht)+{2'd0,desc_q[7:0]}+
                                (hcode-{1'b0,hfirst});es<=E_SYMWAIT;
                        end else if(hlen==15) fail(8'h21);
                        else begin hlen<=hlen+1'b1;es<=E_HBIT;end
                    end
                    E_SYMWAIT: es<=E_SYMBOL;
                    E_SYMBOL: begin
                        amplitude_size<=table_q[3:0];
                        if(!ac_phase) begin
                            if(table_q>11) fail(8'h22);else es<=E_AMP;
                        end else if(table_q==0) es<=E_READY;
                        else if(table_q==240) begin
                            if(coefficient_index+16>64) fail(8'h23);
                            else if(coefficient_index+16==64) es<=E_READY;
                            else begin coefficient_index<=coefficient_index+16;es<=E_HINIT;end
                        end else if(table_q[3:0]==0 || table_q[3:0]>10 ||
                                    coefficient_index+{3'd0,table_q[7:4]}>=64) fail(8'h23);
                        else begin coefficient_index<=coefficient_index+{3'd0,table_q[7:4]};es<=E_AMP;end
                    end
                    E_AMP: if(bit_count>=amplitude_size) begin
                        amplitude=$signed({16'd0,amp_bits});
                        if(amplitude_size!=0 && amp_bits<(16'd1<<(amplitude_size-1'b1)))
                            amplitude=amplitude-$signed({16'd0,amp_mask});
                        predicted=amplitude+(ac_phase ? 32'sd0 : $signed(predictor[component_id]));
                        if(predicted< -32768 || predicted>32767) fail(8'h24);
                        else begin
                            quantized<=predicted[15:0];
                            if(!ac_phase) predictor[component_id]<=predicted[15:0];
                            table_addr<=10'd576+((block_slot<4 ? qy:qc) ? 10'd64:10'd0)+{4'd0,coefficient_index[5:0]};
                            es<=E_QWAIT;
                        end
                    end else if(marker_pending || seen==frame_length) fail(8'h20);
                    E_QWAIT: es<=E_QMUL;
                    E_QMUL: begin dequantized<=$signed(quantized)*$signed({1'b0,table_q});es<=E_STORE;end
                    E_STORE: es<=E_STOREHI;
                    E_STOREHI: begin
                        if(coefficient_index==63) es<=E_READY;
                        else begin coefficient_index<=coefficient_index+1'b1;ac_phase<=1;es<=E_HINIT;end
                    end
                    E_READY: if(idct_start) begin
                        bank<=~bank;
                        if(block_slot==5) begin
                            block_slot<=0;mcu_index<=mcu_index+1'b1;
                            if(mx==39) begin mx<=0;my<=my+1'b1;end else mx<=mx+1'b1;
                            if(mcu_index==1199) es<=E_EOI;
                            else if(restart_interval!=0 && restart_count+1'b1==restart_interval) es<=E_RST;
                            else begin restart_count<=restart_count+1'b1;es<=E_WAITBANK;end
                        end else begin block_slot<=block_slot+1'b1;es<=E_WAITBANK;end
                    end
                    E_RST: if(marker_pending) begin
                        if(!pad_ok || pending_marker!=8'hD0+{5'd0,restart_number}) fail(8'h25);
                        else begin
                            restart_number<=restart_number+1'b1;restart_count<=0;
                            predictor[0]<=0;predictor[1]<=0;predictor[2]<=0;es<=E_WAITBANK;
                        end
                    end else if(seen==frame_length) fail(8'h20);
                    E_EOI: if(marker_pending) begin
                        if(!pad_ok || pending_marker!=8'hD9 || seen!=frame_length) fail(8'h26);
                        else begin entropy_finished<=1;hs<=H_FINISH;es<=E_FINISH;end
                    end else if(seen==frame_length) fail(8'h20);
                    default: begin end
                endcase
                if(hs==H_FINISH && entropy_finished && pixels_finished && !idct_busy) begin busy<=0;done<=1;hs<=H_IDLE;end
                if(hs!=H_RUN && hs!=H_FINISH && seen==frame_length) fail(8'h20);
                if(cycles>=MAX_CYCLES-1) fail(8'h30);
            end
        end
    end
endmodule
`default_nettype wire
