`timescale 1ns/1ps
`default_nettype none
// Elastic 1..8-word master to fixed-rate four-port SDRAM service engine.
// All writes are buffered BEFORE grant. All reads are buffered BEFORE output.
module yingxu_sdram_burst_port(
    input wire clk,rst,enable,
    input wire cmd_valid,output wire cmd_ready,input wire cmd_write,
    input wire [20:0] cmd_addr,input wire [3:0] cmd_words,
    input wire wvalid,output wire wready,input wire [31:0] wdata,input wire wlast,
    output wire rvalid,input wire rready,output wire [31:0] rdata,output wire rlast,
    output reg done,error,output wire idle,
    output wire [6:0] debug_write,
    output wire request,input wire grant,output wire write,
    output wire [20:0] addr,output wire [3:0] words,
    output wire [31:0] phy_wdata,output wire [3:0] phy_mask,input wire phy_in_req,phy_out_valid,
    input wire [31:0] phy_rdata,input wire phy_done
);
    localparam IDLE=0,COLLECT=1,WAIT=2,TRANSFER=3,DRAIN=4;
    reg [2:0] state;reg wr,bad;
    reg [20:0] address;reg [3:0] length,position;
    reg [31:0] buffer[0:7];
    assign debug_write={state,position}; // existing functional registers only
    assign idle=state==IDLE;
    assign cmd_ready=idle && enable;
    assign wready=state==COLLECT;
    assign rvalid=state==DRAIN;
    assign rdata=buffer[position[2:0]];
    assign rlast=position+1'b1==length;
    assign request=state==WAIT;
    assign write=wr;assign addr=address;assign words=8;
    assign phy_wdata=position<length ? buffer[position[2:0]]:32'd0;
    assign phy_mask=position<length ? 4'h0:4'hF;
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;wr<=0;bad<=0;address<=0;length<=0;position<=0;done<=0;error<=0;end
        else begin
            done<=0;error<=0;
            case(state)
                IDLE: if(cmd_valid && cmd_ready) begin
                    wr<=cmd_write;address<={cmd_addr[20:3],3'd0};length<=cmd_words;position<=0;bad<=0;
                    // A 21-bit, 8-word-aligned start is <=0x1ffff8.
                    // With 1..8 words the end is <=0x200000 by construction;
                    // a second 22-bit end-address adder/comparator is redundant.
                    if(cmd_addr[2:0]!=0 || cmd_words==0 || cmd_words>8) begin done<=1;error<=1;end
                    else state<=cmd_write ? COLLECT:WAIT;
                end
                COLLECT: if(wvalid && wready) begin
                    buffer[position[2:0]]<=wdata;position<=position+1'b1;
                    if(wlast!=(position+1'b1==length)) bad<=1;
                    if(position+1'b1==length) begin
                        position<=0;
                        if(bad || !wlast) begin done<=1;error<=1;state<=IDLE;end
                        else state<=WAIT;
                    end
                end
                WAIT: if(grant) begin position<=0;state<=TRANSFER;end
                TRANSFER: begin
                    if((wr && phy_in_req) || (!wr && phy_out_valid)) begin
                        if(position<8) begin
                            if(!wr && position<length) buffer[position[2:0]]<=phy_rdata;
                            position<=position+1'b1;
                        end else bad<=1;
                    end
                    if(phy_done) begin
                        if(bad || position+(((wr && phy_in_req)||(!wr && phy_out_valid)) ? 1'b1:1'b0)!=8) begin
                            done<=1;error<=1;state<=IDLE;
                        end else if(wr) begin done<=1;state<=IDLE;end
                        else begin position<=0;state<=DRAIN;end
                    end
                end
                DRAIN: if(rready) begin
                    position<=position+1'b1;
                    if(position+1'b1==length) begin done<=1;state<=IDLE;end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
