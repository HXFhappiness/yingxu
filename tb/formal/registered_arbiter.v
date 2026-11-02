`default_nettype none
module registered_arbiter(input wire clk,rst,input wire[2:0]valid,wvalid,wlast,rready,
    input wire[2:0]write_cmd,input wire[62:0]address,input wire[11:0]words,
    input wire[95:0]wdata,input wire ready,write_ready,read_valid,last,done,error,
    input wire[31:0]read_data,output wire safe);
    wire[2:0]ack,wa,rv,cd,ce,owner;
    wire mv,mw,mwv,mwl,mrr;wire[20:0]ma;wire[3:0]mn;wire[31:0]md;
    yingxu_mjpeg_arbiter dut(.clk(clk),.rst(rst),.cvalid(valid),.cready(ack),.cwrite(write_cmd),
        .caddr(address),.cwords(words),.cwvalid(wvalid),.cwready(wa),.cwdata(wdata),.cwlast(wlast),
        .crvalid(rv),.crready(rready),.crdata(),.crlast(),.cdone(cd),.cerror(ce),
        .mvalid(mv),.mready(ready),.mwrite(mw),.maddr(ma),.mwords(mn),
        .mwvalid(mwv),.mwready(write_ready),.mwdata(md),.mwlast(mwl),
        .mrvalid(read_valid),.mrready(mrr),.mrdata(read_data),.mrlast(last),
        .debug_owner(owner),.mdone(done),.merror(error));
    reg history,stalled,active,last_end;reg[2:0]saved_owner;reg[25:0]payload;
    always @(posedge clk)begin
        if(rst)begin history<=0;stalled<=0;active<=0;last_end<=0;saved_owner<=0;payload<=0;end
        else begin
            history<=1;stalled<=mv && !ready;active<=owner[2];last_end<=done || error;
            saved_owner<=owner;payload<={mw,ma,mn};
        end
    end
    wire hold_ok=!history || !stalled || (mv && payload=={mw,ma,mn});
    wire owner_ok=!history || !active || last_end || owner==saved_owner;
    wire one_ack=ack==0 || ack==1 || ack==2 || ack==4;
    wire ack_ok=(ack!=0)==(mv && ready);
    wire idle_ok=!(owner[2] && mv) && (owner[2] || (wa==0 && rv==0 && cd==0 && ce==0));
    assign safe=rst || (hold_ok && owner_ok && one_ack && ack_ok && idle_ok);
endmodule
`default_nettype wire
