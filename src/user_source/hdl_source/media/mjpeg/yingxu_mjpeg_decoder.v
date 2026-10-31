`timescale 1ns/1ps
`default_nettype none
// Memory-clock-domain frame master. Byte addresses must be converted by caller.
// RGB565: earlier pixel is the HIGH halfword, matching existing display packing.
module yingxu_mjpeg_decoder #(parameter integer MAX_CYCLES=8_000_000)(
    input wire clk,rst,
    input wire frame_valid,output wire frame_ready,
    input wire [20:0] src_addr,dst_addr,input wire [15:0] jpeg_bytes,
    output reg busy,done,error,output reg [7:0] error_code,
    output reg [31:0] frame_cycles,output reg [17:0] committed_words,
    output wire cmd_valid,input wire cmd_ready,output wire cmd_write,
    output wire [20:0] cmd_addr,output wire [3:0] cmd_words,
    input wire rvalid,output wire rready,input wire [31:0] rdata,input wire rlast,
    output wire wvalid,input wire wready,output wire [31:0] wdata,output wire wlast,
    input wire mem_done,mem_error
);
    localparam M_IDLE=0,M_CMD=1,M_ACTIVE=2;
    reg [1:0] ms;
    reg transaction_write;reg [20:0] transaction_addr;reg [3:0] transaction_words;
    reg [3:0] transferred;
    reg [31:0] input_buf[0:7],output_buf[0:7];
    reg [3:0] cached,packed_words;
    reg [2:0] cache_pos;reg [1:0] byte_pos;
    reg [16:0] byte_count;
    reg [14:0] words_remaining;
    reg [20:0] read_cursor,destination,packed_addr;
    reg [15:0] length,first_pixel;
    reg half_pixel,core_start,core_finished,aborting,core_cancel;
    wire core_busy,core_done,core_error;wire [7:0] core_code;
    wire [31:0] core_cycles;
    wire byte_valid=busy && cached!=0 && byte_count<{1'b0,length} && !aborting;
    wire byte_ready;
    wire [31:0] input_word=input_buf[cache_pos];
    wire [7:0] byte_value=input_word>>(8*byte_pos);
    wire pixel_valid;wire pixel_ready;
    wire [15:0] pixel;wire [9:0] px;wire [8:0] py;
    assign pixel_ready=busy && !aborting && !core_error && packed_words<8;
    yingxu_jpeg_core #(.MAX_CYCLES(MAX_CYCLES)) u_core(
        .clk(clk),.rst(rst || core_cancel),.start(core_start),.frame_bytes(length),
        .byte_valid(byte_valid),.byte_ready(byte_ready),.byte_data(byte_value),
        .pixel_valid(pixel_valid),.pixel_ready(pixel_ready),.pixel(pixel),.pixel_x(px),.pixel_y(py),
        .busy(core_busy),.done(core_done),.error(core_error),.error_code(core_code),.cycles(core_cycles));
    assign frame_ready=!busy && ms==M_IDLE;
    assign cmd_valid=ms==M_CMD;
    assign cmd_write=transaction_write;
    assign cmd_addr=transaction_addr;
    assign cmd_words=transaction_words;
    assign rready=ms==M_ACTIVE && !transaction_write && transferred<transaction_words;
    assign wvalid=ms==M_ACTIVE && transaction_write && transferred<transaction_words;
    assign wdata=output_buf[transferred[2:0]];
    assign wlast=transferred+1'b1==transaction_words;
    wire [21:0] src_end={1'b0,src_addr}+(({6'd0,jpeg_bytes}+22'd3)>>2);
    wire [21:0] dst_end={1'b0,dst_addr}+22'd153600;
    wire extent_bad=jpeg_bytes<4 || src_end>22'd2097152 || dst_end>22'd2097152 ||
        ({1'b0,src_addr}<dst_end && {1'b0,dst_addr}<src_end);
    wire rbeat=rvalid && rready,wbeat=wvalid && wready;
    wire last_byte=byte_count+1'b1=={1'b0,length};
    wire [21:0] pixel_word_offset=({13'd0,py}<<8)+({13'd0,py}<<6)+{13'd0,px[9:1]};
    always @(posedge clk) begin
        if(rst) begin
            busy<=0;done<=0;error<=0;error_code<=0;frame_cycles<=0;committed_words<=0;
            ms<=M_IDLE;transaction_write<=0;transaction_addr<=0;transaction_words<=0;transferred<=0;
            cached<=0;packed_words<=0;cache_pos<=0;byte_pos<=0;byte_count<=0;
            words_remaining<=0;read_cursor<=0;destination<=0;packed_addr<=0;length<=0;
            first_pixel<=0;half_pixel<=0;core_start<=0;core_finished<=0;aborting<=0;core_cancel<=0;
        end else begin
            done<=0;core_start<=0;core_cancel<=0;
            if(frame_valid && frame_ready) begin
                error<=0;error_code<=0;frame_cycles<=0;committed_words<=0;
                cached<=0;packed_words<=0;cache_pos<=0;byte_pos<=0;byte_count<=0;
                read_cursor<=src_addr;destination<=dst_addr;length<=jpeg_bytes;
                words_remaining<=({1'b0,jpeg_bytes}+17'd3)>>2;
                half_pixel<=0;core_finished<=0;aborting<=0;
                if(extent_bad) begin error<=1;error_code<=8'h80;done<=1;end
                else begin busy<=1;core_start<=1;end
            end else if(busy) begin
                frame_cycles<=frame_cycles+1'b1;
                if(core_done && !core_start) core_finished<=1;
                if(core_error && !core_start && !aborting) begin aborting<=1;error<=1;error_code<=core_code;end
                if(byte_valid && byte_ready) begin
                    byte_count<=byte_count+1'b1;byte_pos<=byte_pos+1'b1;
                    if(byte_pos==3 || last_byte) begin cached<=cached-1'b1;cache_pos<=cache_pos+1'b1;end
                end
                if(pixel_valid && pixel_ready) begin
                    half_pixel<=~half_pixel;
                    if(!half_pixel) begin
                        first_pixel<=pixel;
                        if(packed_words==0) packed_addr<=destination+pixel_word_offset[20:0];
                    end else begin output_buf[packed_words[2:0]]<={first_pixel,pixel};packed_words<=packed_words+1'b1;end
                end
                case(ms)
                    M_IDLE: if(!aborting && (!core_error || core_start)) begin
                        if(packed_words==8) begin
                            transaction_write<=1;transaction_addr<=packed_addr;transaction_words<=8;ms<=M_CMD;
                        end else if(cached==0 && words_remaining!=0) begin
                            transaction_write<=0;transaction_addr<=read_cursor;
                            transaction_words<=words_remaining>=8 ? 4'd8:words_remaining[3:0];ms<=M_CMD;
                        end
                    end
                    M_CMD: if(cmd_ready) begin ms<=M_ACTIVE;transferred<=0;end
                    M_ACTIVE: begin
                        if(rbeat) begin
                            input_buf[transferred[2:0]]<=rdata;transferred<=transferred+1'b1;
                            if(rlast!==(transferred+1'b1==transaction_words)) begin
                                aborting<=1;error<=1;error_code<=8'h81;
                            end
                        end
                        if(wbeat) transferred<=transferred+1'b1;
                        if(mem_done || mem_error) begin
                            ms<=M_IDLE;
                            if(mem_error || transferred+((rbeat || wbeat) ? 1'b1:1'b0)!=transaction_words) begin
                                aborting<=1;error<=1;error_code<=8'h82;
                            end else if(transaction_write) begin
                                packed_words<=0;committed_words<=committed_words+{14'd0,transaction_words};
                            end else begin
                                cached<=transaction_words;cache_pos<=0;byte_pos<=0;
                                read_cursor<=read_cursor+{17'd0,transaction_words};
                                words_remaining<=words_remaining-{11'd0,transaction_words};
                            end
                        end
                    end
                    default: ms<=M_IDLE;
                endcase
                // Accepted commands and payload remain owned until physical done.
                if(aborting && ms==M_IDLE) begin
                    packed_words<=0;cached<=0;half_pixel<=0;busy<=0;done<=1;core_cancel<=1;
                end else if(core_finished && !core_error && !aborting && ms==M_IDLE && packed_words==0) begin
                    busy<=0;done<=1;
                    if(committed_words!=153600 || byte_count!={1'b0,length}) begin error<=1;error_code<=8'h83;end
                end
            end
        end
    end
endmodule
`default_nettype wire
