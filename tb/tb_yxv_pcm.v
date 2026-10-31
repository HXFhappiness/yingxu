`timescale 1ns/1ps
module tb_yxv_pcm;
    reg clk=0,sys=0,pix=0;always #5 clk=~clk;always #10 sys=~sys;always #6.818 pix=~pix;
    reg rst=1,en=0,go=0,tick=0;wire cv,cr,cw,rv,rr,rl,done;
    wire [20:0] ca;wire [3:0] cn;wire [31:0] data;wire failed,idle;
    wire [7:0] wd;wire wv,wr,pop,active;wire [23:0] l,r;wire [10:0] occ;
    integer phase=0,pops=0,ct=0,index=0,delay_done=0,base=0;reg reading=0;reg started=0;
    wire [15:0] left_value=((base+index)*257)^16'hA55A;
    assign data={~left_value,left_value};assign cv_ready_unused=0;
    assign cr=!reading && delay_done==0;
    assign rv=reading;assign rl=index==7;assign done=delay_done==1;
    yingxu_yxv_pcm_feed feed(.clk(clk),.sys_clk(sys),.rst(rst),.enable(en),.pcm_bytes(32'd512),
        .cmd_valid(cv),.cmd_ready(cr),.cmd_write(cw),.cmd_addr(ca),.cmd_words(cn),
        .rvalid(rv),.rready(rr),.rdata(data),.rlast(rl),.mem_done(done),.mem_error(1'b0),.failed(failed),
        .wav_data(wd),.wav_valid(wv),.wav_ready(wr),.idle(idle));
    yingxu_wav_player wav(.sys_clk(sys),.sys_rst(rst),.pix_clk(pix),.pix_rst(rst),.music_active(en),
        .sd_data(wd),.sd_valid(wv),.sd_ready(wr),.out_tick(tick),.wav_l(l),.wav_r(r),.wav_active(active),.dbg_occ(occ),.dbg_pop(pop));
    always @(posedge clk) begin
        if(cv&&cr) begin if(cw||cn!=8) $fatal(1,"PCM read command");base<=ca-21'h100000;index<=0;reading<=1;end
        if(rv&&rr) begin index<=index+1;if(index==7) begin reading<=0;delay_done<=4;end end
        if(delay_done!=0) delay_done<=delay_done-1;
        if(failed) $fatal(1,"PCM reader failed");
    end
    reg [15:0] expected_l,expected_r;reg [23:0] el,er;
    always @(posedge pix) if(!rst) begin
        tick<=0;phase<=phase+48000;
        if(!started && occ>=256) started<=1;
        if(phase>=73333333-48000) begin phase<=phase+48000-73333333;if(started) tick<=1;end
        if(pop) begin
            expected_l=((pops%128)*257)^16'hA55A;expected_r=~expected_l;
            el={{2{expected_l[15]}},expected_l,6'd0};er={{2{expected_r[15]}},expected_r,6'd0};
            #1;if(l!==el || r!==er) $fatal(1,"PCM sample diff pop=%0d L=%h expected=%h",pops,l,el);
            pops=pops+1;
        end
    end
    initial begin repeat(8) @(negedge sys);rst=0;en=1;wait(pops==512);@(negedge sys);
        $display("PCMCHK: PASS pops=512 source_samples=128 loops=4 zero-diff L/R including EOF virtual-header reuse-WAV 48k");$finish;end
    initial begin #50000000;$fatal(1,"PCM timeout pops=%0d occ=%0d",pops,occ);end
endmodule
