`timescale 1ns/1ps
module tb_mjpeg_physical;
    reg refclk=0;always #10 refclk=~refclk;wire clk;
    reg reset_n=0,cv=0,cw=0,wv=0,rr=1;
    reg [20:0] ca=0;reg [3:0] cn=0;reg [31:0] wd=0;reg wl=0;
    wire cr,wr,rv,rl,done,error,idle;wire [31:0] rd;wire [31:0] dq;
    wire [31:0] display_data;reg display_pop=0;
    integer n,i,j,cycles=0,disp=0,trans=0;
    yingxu_sdram_control_4port #(.MJPEG_PORT(1)) dut(
        .REF_CLK(refclk),.RESET_N(reset_n),.CLK(clk),
        .WR1_DATA(32'd0),.WR1(1'b0),.WR1_ADDR(21'd0),.WR1_MAX_ADDR(21'd128),.WR1_LENGTH(9'd128),.WR1_LOAD(1'b0),.WR1_CLK(clk),
        .WR2_DATA(32'd0),.WR2(1'b0),.WR2_ADDR(21'd0),.WR2_MAX_ADDR(21'd128),.WR2_LENGTH(9'd128),.WR2_LOAD(1'b0),.WR2_CLK(clk),
        .RD1(1'b0),.RD1_ADDR(21'd0),.RD1_MAX_ADDR(21'd128),.RD1_LENGTH(9'd128),.RD1_LOAD(1'b0),.RD1_CLK(clk),
        .RD2(display_pop),.RD2_DATA(display_data),.RD2_ADDR(21'd1024),.RD2_MAX_ADDR(21'd1152),.RD2_LENGTH(9'd128),.RD2_LOAD(1'b0),.RD2_CLK(clk),
        .DQ(dq),.MJ_ACTIVE(1'b1),.MJ_VALID(cv),.MJ_READY(cr),.MJ_WRITE(cw),.MJ_ADDR(ca),.MJ_WORDS(cn),
        .MJ_WVALID(wv),.MJ_WREADY(wr),.MJ_WDATA(wd),.MJ_WLAST(wl),
        .MJ_RVALID(rv),.MJ_RREADY(rr),.MJ_RDATA(rd),.MJ_RLAST(rl),.MJ_DONE(done),.MJ_ERROR(error),.MJ_IDLE(idle));
    d3_sdram_memory model(.clk(clk),.read(dut.Read),.write(dut.Write),.oe(dut.oe),.addr(dut.mADDR),
        .in_req(dut.IN_REQ),.out_valid(dut.OUT_VALID),.mask(dut.mj_owner ? dut.mj_mask:4'd0),.data(dut.mDATAIN),.dq(dq));
    always @(posedge clk) begin
        cycles<=cycles+1;
        if(reset_n && dut.mj_grant && !dut.rd2_afull_w) $fatal(1,"display priority violated");
        if(reset_n && dut.OUT_VALID && dut.RD_MASK[1]) disp<=disp+1;
        if(reset_n && error) $fatal(1,"adapter error");
    end
    task command(input integer write_mode,input integer count);
        begin
            @(negedge clk);cw=write_mode;cn=count;ca=21'd4096+count*16;cv=1;
            do @(posedge clk); while(!cr);
            @(negedge clk);cv=0;
        end
    endtask
    initial begin
        for(i=0;i<128;i=i+1) model.memory[1024+i]=32'h12340000+i;
        repeat(8) @(negedge clk);reset_n=1;
        for(n=1;n<=8;n=n+1) begin
            for(j=0;j<16;j=j+1) model.memory[4096+n*16+j]=32'hdeadbeef;
            command(1,n);
            for(i=0;i<n;i=i+1) begin
                repeat(i%3) @(negedge clk);
                wv=1;wd=32'habc00000+n*256+i;wl=(i==n-1);
                do @(posedge clk);while(!wr);
                @(negedge clk);wv=0;
            end
            wait(done);@(negedge clk);if(error) $fatal(1,"write failed");
            for(i=0;i<n;i=i+1) if(model.memory[4096+n*16+i]!==32'habc00000+n*256+i) $fatal(1,"physical write mismatch n=%0d i=%0d",n,i);
            for(j=n;j<16;j=j+1) if(model.memory[4096+n*16+j]!==32'hdeadbeef) $fatal(1,"DQM tail overwritten");
            command(0,n);rr=0;wait(rv);repeat(4) @(negedge clk);
            for(i=0;i<n;i=i+1) begin
                if(rd!==32'habc00000+n*256+i || rl!==(i==n-1)) $fatal(1,"physical read mismatch n=%0d i=%0d got=%h",n,i,rd);
                rr=1;@(negedge clk);rr=0;if(i!=n-1) repeat(2) @(negedge clk);
            end
            wait(done);@(negedge clk);trans=trans+2;
        end
        if(disp<128 || trans!=16) $fatal(1,"vacuous coverage");
        $display("PHYPORTCHK: PASS transactions=%0d 1..8word write/read zero-diff stalls owner real-controller done; display_words=%0d",trans,disp);$finish;
    end
    initial begin #500000; $display("TIMEOUT cmd=%d reada=%d writea=%d cref=%d rp=%d cdone=%d ex=%b%b PMSTOP=%d PMDONE=%d",dut.CMD,dut.reada,dut.writea,dut.ref_req,dut.command1.rp_done,dut.command1.command_done,dut.command1.ex_read,dut.command1.ex_write,dut.PM_STOP,dut.PM_DONE);$fatal(1,"physical port timeout n=%0d state=%0d ST=%0d masks=%b/%b",n,dut.mj_port.port_adapter.state,dut.ST,dut.RD_MASK,dut.WR_MASK);end
endmodule
