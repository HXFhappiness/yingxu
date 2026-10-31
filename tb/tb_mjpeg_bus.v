`timescale 1ns/1ps
module tb_mjpeg_arbiter;
    reg clk=0;always #5 clk=~clk;reg rst=1;
    reg [2:0] cv=0,cwrite=3'b010,wv=0,wl=7,rr=7;wire [2:0] cr,wr,rv,done,err;
    reg [62:0] addr={21'd300,21'd200,21'd100};reg [11:0] words={4'd8,4'd8,4'd8};
    reg [95:0] wd={32'hCCCCCCCC,32'hBBBBBBBB,32'hAAAAAAAA};
    wire mv,mwrite,mwv,mwl,mrr,mrl;wire [20:0] ma;wire [3:0] mn;wire [31:0] mwd,rd;
    reg mr=0,mwr=1,mrv=0,mrlast=1,mdone=0,merror=0;
    wire [31:0] mrd=32'hDEADBEEF;
    integer owner,n=0;
    yingxu_mjpeg_arbiter dut(.clk(clk),.rst(rst),.cvalid(cv),.cready(cr),.cwrite(cwrite),.caddr(addr),.cwords(words),
        .cwvalid(wv),.cwready(wr),.cwdata(wd),.cwlast(wl),.crvalid(rv),.crready(rr),.crdata(rd),.crlast(mrl),
        .cdone(done),.cerror(err),.mvalid(mv),.mready(mr),.mwrite(mwrite),.maddr(ma),.mwords(mn),
        .mwvalid(mwv),.mwready(mwr),.mwdata(mwd),.mwlast(mwl),.mrvalid(mrv),.mrready(mrr),.mrdata(mrd),.mrlast(mrlast),
        .mdone(mdone),.merror(merror));
    task service(input integer expected,input integer failure);
        begin
            #1;if(!mv || ma!=(expected+1)*100 || mn!=8) $fatal(1,"priority/address grant");
            mr=1;@(negedge clk);mr=0;cv[expected]=0;
            if(mv) $fatal(1,"owner released before done");
            if(expected==1) begin
                wv=2;#1;if(!mwv || mwd!==32'hBBBBBBBB || wr!==2 || !mwl) $fatal(1,"write routing");
            end else begin
                mrv=1;#1;if(rv!==(3'b001<<expected) || rd!==mrd || !mrr || !mrl) $fatal(1,"read routing");
            end
            repeat(4) @(negedge clk);
            if(mv) $fatal(1,"burst interleaved");
            mdone=!failure;merror=failure;#1;
            if(failure ? err!==(3'b001<<expected) : done!==(3'b001<<expected)) $fatal(1,"completion owner");
            $display("GRANT_TRACE: owner=%0d failure=%0d",expected,failure);
            @(negedge clk);mdone=0;merror=0;wv=0;mrv=0;n=n+1;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;cv=7;
        repeat(3) @(negedge clk);service(0,0);service(1,0);service(2,1);
        // A command already exposed under stall cannot change when display arrives.
        cv=4;@(negedge clk);cv=5;repeat(3) @(negedge clk);
        if(ma!=300) $fatal(1,"stalled command owner changed");
        service(2,0);service(0,0);
        if(n!=5) $fatal(1,"vacuous arbiter coverage");
        $display("ARBCHK: PASS grants=5 priority=display>decode>other owner-until-done stalled-command-stable error-routed");$finish;
    end
    initial begin #10000;$fatal(1,"arbiter timeout");end
endmodule

module tb_mjpeg_mailbox;
    reg sclk=0,dclk=0;always #10 sclk=~sclk;always #5 dclk=~dclk;
    reg rst=1,sv=0;wire sr,sd,dv;reg dr=0,dd=0;
    reg [57:0] payload=0;wire [57:0] dp;wire [8:0] status;reg [8:0] ds=0;
    integer timer=0,requests=0,responses=0,i;reg [57:0] expected;
    yingxu_mjpeg_mailbox dut(.sclk(sclk),.dclk(dclk),.rst(rst),.svalid(sv),.sready(sr),.spayload(payload),
        .sdone(sd),.sstatus(status),.dvalid(dv),.dready(dr),.dpayload(dp),.ddone(dd),.dstatus(ds));
    always @(posedge dclk) begin
        if(rst) begin timer<=0;dr<=0;dd<=0;requests<=0;end
        else begin
            dd<=0;dr<=~dr;
            if(dv && dr) begin
                if(dp!==expected) $fatal(1,"mailbox payload coherence");
                timer<=7;ds<=dp[8:0]^9'h155;requests<=requests+1;
            end
            if(timer!=0) begin timer<=timer-1;if(timer==1) dd<=1;end
        end
    end
    task send(input integer seq);
        begin
            wait(sr);@(negedge sclk);expected=58'h12345678000000+seq;payload=expected;sv=1;
            @(negedge sclk);sv=0;payload=~expected;
            wait(sd);@(negedge sclk);
            if(status!==(expected[8:0]^9'h155) || !sr) $fatal(1,"mailbox completion coherence");
            $display("MAILBOX_TRACE: payload=%h status=%h",expected,status);
            responses=responses+1;
        end
    endtask
    initial begin
        repeat(5) @(negedge sclk);rst=0;
        for(i=0;i<8;i=i+1) send(i);
        if(requests!=8 || responses!=8) $fatal(1,"mailbox request ratio");
        // Cancel a request with common reset, then require fresh replay only.
        @(negedge sclk);expected=58'd99;payload=expected;sv=1;
        @(negedge sclk);sv=0;rst=1;
        repeat(5) @(negedge sclk);rst=0;responses=0;
        for(i=0;i<8;i=i+1) send(i+20);
        if(requests!=8 || responses!=8) $fatal(1,"mailbox reset/replay ratio");
        $display("MAILBOXCHK: PASS requests/responses=8/8 x2 unrelated-clocks held-bus backpressure reset-replay");$finish;
    end
    initial begin #100000;$fatal(1,"mailbox timeout");end
endmodule
