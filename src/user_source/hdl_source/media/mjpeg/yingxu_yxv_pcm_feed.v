`timescale 1ns/1ps
`default_nettype none
// Preloaded SDRAM PCM -> cyclic 32-bit FIFO -> virtual YXMA + raw byte stream.
module yingxu_yxv_pcm_feed(
    input wire clk,sys_clk,rst,enable,input wire [31:0] pcm_bytes,
    output wire cmd_valid,input wire cmd_ready,output wire cmd_write,
    output wire [20:0] cmd_addr,output wire [3:0] cmd_words,
    input wire rvalid,output wire rready,input wire [31:0] rdata,input wire rlast,
    input wire mem_done,mem_error,output reg failed,
    output wire [7:0] wav_data,output wire wav_valid,input wire wav_ready,
    output wire idle
);
    reg [1:0] state;reg [19:0] cursor;reg [3:0] received;
    wire fifo_wr,fifo_rd,fifo_full_ready,fifo_valid;
    wire [31:0] fifo_data;wire [4:0] level;
    yingxu_media_async_fifo #(.WIDTH(32),.ABITS(4)) fifo(
        .wclk(clk),.rclk(sys_clk),.rst(rst),.wvalid(fifo_wr),.wready(fifo_full_ready),.wdata(rdata),
        .rvalid(fifo_valid),.rready(fifo_rd),.rdata(fifo_data),.wlevel(level));
    assign cmd_valid=state==1;assign cmd_write=0;assign cmd_addr={1'b1,cursor};assign cmd_words=8;
    assign rready=state==2 && fifo_full_ready;assign fifo_wr=rvalid && state==2;
    assign idle=state==0;
    always @(posedge clk) begin
        if(rst) begin state<=0;cursor<=0;received<=0;failed<=0;end
        else case(state)
            0: if(enable && !failed && level<=8) state<=1;
            1: if(cmd_ready) begin received<=0;state<=2;end
            2: begin
                if(rvalid && rready) begin received<=received+1'b1;if(rlast!=(received==7))failed<=1;end
                if(mem_done || mem_error) begin
                    state<=0;
                    if(mem_error || received+((rvalid&&rready) ? 1'b1:1'b0)!=8) failed<=1;
                    cursor<=({1'b0,cursor}+21'd8 >= {1'b0,pcm_bytes[21:2]}) ? 20'd0:cursor+20'd8;
                end
            end
            default:state<=0;
        endcase
    end
    reg [1:0] en_sync;reg [2:0] warm;
    reg header_mode;reg [4:0] hi;reg [1:0] bi;reg [21:0] sent;
    wire [31:0] pcm_frames=pcm_bytes>>2;
    function [7:0] header_byte(input [4:0] index);
        begin
            case(index)
                0:header_byte="Y";1:header_byte="X";2:header_byte="M";3:header_byte="A";
                4:header_byte=1;5:header_byte=2;6:header_byte=16;7:header_byte=0;
                8:header_byte=8'h80;9:header_byte=8'hBB;10,11:header_byte=0;
                12:header_byte=pcm_frames[7:0];13:header_byte=pcm_frames[15:8];14:header_byte=pcm_frames[23:16];15:header_byte=pcm_frames[31:24];
                16:header_byte=pcm_bytes[7:0];17:header_byte=pcm_bytes[15:8];18:header_byte=pcm_bytes[23:16];19:header_byte=pcm_bytes[31:24];
                default:header_byte=0;
            endcase
        end
    endfunction
    assign wav_valid=warm==7 && (header_mode || fifo_valid);
    assign wav_data=header_mode ? header_byte(hi):(fifo_data>>(bi*8));
    assign fifo_rd=wav_valid && wav_ready && !header_mode && bi==3;
    always @(posedge sys_clk) begin
        if(rst) begin en_sync<=0;warm<=0;header_mode<=1;hi<=0;bi<=0;sent<=0;end
        else begin
            en_sync<={en_sync[0],enable};
            if(!en_sync[1]) warm<=0;else if(warm!=7) warm<=warm+1'b1;
            if(wav_valid && wav_ready) begin
                if(header_mode) begin hi<=hi+1'b1;if(hi==31)begin header_mode<=0;bi<=0;sent<=0;end end
                else begin
                    bi<=bi+1'b1;sent<=sent+1'b1;
                    if(sent+22'd1==pcm_bytes[21:0]) begin header_mode<=1;hi<=0;bi<=0;end
                end
            end
        end
    end
endmodule
`default_nettype wire
