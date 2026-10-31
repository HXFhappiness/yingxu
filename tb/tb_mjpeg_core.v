`timescale 1ns/1ps
module tb_mjpeg_core;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,start=0;reg [15:0] length;
    reg [7:0] src[0:65535];reg [15:0] gold[0:307199];
    reg [23:0] gc[0:460799];reg [26:0] gt[0:460799];reg [7:0] gs[0:460799];
    reg seen[0:307199];
    reg [7:0] table_gold[0:1023];reg table_mask[0:1023];
    reg [15:0] desc_gold[0:127];reg desc_mask[0:127];
    reg tables_checked=0;integer core_tick=0,idct_begin=0,idct_max=0,idct_count=0;
    wire ready,valid,busy,done,error;wire [7:0] code;
    wire [15:0] pixel;wire [9:0] x;wire [8:0] y;wire [31:0] cycles;
    integer ptr=0,npix=0,nblock=0,nsample=0,i,j,outfile;
    reg sink=1;reg [31:0] rng=32'h9abc1234;integer stalls=0;
    reg [1023:0] prefix,filename;
    yingxu_jpeg_core dut(.clk(clk),.rst(rst),.start(start),.frame_bytes(length),
        .byte_data(src[ptr]),.byte_valid(1'b1),.byte_ready(ready),
        .pixel_valid(valid),.pixel_ready(sink),.pixel(pixel),.pixel_x(x),.pixel_y(y),
        .busy(busy),.done(done),.error(error),.error_code(code),.cycles(cycles));
    always @(negedge clk) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        sink=stalls ? rng[3:0]!=0:1;
    end
    always @(posedge clk) if(!rst) begin
        core_tick=core_tick+1;
        if(dut.hs==16 && !tables_checked) begin
            for(j=0;j<1024;j=j+1) if(table_mask[j] && dut.tables[j]!==table_gold[j])
                $fatal(1,"TABLECHK symbol/quant address=%0d",j);
            for(j=0;j<128;j=j+1) if(desc_mask[j] && dut.descriptors[j]!==desc_gold[j])
                $fatal(1,"TABLECHK descriptor address=%0d",j);
            tables_checked=1;
        end
        if(ready) ptr<=ptr+1;
        if(dut.idct_done) begin
            if(core_tick-idct_begin>idct_max) idct_max=core_tick-idct_begin;
            idct_count=idct_count+1;
        end
        if(dut.idct_start) begin
            idct_begin=core_tick;
            for(j=0;j<64;j=j+1)
                if({dut.coeff[{dut.bank,7'd0}+j*2+1][7:0],dut.coeff[{dut.bank,7'd0}+j*2]} !== gc[nblock*64+j])
                    $fatal(1,"COEFCHK block=%0d k=%0d actual=%0d expected=%0d",nblock,j,$signed({dut.coeff[{dut.bank,7'd0}+j*2+1][7:0],dut.coeff[{dut.bank,7'd0}+j*2]}),$signed(gc[nblock*64+j]));
            nblock=nblock+1;
        end
        if(dut.u_idct.busy && !dut.u_idct.phase && dut.u_idct.serial)
            if(dut.u_idct.result[dut.u_idct.serial_pos[3:1]]!==gt[(nblock-1)*64+{dut.u_idct.serial_vector,dut.u_idct.serial_pos[3:1]}])
                $fatal(1,"IDCT_TEMPCHK block=%0d",nblock-1);
        if(dut.sample_valid) begin
            if(dut.sample_value!==gs[(nblock-1)*64+dut.sample_index])
                $fatal(1,"IDCTCHK block=%0d i=%0d actual=%0d expected=%0d",nblock-1,dut.sample_index,dut.sample_value,gs[(nblock-1)*64+dut.sample_index]);
            nsample=nsample+1;
        end
        if(valid && sink) begin
            i=y*640+x;
            if(x>=640 || y>=480 || seen[i] || pixel!==gold[i])
                $fatal(1,"PIXCHK index=%0d x=%0d y=%0d actual=%04h expected=%04h seen=%b",npix,x,y,pixel,gold[i],seen[i]);
            seen[i]=1;npix=npix+1;
        end
        if(error) $fatal(1,"JPEG error=%02h input=%0d hs=%0d es=%0d block=%0d",code,ptr,dut.hs,dut.es,nblock);
    end
    initial begin
        if(!$value$plusargs("prefix=%s",prefix) || !$value$plusargs("length=%d",length)) $fatal(1,"prefix/length required");
        i=$value$plusargs("stalls=%d",stalls);
        $readmemh({prefix,".jpg.hex"},src,0,length-1);
        $readmemh({prefix,".pixels.hex"},gold);
        $readmemh({prefix,".coef.hex"},gc);
        $readmemh({prefix,".temp.hex"},gt);
        $readmemh({prefix,".samples.hex"},gs);
        $readmemh({prefix,".table.hex"},table_gold);$readmemh({prefix,".tablemask.hex"},table_mask);
        $readmemh({prefix,".desc.hex"},desc_gold);$readmemh({prefix,".descmask.hex"},desc_mask);
        for(i=0;i<307200;i=i+1) seen[i]=0;
        repeat(5) @(negedge clk);rst=0;start=1;@(negedge clk);start=0;
        wait(done);@(negedge clk);
        if(error) $fatal(1,"JPEG error=%02h ptr=%0d hs=%0d es=%0d blocks=%0d",code,ptr,dut.hs,dut.es,nblock);
        if(ptr!=length || npix!=307200 || nblock!=7200 || nsample!=460800) $fatal(1,"coverage counts");
        for(i=0;i<307200;i=i+1) if(!seen[i]) $fatal(1,"missing address");
        if(!tables_checked || idct_count!=7200 || idct_max>304) $fatal(1,"TABLE/IDCT coverage or cycle budget");
        $display("TABLECHK: PASS all loaded DHT/DQT words zero-diff; IDCT_TEMPCHK 460800/460800; IDCT max_cycles=%0d blocks=%0d/7200",idct_max,idct_count);
        $display("MJPEG_CORE: PASS bytes=%0d/%0d blocks=%0d/7200 samples=%0d/460800 pixels=%0d/307200 cycles=%0d ratio_frame_x10000=%0d",ptr,length,nblock,nsample,npix,cycles,cycles*24/10000);
        $finish;
    end
    initial begin #100_000_000;$fatal(1,"TB timeout");end
endmodule
