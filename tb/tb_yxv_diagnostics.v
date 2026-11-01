`timescale 1ns/1ps
// No decoder/memory traffic is needed to classify the first-header boundary.
module tb_yxv_diagnostics;
    reg clk=0,sys=0,pix=0;always #5 clk=~clk;always #10 sys=~sys;always #6.818 pix=~pix;
    reg rst=1;wire owned,failed,start,sdreset,sready;wire [27:0] lba;wire [15:0] sectors;
    wire [15:0] diagnosis,detail;wire [10:0] count;wire [9:0] badindex;wire [31:0] badword;wire [7:0] code;
    reg busy=0,done=0,reading=0,second=0;integer pos=0,cmds=0,phase=0,limit=512,delay_done=0;
    integer dropped_done=0,cases=0,fd,n,i,j,mode;reg [7:0] data[0:511],original[0:511];
    wire valid=reading;wire [7:0] sdbyte=data[pos];reg [27:0] second_lba;reg [15:0] second_n;
    yingxu_yxv_pipeline #(.STALL_LIMIT(1000)) dut(.sys_clk(sys),.clk(clk),.pix_clk(pix),.rst(rst),.enable(1'b1),.mem_ready(1'b1),
        .sd_init(1'b1),.sd_busy(busy),.sd_done(done),.sd_data(sdbyte),.sd_data_valid(valid),.sd_data_ready(sready),
        .sd_start(start),.sd_lba(lba),.sd_sectors(sectors),.sd_reset(sdreset),.owned(owned),.failed(failed),.error_code(code),
        .diagnosis(diagnosis),.detail(detail),.fail_count(count),.fail_index(badindex),.fail_word(badword),
        .audio_ready(1'b0),.audio_pop(1'b0),.x(11'd0),.y(10'd0),.pixel_active(1'b0),.rd2_data(32'd0),.rd2_empty(1'b1),
        .cmd_ready(1'b0),.wready(1'b0),.rvalid(1'b0),.rdata(32'd0),.rlast(1'b0),.mem_done(1'b0),.mem_error(1'b0),.port_idle(1'b1));
    always @(posedge sys)begin
        if(rst)begin busy<=0;done<=0;reading<=0;second<=0;pos<=0;cmds<=0;delay_done<=0;end
        else begin
            done<=0;
            if(start)begin
                if(cmds==0)begin
                    if(lba!=3000000 || sectors!=1)$fatal(1,"first request");
                    busy<=1;reading<=1;pos<=0;
                end else begin second<=1;second_lba<=lba;second_n<=sectors;end
                cmds<=cmds+1;
            end
            if(valid && sready)begin
                pos<=pos+1;
                if(!dropped_done && phase<0 && pos==limit-1+phase)done<=1;
                if(pos==limit-1)begin
                    reading<=0;busy<=0;
                    if(!dropped_done)begin
                        if(phase==0)done<=1;else if(phase>0)delay_done<=phase;
                    end
                end
            end
            if(delay_done>0)begin delay_done<=delay_done-1;if(delay_done==1)done<=1;end
            if(sdreset)begin busy<=0;reading<=0;end
        end
    end
    task prepare(input integer ph,input integer lim,input integer drop);
        begin
            @(negedge sys);rst=1;phase=ph;limit=lim;dropped_done=drop;
            repeat(5)@(negedge sys);
            for(i=0;i<512;i=i+1)data[i]=original[i];
        end
    endtask
    task failure(input [15:0] expected,input [7:0] why,input integer cnt,input integer idx,input [31:0] value,input [1:0] terminal);
        begin
            rst=0;wait(failed && !owned);repeat(20)@(negedge sys);
            if(diagnosis!==expected || detail[15:8]!==why || count!==cnt || badindex!==idx || badword!==value || code!==expected[7:0])
                $fatal(1,"diagnostic mismatch got=%h reason=%h count=%d idx=%d word=%h",diagnosis,detail,count,badindex,badword);
            if({detail[7],detail[6]}!==terminal)$fatal(1,"rx/ack mismatch");
            if(!dut.local_rst || dut.fault_code!=0 || !failed)$fatal(1,"snapshot not checked after MEM reset");
            cases=cases+1;
            $display("FAULTSNAPCHK: PASS MISE=%h SP=%h ACC=%h WC=%h WORD=%h retained-after-owned-release",diagnosis,detail,count,badindex,badword);
        end
    endtask
    reg [31:0] expected_word;
    initial begin
        fd=$fopen("out/mjpeg_d3/diag486.yxv","rb");if(!fd)$fatal(1,"diag486 required");
        n=$fread(original,fd);$fclose(fd);if(n!=512)$fatal(1,"header fixture");
        for(j=0;j<6;j=j+1)begin
            case(j)0:phase=-4;1:phase=0;2:phase=1;3:phase=2;4:phase=4;5:phase=16;endcase
            prepare(phase,512,0);rst=0;wait(second || failed);@(negedge sys);
            if(failed || second_lba!=3000001 || second_n!=7 || dut.loader.count!=0)$fatal(1,"486 table next request");
            cases=cases+1;$display("METANEXTCHK: PASS done_phase=%0d first512 accepted next_LBA=3000001 sectors=7",phase);
        end
        for(j=0;j<8;j=j+1)begin
            prepare(0,512,0);
            case(j)0:data[0]=0;1:data[4]=2;2:data[10]=25;
                3:begin data[12]=0;data[13]=0;data[14]=0;data[15]=0;end
                4:data[16]=0;5:data[20]=data[20]^1;6:data[24]=0;7:data[28]=data[28]^1;endcase
            expected_word={data[j*4+3],data[j*4+2],data[j*4+1],data[j*4]};
            failure(16'h3992,j+1,512,(j<4 ? 0:486),expected_word,2'b11);
        end
        prepare(0,512,0);data[32]=data[32]^1;expected_word={data[35],data[34],data[33],data[32]};
        failure(16'h3993,8'h11,512,0,expected_word,2'b11);
        prepare(0,512,1);failure(16'h189F,0,512,0,0,2'b10);
        prepare(0,511,0);failure(16'h109F,0,511,0,0,2'b01);
        if(cases!=17)$fatal(1,"vacuous cases");
        $display("DIAGCHK: PASS 17 cases; six done phases, eight header words, bad table, lost done, lost byte");$finish;
    end
    initial begin #1000000;$fatal(1,"diagnostic timeout");end
endmodule
