`timescale 1ns/1ps
`default_nettype none
// YXV1 fixed 640x480@24. PCM preload, then frame-frame_table-indexed double staging.
// All external signals here are in mem_clk=100MHz; SD CDC is outside.
module yingxu_yxv_loader #(parameter [27:0] VIDEO_LBA=28'd3000000)(
    input wire clk,rst,enable,abort,
    output wire sd_valid,input wire sd_ready,output reg [27:0] sd_lba,output reg [15:0] sd_sectors,
    input wire sd_done,input wire [7:0] sd_byte,input wire sd_byte_valid,output wire sd_byte_ready,
    output wire idle,
    output wire [7:0] debug_phase,debug_flags,
    output reg [7:0] debug_reason,output reg [31:0] debug_word,
    output reg [9:0] debug_index,output wire [10:0] debug_count,
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
    reg [34:0] frame_table[0:511];reg [34:0] table_q;reg [55:0] assembly;
    reg [8:0] next_local;reg [15:0] next_tag;reg selected;
    reg [18:0] frame_start,previous_end,audio_off; // aligned sector indices
    reg [21:0] count,expected;reg [12:0] absolute_base;
    reg ack,rx_complete,invalid;
    reg [23:0] word;reg [31:0] write_buffer[0:7];reg [3:0] filled;
    reg [1:0] mstate;reg [3:0] sent;reg [20:0] cursor;
    wire meta=purpose<2;
    wire byte_fire=sd_byte_valid && sd_byte_ready;
    wire [12:0] absolute=absolute_base+count[12:0];
    wire [9:0] entry_index=(absolute-13'd32)>>3;
    wire [63:0] complete_entry={sd_byte,assembly};
    wire [31:0] entry_off=complete_entry[31:0],entry_size=complete_entry[63:32];
    wire [16:0] rounded_size=({1'b0,entry_size[15:0]}+17'd511)&17'h1FE00;
    wire [19:0] entry_end={1'b0,entry_off[27:9]}+{12'd0,rounded_size[16:9]};
    wire [13:0] pcm_sectors={1'b0,pcm_bytes[21:9]}+{13'd0,(|pcm_bytes[8:0])};
    wire [19:0] audio_end=entry_end+{6'd0,pcm_sectors};
    // D4f diagnostic-only pipeline. Raw words and parallel error predicates
    // are registered at the entry edge; priority/field selection runs from
    // those registers one edge later. No assembly -> reason -> word mux path.
    reg [7:0] diag_entry_flags;
    reg [31:0] diag_entry_off,diag_entry_size;
    reg [19:0] diag_audio_end;reg [9:0] diag_entry_index;
    wire [7:0] diag_entry_reason=diag_entry_flags[7] ? 8'h10:diag_entry_flags[6] ? 8'h11:
        diag_entry_flags[5] ? 8'h12:diag_entry_flags[4] ? 8'h13:
        diag_entry_flags[3] ? 8'h14:diag_entry_flags[2] ? 8'h15:diag_entry_flags[1] ? 8'h16:8'h17;
    wire diag_size_selected=!(|diag_entry_flags[7:5]) && diag_entry_flags[4];
    wire diag_audio_selected=!(|diag_entry_flags[7:1]);
    wire [31:0] diag_entry_observed=diag_size_selected ? diag_entry_size:
        diag_audio_selected ? {12'd0,diag_audio_end}:diag_entry_off;
    wire [31:0] complete_word={sd_byte,word[23:0]};
    // Fixed shifts keep the 8000*frames duration check out of DSPs.
    wire [22:0] expected_pcm={frames,13'd0}-{6'd0,frames,7'd0}-{7'd0,frames,6'd0};
    wire [12:0] minimum_frame_start=(13'd32+{frames,3'd0}+13'd511)&13'h1E00;
    assign debug_phase={purpose,state,mstate,invalid};
    assign debug_flags={rx_complete,ack,sd_done,sd_valid,sd_ready,(filled==0),(mstate==0),sd_byte_valid};
    assign debug_count=count[10:0];
    // Observation only: preserve the first validation failure, never change flow.
    task remember(input [7:0] why,input [31:0] observed,input [9:0] index);
        begin if(debug_reason==0)begin debug_reason<=why;debug_word<=observed;debug_index<=index;end end
    endtask
    assign sd_valid=state==SDREQ;
    assign sd_byte_ready=abort || (state==RECEIVE && (meta || invalid || filled<8));
    assign idle=(state==IDLE || state==SELECT || state==FAIL) && mstate==0;
    assign cmd_valid=mstate==1;assign cmd_write=1;assign cmd_addr=cursor;assign cmd_words=8;
    assign wvalid=mstate==2 && sent<8;assign wdata=write_buffer[sent[2:0]];assign wlast=sent==7;
    always @(posedge clk) begin table_q<=frame_table[next_local];end
    task request_sd(input [27:0] lba,input [15:0] sectors,input [1:0] kind,input [20:0] target,input [31:0] file_offset);
        begin sd_lba<=lba;sd_sectors<=sectors;purpose<=kind;cursor<=target;absolute_base<=file_offset[12:0];
            expected<={sectors[12:0],9'd0};count<=0;ack<=0;rx_complete<=0;filled<=0;state<=SDREQ;end
    endtask
    always @(posedge clk) begin
        if(rst) begin
            debug_reason<=0;debug_word<=0;debug_index<=0;
            diag_entry_flags<=0;diag_entry_off<=0;diag_entry_size<=0;diag_audio_end<=0;diag_entry_index<=0;
            state<=IDLE;purpose<=0;sd_lba<=VIDEO_LBA;sd_sectors<=0;ready<=0;failed<=0;error_code<=0;
            frames<=0;pcm_bytes<=0;slot_valid<=0;slot_tag0<=0;slot_tag1<=0;slot_len0<=0;slot_len1<=0;
            sd_accepted<=0;sd_ticks<=0;next_local<=0;next_tag<=0;selected<=0;
            frame_start<=0;previous_end<=0;audio_off<=0;count<=0;expected<=0;absolute_base<=0;
            ack<=0;rx_complete<=0;invalid<=0;assembly<=0;word<=0;filled<=0;mstate<=0;sent<=0;cursor<=0;
        end else begin
            diag_entry_flags<=0;
            if(|diag_entry_flags) remember(diag_entry_reason,diag_entry_observed,diag_entry_index);
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
                        if(mem_error) begin invalid<=1;error_code<=8'h91;remember(8'h20,{11'd0,cursor},10'd0);end
                    end
                end
                default:mstate<=0;
            endcase
            if(byte_fire && !abort) begin
                sd_accepted<=sd_accepted+1'b1;count<=count+22'd1;
                if(meta) begin
                    // Validate one 32-bit header word at a time. Reusing the
                    // existing byte assembler avoids a 32-byte multi-read RAM.
                    if(absolute<32) begin
                        word<={sd_byte,word[23:8]};
                        if(count[1:0]==3) begin
                            case(absolute[4:2])
                                0:if(complete_word!=32'h31565859)begin invalid<=1;error_code<=8'h92;remember(8'd1,complete_word,(absolute[4:2]==3 ? complete_word[9:0]:frames));end
                                1:if(complete_word!=32'h02800201)begin invalid<=1;error_code<=8'h92;remember(8'd2,complete_word,(absolute[4:2]==3 ? complete_word[9:0]:frames));end
                                2:if(complete_word!=32'h001801E0)begin invalid<=1;error_code<=8'h92;remember(8'd3,complete_word,(absolute[4:2]==3 ? complete_word[9:0]:frames));end
                                3:begin
                                    frames<=complete_word[9:0];
                                    if(complete_word==0 || complete_word>512)begin invalid<=1;error_code<=8'h92;remember(8'd4,complete_word,(absolute[4:2]==3 ? complete_word[9:0]:frames));end
                                end
                                4:if(complete_word!=48000)begin invalid<=1;error_code<=8'h92;remember(8'd5,complete_word,(absolute[4:2]==3 ? complete_word[9:0]:frames));end
                                5:begin
                                    pcm_bytes<={10'd0,complete_word[21:0]};
                                    if(complete_word!={9'd0,expected_pcm})begin invalid<=1;error_code<=8'h92;remember(8'd6,complete_word,(absolute[4:2]==3 ? complete_word[9:0]:frames));end
                                end
                                6:if(complete_word!=32)begin invalid<=1;error_code<=8'h92;remember(8'd7,complete_word,(absolute[4:2]==3 ? complete_word[9:0]:frames));end
                                7:begin
                                    frame_start<=complete_word[27:9];
                                    if(complete_word[31:28]!=0 || complete_word[8:0]!=0 || complete_word<minimum_frame_start)
                                        begin invalid<=1;error_code<=8'h92;remember(8'd8,complete_word,(absolute[4:2]==3 ? complete_word[9:0]:frames));end
                                end
                            endcase
                        end
                    end
                    if(!invalid && absolute>=32 && absolute<13'd32+{frames,3'd0}) begin
                        assembly<={sd_byte,assembly[55:8]};
                        if(count[2:0]==7) begin
                            // Capture every candidate, not a comparator-gated
                            // wide word. !invalid above freezes the first bad
                            // candidate; next edge publishes its diagnosis.
                            diag_entry_off<=entry_off;diag_entry_size<=entry_size;
                            diag_audio_end<=audio_end;diag_entry_index<=entry_index;
                            diag_entry_flags<={entry_index>=512,entry_off[8:0]!=0,entry_off[31:28]!=0,
                                (entry_size[31:16]!=0 || entry_size[15:0]<16'd4),
                                (entry_index==0 && entry_off[27:9]!=frame_start),
                                (entry_index!=0 && entry_off[27:9]<previous_end),entry_end[19],
                                (entry_index+10'd1==frames && audio_end>20'h80000)};
                            if(entry_index>=512 || entry_off[8:0]!=0 || entry_off[31:28]!=0 || entry_size[31:16]!=0 || entry_size[15:0]<16'd4 ||
                               (entry_index==0 ? entry_off[27:9]!=frame_start : entry_off[27:9]<previous_end) || entry_end[19] ||
                               (entry_index+10'd1==frames && audio_end>20'h80000)) begin
                                invalid<=1;error_code<=8'h93;
                            end else begin
                                frame_table[entry_index[8:0]]<={entry_size[15:0],entry_off[27:9]};previous_end<=entry_end[18:0];
                                if(entry_index+10'd1==frames) audio_off<=entry_end[18:0];
                            end
                        end
                    end
                end else if(!invalid) begin
                    word<={sd_byte,word[23:8]};
                    if(count[1:0]==3) begin write_buffer[filled[2:0]]<=complete_word;filled<=filled+1'b1;end
                end
                if(count+22'd1==expected) begin rx_complete<=1;state<=FINISH;end
            end
            case(state)
                IDLE: if(enable) request_sd(VIDEO_LBA,16'd1,0,0,0);
                SDREQ: if(sd_ready) state<=RECEIVE;
                FINISH: if(rx_complete && ack && mstate==0 && filled==0) begin
                    if(invalid) begin failed<=1;state<=FAIL;end
                    else if(purpose==0 && 32+{19'd0,frames,3'd0}>512)
                        request_sd(VIDEO_LBA+1,((32+{19'd0,frames,3'd0}+511)>>9)-1,1,0,512);
                    else if(purpose<2) request_sd(VIDEO_LBA+{9'd0,audio_off},{2'd0,pcm_sectors},2,21'h100000,{4'd0,audio_off,9'd0});
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
                    if(selected) slot_len1<=table_q[34:19];else slot_len0<=table_q[34:19];
                    request_sd(VIDEO_LBA+{9'd0,table_q[18:0]},({1'b0,table_q[34:19]}+17'd511)>>9,3,selected ? 21'h084000:21'h080000,{4'd0,table_q[18:0],9'd0});
                end
                default:begin end
            endcase
            if(abort && mstate==0) begin state<=FAIL;failed<=1;filled<=0;slot_valid<=0;end
        end
    end
endmodule
`default_nettype wire
