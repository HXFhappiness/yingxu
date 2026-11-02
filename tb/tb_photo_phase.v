`timescale 1ns/1ps
// Native 1280x720 raster and actual production replay/SDRAM controller.
// FIFO, SDRAM cells and PLL are functional models, not pin timing models.
module tb_photo_phase;
    reg sys=0,pix=0;always #10 sys=~sys;always #6.734 pix=~pix;
    reg rst=1,loaded=0;wire clk;wire [31:0] dq,data;
    wire empty,rd,load;wire[20:0] addr,maxaddr;wire[8:0]len;wire[23:0]rgb;
    reg[10:0]x=0;reg[9:0]y=720;
    integer frames=0,i,expect_stable,rc,mismatches=0,checked=0;
    integer busy_reloads=0;reg load_q=0;
    reg [31:0] reference[0:460799];
    yingxu_sdram_video_player p(
        .pixel_clk(pix),.rst(rst),.pixel_x(x),.pixel_y(y),
        .pixel_active(x<1280&&y<720),.loaded(loaded),.rd2_data(data),
        .rd2_empty(empty),.rd2_en(rd),.rd2_load(load),.rd2_addr(addr),
        .rd2_max_addr(maxaddr),.rd2_len(len),.i_base(21'd0),.fade_dark(4'd0),
        .bright_en(1'b0),.contrast_en(1'b0),.rgb_out(rgb),
        .i_video_en(1'b0),.i_video_rgb(24'd0));
    yingxu_sdram_control_4port #(.MJPEG_PORT(1)) phy(
        .REF_CLK(sys),.RESET_N(!rst),.CLK(clk),.DQ(dq),
        .WR1_DATA(32'd0),.WR1(1'b0),.WR1_ADDR(21'd0),.WR1_MAX_ADDR(21'd128),
        .WR1_LENGTH(9'd128),.WR1_LOAD(1'b0),.WR1_CLK(clk),
        .WR2_DATA(32'd0),.WR2(1'b0),.WR2_ADDR(21'd0),.WR2_MAX_ADDR(21'd128),
        .WR2_LENGTH(9'd128),.WR2_LOAD(1'b0),.WR2_CLK(sys),
        .RD1(1'b0),.RD1_ADDR(21'd0),.RD1_MAX_ADDR(21'd128),
        .RD1_LENGTH(9'd128),.RD1_LOAD(1'b0),.RD1_CLK(pix),
        .RD2(rd),.RD2_DATA(data),.RD2_EMPTY(empty),.RD2_ADDR(addr),
        .RD2_MAX_ADDR(maxaddr),.RD2_LENGTH(len),.RD2_LOAD(load),.RD2_CLK(pix),
        .MJ_ACTIVE(1'b0),.MJ_VALID(1'b0),.MJ_WRITE(1'b0),.MJ_ADDR(21'd0),
        .MJ_WORDS(4'd0),.MJ_WVALID(1'b0),.MJ_WDATA(32'd0),
        .MJ_WLAST(1'b0),.MJ_RREADY(1'b0));
    d3_sdram_memory memory(
        .clk(clk),.read(phy.Read),.write(phy.Write),.oe(phy.oe),.addr(phy.mADDR),
        .in_req(phy.IN_REQ),.out_valid(phy.OUT_VALID),.mask(4'd0),
        .data(phy.mDATAIN),.dq(dq));
    always @(posedge clk)begin
        load_q<=load;
        if(!rst && loaded && load && !load_q && phy.ST!=0 && phy.RD_MASK[1])
            busy_reloads=busy_reloads+1;
    end
    // Each SDRAM word contains a unique tag. Compare later frames with the
    // complete first-frame stream, independently of color postprocessing and
    // the service-level SDRAM model's burst-edge data latency.
    always @(negedge pix) if(loaded) begin
        if(x==0&&y==0)begin
            $display("FRAME %0d first_pair=%0d buffered=%0d next_addr=%0d",
                frames,p.pair,phy.read_fifo2.wp-phy.read_fifo2.rp,phy.rRD2_ADDR);
            frames=frames+1;
            if(frames==7)begin
                if(checked!=5*460800)$fatal(1,"incomplete active-pair checks");
                if(expect_stable && mismatches!=0)$fatal(1,"flush still drifts: %0d",mismatches);
                if(!expect_stable && mismatches==0)$fatal(1,"production drift not reproduced");
                if(busy_reloads==0)$fatal(1,"no reload overlapped an in-flight read");
                if(expect_stable)$display("PHOTO_PHASE: STABLE_REPLAY checked_pairs=%0d mismatches=%0d busy_reloads=%0d",
                    checked,mismatches,busy_reloads);
                else $display("PHOTO_PHASE: DRIFT_REPRODUCED checked_pairs=%0d mismatches=%0d busy_reloads=%0d",
                    checked,mismatches,busy_reloads);
                $finish;
            end
        end
        if(x<1280 && y<720 && !x[0])begin
            if(frames==1)reference[y*640+x/2]=p.pair;
            else begin
                checked=checked+1;
                if(!p.primed || p.pair!=reference[y*640+x/2])mismatches=mismatches+1;
            end
        end
        if(x==1649)begin x=0;if(y==749)y=0;else y=y+1;end
        else x=x+1;
    end
    initial begin
        expect_stable=0;rc=$value$plusargs("expect_stable=%d",expect_stable);
        for(i=0;i<460800;i=i+1)memory.memory[i]=i;
        #1000;rst=0;
        // Start the first vertical-blank reload in the middle of a real burst.
        wait(phy.OUT_VALID && phy.RD_MASK[1]);
        @(negedge pix);#1;loaded=1;
    end
    initial begin #110000000;$fatal(1,"timeout");end
endmodule
