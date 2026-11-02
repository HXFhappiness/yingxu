`timescale 1ns/1ps
module tb_d7_menu_pixels;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,visible=1,page=0,we=0,en=0,scan_enable=1;
    reg [2:0]sel=0;reg[3:0]slot=0;reg[9:0]bar_y=268;
    reg[10:0]x=0;reg[9:0]y=0;
    wire active=x<1280 && y<720;wire[23:0]bg,rgb;
    reg[7:0]logo[0:3199];reg[23:0]palette[0:9],previous;
    reg[31:0]font[0:543];reg[23:0]main_pixels[0:921599],sub_pixels[0:921599];
    reg[1023:0]font_path,out_path,logo_path;integer rc,k,p,s,fd,checks=0;
    reg[23:0]expected,base;reg ink,canvas,green;
    integer line_no,row_no,column_no,glyph,n,address;
    yingxu_menu_ui dut(.clk(clk),.rst(rst),.pixel_x(x),.pixel_y({1'b0,y}),
        .pixel_active(active),.menu_visible(visible),.page(page),.sel(sel),.menu_rgb(bg));
    yingxu_sprite_engine sprite(.clk(clk),.rst(rst),.pixel_x(x),.pixel_y(y),
        .pixel_active(active),.bg_rgb(bg),.we(we),.slot(slot),.en(en),
        .spr_x(11'd930),.spr_y(bar_y),.spr_w(7'd12),.spr_h(6'd56),
        .spr_color(24'h00A651),.brick_mask(60'd0),.tile_rgb(24'd0),.rgb_out(rgb));
    // Same NBA raster phase as production video_source_test.
    always @(posedge clk)if(!rst && scan_enable)begin
        if(x==1649)begin x<=0;if(y==749)y<=0;else y<=y+1'b1;end
        else x<=x+1'b1;
    end
    task golden;
        begin
            base=palette[(x+y)/200];
            if(x>=40 && x<200 && y>=28 && y<188 &&
               logo[(y-28)*20+(x-40)/8][7-((x-40)%8)])base=24'hFFFFFF;
            if(x>=820 && x<=1190 && y>=240 && y<=700)begin
                if(x<826 || x>1184 || y<246 || y>694)base=0;
                else base=24'hC8B45A;
            end
            line_no=-1;row_no=0;
            for(n=0;n<5;n=n+1)if(y>=280+87*n && y<312+87*n)begin
                line_no=n;row_no=y-(280+87*n);
            end
            column_no=(x-950)/32;glyph=-1;
            if(x>=950 && x<1078 && line_no>=0)begin
                if(!page && column_no<2)glyph=line_no*2+column_no;
                else if(page && line_no==0 && column_no<3)glyph=10+column_no;
                else if(page && line_no==1 && column_no<4)glyph=13+column_no;
            end
            ink=0;canvas=glyph>=0;
            if(canvas)ink=font[glyph*32+row_no][31-((x-950)%32)];
            expected=ink ? 24'd0:base;
        end
    endtask
    task check_frame;
        begin
            // A whole blanking period is available for slot writes/line rendering.
            while(!(x==0&&y==720))@(negedge clk);
            page=p[0];sel=s[2:0];bar_y=268+87*s;slot=15;en=1;we=1;
            repeat(2)@(negedge clk);we=0;
            while(!(x==0&&y==0))@(negedge clk);
            fd=0;
            if((p==0&&s==0)||(p==1&&s==1))begin
                if(p==0)fd=$fopen($sformatf("%0s/main.ppm",out_path),"wb");
                else fd=$fopen($sformatf("%0s/games.ppm",out_path),"wb");
                if(!fd)$fatal(1,"frame output");
                $fwrite(fd,"P6\n1280 720\n255\n");
            end
            while(y<720)begin
                if(active)begin
                    golden();address=y*1280+x;
                    if(bg!==expected)$fatal(1,"menu pixel page=%0d sel=%0d x=%0d y=%0d got=%h expected=%h",
                        page,sel,x,y,bg,expected);
                    // Every selection on a given page has identical background/text.
                    if(p==0)begin
                        if(s==0)main_pixels[address]=bg;
                        else if(bg!==main_pixels[address])$fatal(1,"selection changed menu RGB");
                    end else begin
                        if(s==0)sub_pixels[address]=bg;
                        else if(bg!==sub_pixels[address])$fatal(1,"sub selection changed menu RGB");
                        // Exclude the union of both pages' text canvases only.
                        if(!(x>=950&&x<1078&&line_no>=0) && bg!==main_pixels[address])
                            $fatal(1,"page changed fixed background or panel");
                    end
                    green=x>=930&&x<942&&y>=bar_y&&y<bar_y+56;
                    // Existing sprite line RAM stores RGB565: 00A651 expands to 00A652.
                    if(rgb!==(green ? 24'h00A652:expected))
                        $fatal(1,"composition page=%0d sel=%0d x=%0d y=%0d got=%h expected=%h",
                            page,sel,x,y,rgb,green ? 24'h00A652:expected);
                    if(green&&canvas)$fatal(1,"marker overlaps text");
                    if(fd)$fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);
                    checks=checks+1;
                end
                @(negedge clk);
            end
            if(fd)$fclose(fd);
            $display("D8_PIXELS PASS page=%0d sel=%0d raster, glyphs/logo, gradient, invariant background/panel, sprite composition",p,s);
        end
    endtask
    initial begin
        if(!$value$plusargs("font=%s",font_path))$fatal(1,"font fixture");
        rc=$value$plusargs("out=%s",out_path);$readmemh(font_path,font);
        if(!$value$plusargs("logo=%s",logo_path))$fatal(1,"logo fixture");
        $readmemh(logo_path,logo);
        palette[0]=24'h0A1030;palette[1]=24'h0B1838;palette[2]=24'h0F2040;
        palette[3]=24'h14284C;palette[4]=24'h1A3055;palette[5]=24'h31415E;
        palette[6]=24'h4A5570;palette[7]=24'h6B7280;palette[8]=24'h8A9099;
        palette[9]=24'hB0B4B8;
        // Disable all slots through the real table write port.
        repeat(2)@(negedge clk);we=1;en=0;
        for(k=0;k<16;k=k+1)begin slot=k[3:0];@(negedge clk);end
        we=0;rst=0;
        for(p=0;p<2;p=p+1)for(s=0;s<(p ? 2:5);s=s+1)check_frame();
        // Traverse all 1999 diagonal coordinates outside panel/logo regions.
        scan_enable=0;previous=0;
        for(k=0;k<=1998;k=k+1)begin
            x=k<=1279 ? k:1279;y=k<=1279 ? 0:k-1279;#1;
            if(bg!==palette[k/200])$fatal(1,"gradient band/end point %0d",k);
            if(bg[23:16]<previous[23:16] || bg[15:8]<previous[15:8] || bg[7:0]<previous[7:0])
                $fatal(1,"gradient is not monotone");
            previous=bg;
        end
        visible=0;#1;if(bg!==0)$fatal(1,"hidden menu not blank");
        visible=1;rst=1;#1;if(bg!==0)$fatal(1,"reset menu not blank");
        $display("D8_PIXEL_ACCEPTANCE PASS active_pixels=%0d scenarios=7",checks);$finish;
    end
    initial begin #110000000;$fatal(1,"pixel test timeout");end
endmodule
