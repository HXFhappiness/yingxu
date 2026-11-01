`timescale 1ns/1ps
`default_nettype none
// Board-integrated scheduler: one physical RAM, one SD controller, one WAV chain.
module yingxu_yxv_pipeline #(
    parameter integer STALL_LIMIT=500_000_000,
    parameter integer ACQUIRE_LIMIT=250_000_000
)(
    input wire sys_clk,clk,pix_clk,rst,enable,mem_ready,
    input wire sd_init,sd_busy,sd_done,input wire [7:0] sd_data,input wire sd_data_valid,
    output wire sd_data_ready,output reg sd_start,output reg [27:0] sd_lba,output reg [15:0] sd_sectors,
    output wire sd_reset,
    output reg owned,failed,output reg [7:0] error_code,
    output reg [15:0] diagnosis,detail,output reg [10:0] fail_count,
    output wire [9:0] fail_index,output wire [31:0] fail_word,
    output wire audio_enable,output wire [7:0] audio_data,output wire audio_valid,input wire audio_ready,
    input wire audio_pop,input wire [10:0] x,input wire [9:0] y,input wire pixel_active,
    input wire [31:0] rd2_data,input wire rd2_empty,
    output wire rd2_en,rd2_load,output wire [20:0] rd2_addr,rd2_max,output wire [8:0] rd2_len,output wire [23:0] rgb,
    output wire cmd_valid,input wire cmd_ready,output wire cmd_write,output wire [20:0] cmd_addr,output wire [3:0] cmd_words,
    output wire wvalid,input wire wready,output wire [31:0] wdata,output wire wlast,
    input wire rvalid,output wire rready,input wire [31:0] rdata,input wire rlast,input wire mem_done,mem_error,
    input wire port_idle,
    output wire [31:0] decoded_frames,displayed_frames,dropped_frames,played_samples,
    output wire [15:0] sd_occupancy,output wire [23:0] status
);
    reg [1:0] request_sync;
    wire local_rst=rst || !owned || !mem_ready;
    reg fault;reg [7:0] fault_code;reg [28:0] stall;reg last_sample;
    reg audio_run;wire [31:0] sample_count;
    wire [7:0] lp,lf,lr;wire [10:0] lc;
    reg diag_frozen;reg [7:0] frozen_phase,frozen_reason,frozen_flags;
    reg [10:0] frozen_count;
    // D4g removes all data snapshots, including MEM and SYS copies.
    assign fail_index=10'd0;assign fail_word=32'd0;
    // Capture before abort changes loader state. Held until common release;
    // fault_sys gives multiple clocks of stability before the SYS snapshot.
    always @(posedge clk)begin
        if(local_rst)begin diag_frozen<=0;frozen_phase<=0;frozen_reason<=0;frozen_flags<=0;frozen_count<=0;end
        else if(fault && !diag_frozen)begin
            diag_frozen<=1;
            frozen_phase<=fault_code==8'h95 ? 8'h0E:fault_code==8'h9E ? 8'h1E:
                (fault_code==8'h91 || fault_code==8'h92 || fault_code==8'h93 || fault_code==8'h9F) ? lp:8'h16;
            frozen_reason<=lr;frozen_flags<=lf;frozen_count<=lc;
        end
    end
    wire loader_idle,loader_ready,loader_failed,pcm_failed,pcm_idle;
    wire [7:0] loader_code;wire [9:0] frames;wire [31:0] pcm_bytes;
    wire [1:0] slots;reg [1:0] slot_release;
    wire [15:0] slot_tag0,slot_tag1;wire [15:0] slot_len0,slot_len1;
    wire [31:0] sd_accepted,sd_ticks;
    wire sdv,sdr,sdd;wire [27:0] sdlba;wire [15:0] sdn;
    wire byte_valid,byte_ready;wire [7:0] byte_data;
    wire [6:0] byte_level;
    wire source_ready;wire [43:0] source_payload;wire source_valid,dest_done;
    wire [0:0] source_status;
    reg [1:0] abort_sys;reg sd_inflight;
    // Source ownership persists across mode exits until every accepted transfer ends.
    wire quiet;reg [1:0] quiet_sys,fault_sys;
    reg [1:0] audio_sys;reg [27:0] acquire_wait;
    always @(posedge sys_clk) begin
        if(rst) begin owned<=0;failed<=0;error_code<=0;diagnosis<=0;detail<=0;fail_count<=0;quiet_sys<=0;fault_sys<=0;audio_sys<=0;abort_sys<=0;acquire_wait<=0;end
        else begin
            quiet_sys<={quiet_sys[0],quiet};fault_sys<={fault_sys[0],fault};
            audio_sys<={audio_sys[0],audio_run};abort_sys<={abort_sys[0],fault};
            if(!owned && !enable) begin failed<=0;error_code<=0;diagnosis<=0;detail<=0;fail_count<=0;end
            if(owned || !enable || failed)acquire_wait<=0;
            else if(sd_init && !sd_busy) begin owned<=1;acquire_wait<=0;end
            else if(acquire_wait==ACQUIRE_LIMIT-1)begin failed<=1;error_code<=8'h9F;diagnosis<=16'h069F;detail<=0;fail_count<=0;end
            else acquire_wait<=acquire_wait+1'b1;
            // D4e: an in-flight memory command may prevent quiet/release.
            // The first MEM snapshot is already stable before fault_sys[1].
            // Publish it independently of teardown; do not change abort/reset.
            if(owned && fault_sys[1] && diagnosis==16'd0) begin
                error_code<=fault_code;diagnosis<={frozen_phase,fault_code};
                detail<={frozen_reason,frozen_flags};fail_count<=frozen_count;
            end
            if(owned && (!enable || fault_sys[1]) && quiet_sys[1] && !sd_inflight) begin
                owned<=0;
                if(fault_sys[1]) begin failed<=1;error_code<=fault_code;
                    diagnosis<={frozen_phase,fault_code};detail<={frozen_reason,frozen_flags};
                    fail_count<=frozen_count;end
            end
        end
    end
    assign sd_reset=owned && abort_sys[1];
    assign audio_enable=owned && audio_sys[1] && !fault_sys[1];
    assign sd_occupancy={sd_busy,8'd0,byte_level};
    yingxu_mjpeg_mailbox #(.WIDTH(44),.STATUS(1)) sd_commands(
        .sclk(clk),.dclk(sys_clk),.rst(local_rst),.svalid(sdv),.sready(sdr),.spayload({sdlba,sdn}),.sdone(sdd),.sstatus(source_status),
        .dvalid(source_valid),.dready(source_ready),.dpayload(source_payload),.ddone(dest_done),.dstatus(1'b0));
    assign source_ready=owned && (abort_sys[1] || (sd_init && !sd_busy && !sd_inflight));
    assign dest_done=sd_done || sd_reset;
    always @(posedge sys_clk) begin
        if(local_rst) begin sd_start<=0;sd_lba<=0;sd_sectors<=0;sd_inflight<=0;end
        else begin
            sd_start<=0;
            if(source_valid && source_ready) begin sd_lba<=source_payload[43:16];sd_sectors<=source_payload[15:0];sd_start<=!abort_sys[1];sd_inflight<=!abort_sys[1];end
            if(dest_done) sd_inflight<=0;
        end
    end
    yingxu_media_async_fifo #(.WIDTH(8),.ABITS(6)) sd_bytes(
        .wclk(sys_clk),.rclk(clk),.rst(local_rst),.wvalid(sd_data_valid && owned),.wready(sd_data_ready),.wdata(sd_data),
        .rvalid(byte_valid),.rready(byte_ready),.rdata(byte_data),.wlevel(byte_level));
    wire dv,dready,dwrite,dwv,dwr,dwl,drv,drr,drl,ddone,derror;
    wire [20:0] daddr;wire [3:0] dwords;wire [31:0] dwd,drd;
    wire lv,lready,lwrite,lwv,lwr,lwl,lrv,lrr,lrl,ldone,lerror;
    wire [20:0] laddr;wire [3:0] lwords;wire [31:0] lwd,lrd;
    wire pv,pready,pwrite,pwv,pwr,pwl,prv,prr,prl,pdone,perror;
    wire [20:0] paddr;wire [3:0] pwords;wire [31:0] pwd,prd;
    wire ov,oready,owrite,owv,owr,owl,orv,orr,orl,odone,oerror;
    wire [20:0] oaddr;wire [3:0] owords;wire [31:0] owd,ord;

    yingxu_yxv_loader loader(.clk(clk),.rst(local_rst),.enable(request_sync[1] && !fault),.abort(fault),
        .sd_valid(sdv),.sd_ready(sdr),.sd_lba(sdlba),.sd_sectors(sdn),.sd_done(sdd),
        .sd_byte(byte_data),.sd_byte_valid(byte_valid),.sd_byte_ready(byte_ready),
        .debug_phase(lp),.debug_flags(lf),.debug_reason(lr),.debug_word(),.debug_index(),.debug_count(lc),
        .idle(loader_idle),.ready(loader_ready),.failed(loader_failed),.error_code(loader_code),.frames(frames),.pcm_bytes(pcm_bytes),
        .slot_valid(slots),.slot_release(slot_release),.slot_tag0(slot_tag0),.slot_tag1(slot_tag1),.slot_len0(slot_len0),.slot_len1(slot_len1),
        .sd_accepted(sd_accepted),.sd_ticks(sd_ticks),
        .cmd_valid(lv),.cmd_ready(lready),.cmd_write(lwrite),.cmd_addr(laddr),.cmd_words(lwords),
        .wvalid(lwv),.wready(lwr),.wdata(lwd),.wlast(lwl),.mem_done(ldone),.mem_error(lerror));
    assign lrr=1;
    yingxu_yxv_pcm_feed pcm(.clk(clk),.sys_clk(sys_clk),.rst(local_rst),.enable(audio_run && request_sync[1] && !fault),.pcm_bytes(pcm_bytes),
        .cmd_valid(pv),.cmd_ready(pready),.cmd_write(pwrite),.cmd_addr(paddr),.cmd_words(pwords),
        .rvalid(prv),.rready(prr),.rdata(prd),.rlast(prl),.mem_done(pdone),.mem_error(perror),.failed(pcm_failed),.idle(pcm_idle),
        .wav_data(audio_data),.wav_valid(audio_valid),.wav_ready(audio_ready));
    assign pwv=0;assign pwd=0;assign pwl=0;
    reg [1:0] rgb_ready;reg [15:0] tag_bank0,tag_bank1;
    reg front_valid,front_bank,decode_bank,decode_slot;
    reg [15:0] next_decode,decode_tag,completed,present_number,drops;reg [21:0] present_pts;
    wire decode_busy,decode_done,decode_error;wire [7:0] decode_code;wire [31:0] decode_cycles;wire [17:0] committed;
    wire free0=!rgb_ready[0] && !(front_valid && !front_bank);
    wire free1=!rgb_ready[1] && !(front_valid && front_bank);
    wire choose_bank=!free0;
    wire choose_slot=!(slots[0] && slot_tag0==next_decode);
    wire slot_available=(slots[0] && slot_tag0==next_decode)||(slots[1] && slot_tag1==next_decode);
    wire frame_valid=!decode_busy && request_sync[1] && !fault && slot_available && (free0||free1) && !decode_done;
    wire frame_ready;
    yingxu_mjpeg_decoder decoder(.clk(clk),.rst(local_rst),.frame_valid(frame_valid),.frame_ready(frame_ready),
        .src_addr(choose_slot ? 21'h084000:21'h080000),.dst_addr(choose_bank ? 21'h040000:21'h000000),
        .jpeg_bytes(choose_slot ? slot_len1:slot_len0),.busy(decode_busy),.done(decode_done),.error(decode_error),.error_code(decode_code),
        .frame_cycles(decode_cycles),.committed_words(committed),
        .cmd_valid(dv),.cmd_ready(dready),.cmd_write(dwrite),.cmd_addr(daddr),.cmd_words(dwords),
        .wvalid(dwv),.wready(dwr),.wdata(dwd),.wlast(dwl),.rvalid(drv),.rready(drr),.rdata(drd),.rlast(drl),.mem_done(ddone),.mem_error(derror));
    wire signed [21:0] av_distance=$signed(sample_count[21:0]-present_pts);
    wire exchange_valid,exchange_ready,exchange_done;reg exchange_pending,exchange_bank;
    wire choose_present=!(rgb_ready[0] && tag_bank0==present_number);
    wire present_available=(rgb_ready[0] && tag_bank0==present_number)||(rgb_ready[1] && tag_bank1==present_number);
    assign exchange_valid=request_sync[1] && !fault && present_available && !exchange_pending &&
        (!front_valid || (av_distance >= -22'sd960));
    wire pxvalid,pxready,pxdone;wire [16:0] pxpayload;wire [0:0] exchange_status;
    yingxu_mjpeg_mailbox #(.WIDTH(17),.STATUS(1)) present_mailbox(
        .sclk(clk),.dclk(pix_clk),.rst(local_rst),.svalid(exchange_valid),.sready(exchange_ready),.spayload({present_number,choose_present}),
        .sdone(exchange_done),.sstatus(exchange_status),.dvalid(pxvalid),.dready(pxready),.dpayload(pxpayload),.ddone(pxdone),.dstatus(1'b0));
    wire [31:0] pixel_tag;wire pixel_tag_valid,scan_underflow;
    yingxu_yxv_scanout scanout(.clk(pix_clk),.rst(local_rst),.x(x),.y(y),.active(pixel_active),
        .frame_valid(pxvalid),.frame_ready(pxready),.frame_bank(pxpayload[0]),.frame_tag({16'd0,pxpayload[16:1]}),.frame_done(pxdone),
        .displayed_tag(pixel_tag),.displayed_valid(pixel_tag_valid),.rd_data(rd2_data),.rd_empty(rd2_empty),
        .rd_en(rd2_en),.rd_load(rd2_load),.rd_addr(rd2_addr),.rd_max(rd2_max),.rd_len(rd2_len),.rgb(rgb),.underflow(scan_underflow));
    reg [31:0] played,played_gray;reg [1:0] audio_pix;
    always @(posedge pix_clk) begin
        if(local_rst) begin played<=0;played_gray<=0;audio_pix<=0;end
        else begin
            audio_pix<={audio_pix[0],audio_run};played_gray<=(played>>1)^played;
            if(audio_pop && audio_pix[1]) played<=played+1'b1;
        end
    end
    (* async_reg="true" *) reg [31:0] sample_meta,sample_sync;
    function [31:0] fromgray(input [31:0] gray);
        integer k;begin fromgray[31]=gray[31];for(k=30;k>=0;k=k-1)fromgray[k]=fromgray[k+1]^gray[k];end
    endfunction
    assign sample_count=fromgray(sample_sync);
    always @(posedge clk) begin
        if(local_rst) begin
            request_sync<=0;sample_meta<=0;sample_sync<=0;fault<=0;fault_code<=0;stall<=0;last_sample<=0;audio_run<=0;
            rgb_ready<=0;front_valid<=0;front_bank<=0;decode_bank<=0;decode_slot<=0;next_decode<=0;decode_tag<=0;
            completed<=0;present_number<=0;present_pts<=0;drops<=0;slot_release<=0;tag_bank0<=0;tag_bank1<=0;
            exchange_pending<=0;exchange_bank<=0;
        end else begin
            request_sync<={request_sync[0],enable};sample_meta<=played_gray;sample_sync<=sample_meta;slot_release<=0;
            last_sample<=sample_sync[0];
            if(byte_valid && byte_ready || decode_done || sample_sync[0]!=last_sample) stall<=0;
            else if(stall<STALL_LIMIT) stall<=stall+1'b1;
            if(!fault && stall==STALL_LIMIT-1) begin fault<=1;fault_code<=8'h9F;end
            if(loader_failed && !fault) begin fault<=1;fault_code<=loader_code;end
            if(pcm_failed && !fault) begin fault<=1;fault_code<=8'h95;end
            if(decode_done && decode_error && !fault) begin fault<=1;fault_code<=decode_code;drops<=drops+1'b1;end
            if(frame_valid && frame_ready) begin decode_bank<=choose_bank;decode_slot<=choose_slot;decode_tag<=next_decode;next_decode<=next_decode+1'b1;end
            if(decode_done) begin
                slot_release[decode_slot]<=1;
                if(!decode_error) begin
                    completed<=completed+1'b1;rgb_ready[decode_bank]<=1;
                    if(decode_bank)tag_bank1<=decode_tag;else tag_bank0<=decode_tag;
                end
            end
            if(exchange_valid && exchange_ready) begin exchange_pending<=1;exchange_bank<=choose_present;end
            if(exchange_done) begin
                front_valid<=1;front_bank<=exchange_bank;rgb_ready[exchange_bank]<=0;exchange_pending<=0;
                present_number<=present_number+1'b1;present_pts<=present_pts+2000;
            end
            if(audio_run && av_distance>22'sd2000 && !exchange_pending && !fault) begin
                fault<=1;fault_code<=8'h9E;drops<=drops+1'b1;
            end
            if(completed>=2 && front_valid && !fault) audio_run<=1;
            if(!request_sync[1] || fault) audio_run<=0;
        end
    end
    wire source_ready_mem=sdr;
    assign quiet=loader_idle && !decode_busy && pcm_idle && !exchange_pending && source_ready_mem &&
        !cmd_valid && port_idle && !lv && !pv && !dv;
    // Others: audio reads > SD staging writes > compressed reads. Physical RD2
    // display is higher priority inside the four-port controller.
    wire [2:0] ir,iwready,irvalid,idone,ierror;
    wire [31:0] inner_rdata;wire inner_rlast;
    yingxu_mjpeg_arbiter other_arb(.clk(clk),.rst(local_rst),
        .cvalid({dv&&!dwrite,lv,pv}),.cready(ir),.cwrite(3'b010),.caddr({daddr,laddr,paddr}),.cwords({dwords,lwords,pwords}),
        .cwvalid({1'b0,lwv,1'b0}),.cwready(iwready),.cwdata({32'd0,lwd,32'd0}),.cwlast({1'b0,lwl,1'b0}),
        .crvalid(irvalid),.crready({drr,1'b1,prr}),.crdata(inner_rdata),.crlast(inner_rlast),.cdone(idone),.cerror(ierror),
        .mvalid(ov),.mready(oready),.mwrite(owrite),.maddr(oaddr),.mwords(owords),
        .mwvalid(owv),.mwready(owr),.mwdata(owd),.mwlast(owl),.mrvalid(orv),.mrready(orr),.mrdata(ord),.mrlast(orl),.mdone(odone),.merror(oerror));
    assign pready=ir[0];assign lready=ir[1];assign lwr=iwready[1];
    assign prv=irvalid[0];assign prd=inner_rdata;assign prl=inner_rlast;assign pdone=idone[0];assign perror=ierror[0];
    assign ldone=idone[1];assign lerror=ierror[1];
    wire [2:0] er,ewready,ervalid,edone,eerror;wire [31:0] external_rdata;wire external_rlast;
    yingxu_mjpeg_arbiter write_arb(.clk(clk),.rst(local_rst),
        .cvalid({ov,dv&&dwrite,1'b0}),.cready(er),.cwrite({owrite,1'b1,1'b0}),.caddr({oaddr,daddr,21'd0}),.cwords({owords,dwords,4'd0}),
        .cwvalid({owv,dwv,1'b0}),.cwready(ewready),.cwdata({owd,dwd,32'd0}),.cwlast({owl,dwl,1'b0}),
        .crvalid(ervalid),.crready({orr,1'b1,1'b0}),.crdata(external_rdata),.crlast(external_rlast),.cdone(edone),.cerror(eerror),
        .mvalid(cmd_valid),.mready(cmd_ready),.mwrite(cmd_write),.maddr(cmd_addr),.mwords(cmd_words),
        .mwvalid(wvalid),.mwready(wready),.mwdata(wdata),.mwlast(wlast),.mrvalid(rvalid),.mrready(rready),.mrdata(rdata),.mrlast(rlast),.mdone(mem_done),.merror(mem_error));
    assign oready=er[2];assign owr=ewready[2];assign orv=ervalid[2];assign ord=external_rdata;assign orl=external_rlast;
    assign odone=edone[2];assign oerror=eerror[2];assign dready=dwrite ? er[1]:ir[2];assign dwr=ewready[1];
    assign drv=irvalid[2];assign drd=inner_rdata;assign drl=inner_rlast;assign ddone=edone[1]||idone[2];assign derror=eerror[1]||ierror[2];
    // SYS telemetry snapshots: all counters cross as Gray, not incoherent binary.
    reg [15:0] cg,dg,pg,cm,cs,dm,ds,pm,ps;reg [31:0] am,audio_sample_sync;
    always @(posedge clk)begin cg<=completed^(completed>>1);dg<=drops^(drops>>1);pg<=present_number^(present_number>>1);end
    always @(posedge sys_clk) begin
        if(local_rst)begin cm<=0;cs<=0;dm<=0;ds<=0;pm<=0;ps<=0;am<=0;audio_sample_sync<=0;end
        else begin cm<=cg;cs<=cm;dm<=dg;ds<=dm;pm<=pg;ps<=pm;am<=played_gray;audio_sample_sync<=am;end
    end
    assign decoded_frames=fromgray(cs);assign dropped_frames=fromgray(ds);assign displayed_frames=fromgray(ps);assign played_samples=fromgray(audio_sample_sync);
    assign status={owned,audio_enable,failed,loader_ready,decode_busy,enable,frames[9:8],(failed ? error_code:fault_code),frames[7:0]};
endmodule
`default_nettype wire
