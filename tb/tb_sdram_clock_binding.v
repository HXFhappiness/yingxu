`timescale 1ns/1ps
`default_nettype none
// Actual production controller and adapter: no clock fault injection.
module tb_sdram_clock_binding #(parameter integer EXPECT_SHADOW=0);
    reg sys=0;always #10 sys=~sys;
    reg reset_n=0,valid=0,wvalid=0;
    reg [31:0] data=0;reg last=0;
    wire clk,ready,wready;wire[6:0]wd;wire[4:0]cd;wire[31:0]dq;
    integer parent_edges=0,receiver_edges=0,acks=0,words=0,i;
    always @(posedge clk)begin parent_edges=parent_edges+1;if(valid && ready)acks=acks+1;end
    always @(posedge dut.mj_port.port_adapter.clk)receiver_edges=receiver_edges+1;
    yingxu_sdram_control_4port #(.MJPEG_PORT(1)) dut(
        .REF_CLK(sys),.RESET_N(reset_n),.CLK(clk),.DQ(dq),
        .WR1_DATA(32'd0),.WR1(1'b0),.WR1_ADDR(21'd0),.WR1_MAX_ADDR(21'd128),.WR1_LENGTH(9'd128),.WR1_LOAD(1'b0),.WR1_CLK(clk),
        .WR2_DATA(32'd0),.WR2(1'b0),.WR2_ADDR(21'd0),.WR2_MAX_ADDR(21'd128),.WR2_LENGTH(9'd128),.WR2_LOAD(1'b0),.WR2_CLK(sys),
        .RD1(1'b0),.RD1_ADDR(21'd0),.RD1_MAX_ADDR(21'd128),.RD1_LENGTH(9'd128),.RD1_LOAD(1'b0),.RD1_CLK(sys),
        .RD2(1'b0),.RD2_ADDR(21'd0),.RD2_MAX_ADDR(21'd128),.RD2_LENGTH(9'd128),.RD2_LOAD(1'b0),.RD2_CLK(sys),
        .MJ_ACTIVE(1'b1),.MJ_VALID(valid),.MJ_READY(ready),.MJ_WRITE(1'b1),.MJ_ADDR(21'h100000),.MJ_WORDS(4'd8),
        .MJ_WVALID(wvalid),.MJ_WREADY(wready),.MJ_WDATA(data),.MJ_WLAST(last),
        .MJ_RREADY(1'b1),.MJ_DEBUG_WRITE(wd),.MJ_DEBUG_CMD(cd));
    initial begin
        repeat(8)@(negedge clk);reset_n=1;valid=1;
        if(EXPECT_SHADOW)begin
            repeat(20)@(negedge clk);
            if(receiver_edges!=0 || parent_edges<25 || dut.mj_port.port_adapter.clk!==1'bz || acks!=0)
                $fatal(1,"forward-declaration shadow was not reproduced");
            $display("CLOCK_SHADOW_REPRO PASS parent_edges=%0d receiver_edges=%0d receiver_clk=Z ACKs=%0d; unmodified baseline RTL, no clock force",parent_edges,receiver_edges,acks);
        end else begin
            wait(ready);@(posedge clk);@(negedge clk);valid=0;
            for(i=0;i<8;i=i+1)begin
                wvalid=1;data=32'habc00000+i;last=(i==7);
                @(posedge clk);if(!wready)$fatal(1,"data not accepted");words=words+1;
                @(negedge clk);
            end
            wvalid=0;
            if(parent_edges!=receiver_edges || acks!=1 || words!=8 || wd[6:4]!=2 || !cd[0])
                $fatal(1,"correct binding/capture/data checks failed");
            $display("CLOCK_BINDING PASS parent_edges=%0d receiver_edges=%0d ACKs=1 data_words=8 state=WAIT sampled_VALID=1",parent_edges,receiver_edges);
        end
        $finish;
    end
    initial begin #10000;$fatal(1,"clock binding timeout");end
endmodule
`default_nettype wire
