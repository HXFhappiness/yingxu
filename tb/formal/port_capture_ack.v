`default_nettype none
module port_capture_ack(input wire clk,rst,enable,source_valid,drop_valid,write_cmd,
    input wire [20:0] command_addr,input wire [3:0] command_words,
    input wire wvalid,wlast,rready,grant,in_req,out_valid,phy_done,
    input wire [31:0] wdata,rdata,output wire safe);
    wire ready,idle,done,error;wire [6:0]debug_state;
    yingxu_sdram_burst_port dut(.clk(clk),.rst(rst),.enable(enable),
        .cmd_valid(source_valid && !drop_valid),.cmd_ready(ready),.cmd_write(write_cmd),
        .cmd_addr(command_addr),.cmd_words(command_words),.wvalid(wvalid),.wready(),
        .wdata(wdata),.wlast(wlast),.rvalid(),.rready(rready),.rdata(),.rlast(),
        .done(done),.error(error),.idle(idle),.debug_write(debug_state),
        .request(),.grant(grant),.write(),.addr(),.words(),.phy_wdata(),.phy_mask(),
        .phy_in_req(in_req),.phy_out_valid(out_valid),.phy_rdata(rdata),.phy_done(phy_done));
    reg captured,ack_prev,write_saved,bad_saved;
    always @(posedge clk)begin
        if(rst)begin captured<=0;ack_prev<=0;write_saved<=0;bad_saved<=0;end
        else begin
            ack_prev<=ready;
            if(done)captured<=0;
            if(idle && enable && source_valid && !drop_valid)begin
                captured<=1;write_saved<=write_cmd;
                bad_saved<=command_addr[2:0]!=0 || command_words==0 || command_words>8;
            end
        end
    end
    // Even arbitrary omission of valid cannot create an upstream acceptance
    // before this receiver has latched the payload. ACK uses those saved fields.
    wire safe_accept=!(source_valid && ready) || (captured && !idle);
    wire safe_next=!ack_prev || (bad_saved ? (done && error && idle):
                   write_saved ? debug_state[6:4]==1:debug_state[6:4]==2);
    assign safe=rst || (safe_accept && safe_next);
endmodule
`default_nettype wire
