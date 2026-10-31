`timescale 1ns/1ps
`default_nettype none
// YXV1 fixed 640x480@24. PCM preload, then frame-frame_table-indexed double staging.
// All external signals here are in mem_clk=100MHz; SD CDC is outside.
module yingxu_yxv_loader #(parameter [27:0] VIDEO_LBA=28'd3000000)(
    input wire clk,rst,enable,
    output wire sd_valid,input wire sd_ready,output reg [27:0] sd_lba,output reg [15:0] sd_sectors,
    input wire sd_done,input wire [7:0] sd_byte,input wire sd_byte_valid,output wire sd_byte_ready,
    output reg ready,failed,output reg [7:0] error_code,
    output reg [9:0] frames,output reg [31:0] pcm_bytes,
    output reg [1:0] slot_valid,input wire [1:0] slot_release,
    output reg [31:0] slot_tag0,slot_tag1,output reg [15:0] slot_len0,slot_len1,
    output reg [31:0] sd_accepted,output reg [31:0] sd_ticks,
    output wire cmd_valid,input wire cmd_ready,output wire cmd_write,
    output wire [20:0] cmd_addr,output wire [3:0] cmd_words,
    output wire wvalid,input wire wready,output wire [31:0] wdata,output wire wlast,
    input wire mem_done,mem_error
);
    localparam IDLE=0,SDREQ=1,RECEIVE=2,FINISH=3,SELECT=4,LOOKUP=5,PREPARE=6,FAIL=7;
    reg [2:0] state;reg [1:0] purpose; // 0 first meta,1 remaining meta,2 PCM,3 JPEG
    reg [7:0] header[0:31];reg [63:0] frame_table[0:511];reg [63:0] table_q,assembly;
    reg [8:0] next_local;reg [31:0] next_tag;reg selected;
    reg [31:0] frame_start,previous_end,audio_off;
    reg [31:0] count,expected,absolute_base;
    reg ack,rx_complete,invalid;
    reg [31:0] word;reg [31:0] write_buffer[0:7];reg [3:0] filled;
    reg [1:0] mstate;reg [3:0] sent;reg [20:0] cursor;
    wire meta=purpose<2;
    wire byte_fire=sd_byte_valid && sd_byte_ready;
    wire [31:0] absolute=absolute_base+count;
    wire [31:0] entry_index=(absolute-32)>>3;
    wire [63:0] complete_entry={sd_byte,assembly[55:0]};
    wire [31:0] entry_off=complete_entry[31:0],entry_size=complete_entry[63:32];
    wire [31:0] entry_end=entry_off+((entry_size+511)&32'hFFFFFE00);
    function [31:0] h32(input integer a);h32={header[a+3],header[a+2],header[a+1],header[a]};endfunction
    wire [31:0] header_frames=h32(12),header_start=h32(28);
    assign sd_valid=state==SDREQ;
    assign sd_byte_ready=state==RECEIVE && (meta || invalid || filled<8);
    assign cmd_valid=mstate==1;assign cmd_write=1;assign cmd_addr=cursor;assign cmd_words=8;
    assign wvalid=mstate==2 && sent<8;assign wdata=write_buffer[sent[2:0]];assign wlast=sent==7;
    always @(posedge clk) begin table_q<=frame_table[next_local];end
    task request_sd(input [27:0] lba,input [15:0] sectors,input [1:0] kind,input [20:0] target,input [31:0] file_offset);
        begin sd_lba<=lba;sd_sectors<=sectors;purpose<=kind;cursor<=target;absolute_base<=file_offset;
            expected<={7'd0,sectors,9'd0};count<=0;ack<=0;rx_complete<=0;filled<=0;state<=SDREQ;end
    endtask
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;purpose<=0;sd_lba<=VIDEO_LBA;sd_sectors<=0;ready<=0;failed<=0;error_code<=0;
            frames<=0;pcm_bytes<=0;slot_valid<=0;slot_tag0<=0;slot_tag1<=0;slot_len0<=0;slot_len1<=0;
            sd_accepted<=0;sd_ticks<=0;next_local<=0;next_tag<=0;selected<=0;
            frame_start<=0;previous_end<=0;audio_off<=0;count<=0;expected<=0;absolute_base<=0;
            ack<=0;rx_complete<=0;invalid<=0;assembly<=0;word<=0;filled<=0;mstate<=0;sent<=0;cursor<=0;
        end else begin
            if(sd_done) ack<=1;
            slot_valid<=slot_valid & ~slot_release;
            if(state==SDREQ || state==RECEIVE || state==FINISH) sd_ticks<=sd_ticks+1'b1;
            // In-flight writes finish even if a later header/data check fails.
            case(mstate)
                0: if(filled==8) begin mstate<=1;sent<=0;end
                1: if(cmd_ready) mstate<=2;
                2: begin
                    if(wvalid && wready) sent<=sent+1'b1;
                    if(mem_done || mem_error) begin
                        mstate<=0;filled<=0;cursor<=cursor+8;
                        if(mem_error) begin invalid<=1;error_code<=8'h91;end
                    end
                end
                default:mstate<=0;
            endcase
            if(byte_fire) begin
                sd_accepted<=sd_accepted+1'b1;count<=count+1'b1;
                if(meta) begin
                    if(absolute<32) header[absolute[4:0]]<=sd_byte;
                    if(absolute==32 && purpose==0) begin
                        frames<=header_frames[9:0];pcm_bytes<=h32(20);frame_start<=h32(28);
                        if({header[0],header[1],header[2],header[3]}!=32'h59585631 || header[4]!=1 || header[5]!=2 ||
                           {header[7],header[6]}!=640 || {header[9],header[8]}!=480 || {header[11],header[10]}!=24 ||
                           h32(12)==0 || h32(12)>512 || h32(16)!=48000 || h32(20)!=h32(12)*8000 ||
                           h32(24)!=32 || header_start[8:0]!=0 || h32(28)<((32+h32(12)*8+511)&32'hFFFFFE00)) begin
                            invalid<=1;error_code<=8'h92;
                        end
                    end
                    if(absolute>=32 && (absolute==32 || absolute<32+{19'd0,frames,3'd0})) begin
                        assembly[count[2:0]*8+:8]<=sd_byte;
                        if(count[2:0]==7) begin
                            if(entry_index>=512 || entry_off[8:0]!=0 || entry_off[31:28]!=0 || entry_size<4 || entry_size>65535 ||
                               (entry_index==0 ? entry_off!=frame_start : entry_off<previous_end) || entry_end<entry_off) begin
                                invalid<=1;error_code<=8'h93;
                            end else begin
                                frame_table[entry_index[8:0]]<=complete_entry;previous_end<=entry_end;
                                if(entry_index+1==frames) audio_off<=entry_end;
                            end
                        end
                    end
                end else if(!invalid) begin
                    word[count[1:0]*8+:8]<=sd_byte;
                    if(count[1:0]==3) begin write_buffer[filled[2:0]]<={sd_byte,word[23:0]};filled<=filled+1'b1;end
                end
                if(count+1==expected) begin rx_complete<=1;state<=FINISH;end
            end
            case(state)
                IDLE: if(enable) request_sd(VIDEO_LBA,16'd1,0,0,0);
                SDREQ: if(sd_ready) state<=RECEIVE;
                FINISH: if(rx_complete && ack && mstate==0 && filled==0) begin
                    if(invalid) begin failed<=1;state<=FAIL;end
                    else if(purpose==0 && 32+{19'd0,frames,3'd0}>512)
                        request_sd(VIDEO_LBA+1,((32+{19'd0,frames,3'd0}+511)>>9)-1,1,0,512);
                    else if(purpose<2) request_sd(VIDEO_LBA+(audio_off>>9),(pcm_bytes+511)>>9,2,21'h100000,audio_off);
                    else if(purpose==2) begin ready<=1;state<=SELECT;end
                    else begin
                        slot_valid[selected]<=1;
                        if(selected) slot_tag1<=next_tag;else slot_tag0<=next_tag;
                        next_tag<=next_tag+1'b1;next_local<=({1'b0,next_local}+1==frames) ? 0:next_local+1'b1;
                        state<=SELECT;
                    end
                end
                SELECT: if(enable && slot_valid!=3) begin selected<=slot_valid[0] ? 1'b1:1'b0;state<=LOOKUP;end
                LOOKUP:state<=PREPARE;
                PREPARE: begin
                    if(selected) slot_len1<=table_q[47:32];else slot_len0<=table_q[47:32];
                    request_sd(VIDEO_LBA+(table_q[31:0]>>9),(table_q[63:32]+511)>>9,3,selected ? 21'h084000:21'h080000,table_q[31:0]);
                end
                default:begin end
            endcase
        end
    end
endmodule
`default_nettype wire
