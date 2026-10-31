`timescale 1ns/1ps
module tb_yxv_scanout;
    reg clk=0;always #6.818 clk=~clk;reg rst=1;reg [10:0] x=0;reg [9:0] y=0;
    reg fv=0,fb=0;reg [31:0] ft=0;wire fr,fd,dv,en,load,uf;
    wire [31:0] tag;wire [20:0] addr,maxaddr;wire [8:0] len;wire [23:0] rgb;
    integer checked0=0,checked1=0,acks=0;reg previous_bank=0;
    wire [31:0] data=addr==0 ? 32'hF800001F:32'h07E0FFFF;
    yingxu_yxv_scanout dut(.clk(clk),.rst(rst),.x(x),.y(y),.active(x<1280&&y<720),
        .frame_valid(fv),.frame_ready(fr),.frame_bank(fb),.frame_tag(ft),.frame_done(fd),.displayed_tag(tag),.displayed_valid(dv),
        .rd_data(data),.rd_empty(1'b0),.rd_en(en),.rd_load(load),.rd_addr(addr),.rd_max(maxaddr),.rd_len(len),.rgb(rgb),.underflow(uf));
    always @(posedge clk) if(!rst) begin
        if(x==1649)begin x<=0;y<=y==749?0:y+1'b1;end else x<=x+1'b1;
        if(fd)acks<=acks+1;
    end
    always @(negedge clk) if(!rst) begin
        if(dut.bank!=previous_bank && !(x==1 && y==600)) $fatal(1,"swap outside blank");
        previous_bank=dut.bank;
        if(dv && dut.primed && x>=322 && x<=959 && y>=120 && y<600) begin
            if(tag==0) begin
                if(rgb!==((x-1)%2 ? 24'h0000FF:24'hFF0000))$fatal(1,"565 half order frame0 x=%0d got=%h",x,rgb);
                checked0=checked0+1;
            end else begin
                if(rgb!==((x-1)%2 ? 24'hFFFFFF:24'h00FF00))$fatal(1,"565 half order frame1");
                checked1=checked1+1;
            end
        end
        if(uf) $fatal(1,"underflow");
    end
    initial begin
        repeat(8) @(negedge clk);rst=0;fv=1;wait(fd);@(negedge clk);fv=0;
        wait(y==120);wait(y==599);@(negedge clk);fb=1;ft=1;fv=1;
        wait(fd);@(negedge clk);fv=0;wait(y==120);wait(y==599);@(negedge clk);
        if(checked0<300000 || checked1<300000 || acks!=2) $fatal(1,"vacuous scanout count");
        $display("SCANOUTCHK: PASS centered640x480 high-half-first both banks pixels=%0d/%0d vblank swaps=2 stretched flush no-underflow",checked0,checked1);$finish;
    end
    initial begin #100000000;$fatal(1,"scanout timeout");end
endmodule
