`timescale 1ns/1fs
// Test-only media/PLL/HDMI models. All board scheduling and decoding are RTL.
// SD service is limited to 1.30 MB/s INCLUDING the real two-cycle drain.
module sd_card_control #(
    parameter                           clock_freq                = 100_000_000,
               spi_lowfreq = 400_000,
               spi_highfreq = 25_000_000,
               spi_low_div = clock_freq / (spi_lowfreq * 2),
               spi_high_div = clock_freq / (spi_highfreq * 2),
               spi_div_width = spi_low_div > 0 ? $clog2(spi_low_div) : 1
    )(
    output                              mosi                       ,
    output                              sclk                       ,
    output reg                          cs_n                       ,
    output                              idle                       ,
    output reg                          done                       ,
    output             [   7: 0]        rd_ram_dout                ,
    input              [   8: 0]        rd_ram_addr                ,
    input              [   7: 0]        wr_ram_din                 ,
    input              [   8: 0]        wr_ram_addr                ,
    input                               wr_ram_wea                 ,
    input              [  27: 0]        sector_addr                ,
    input                               miso                       ,
    input                               start                      ,
    input              [   1: 0]        mode                       ,
    input                               clk                        ,
    input                               rst                        ,
    // Debug-only observability ports for ChipWatcher.
    output wire                         dbg_spi_clk                ,
    output wire        [spi_div_width-1:0] dbg_spi_div_value        ,
    output wire        [spi_div_width-1:0] dbg_spi_div_counter      ,
    output wire        [   2: 0]        dbg_ctrl_state             ,
    output wire        [   1: 0]        dbg_select_num             ,
    output wire                         dbg_spi_start              ,
    output wire                         dbg_spi_next               ,
    output wire                         dbg_spi_done               ,
    output wire        [   3: 0]        dbg_init_state             ,
    output wire        [  39: 0]        dbg_init_response          ,
    output wire                         dbg_spi_driver_state       ,
    output wire        [   3: 0]        dbg_spi_driver_count       ,
    output wire        [   2: 0]        dbg_read_state             ,
    output wire        [   7: 0]        dbg_read_spi_rec_data      ,
    output wire                         dbg_read_addr_done         ,
    output wire                         dbg_read_data_done          
    );

    reg [7:0] file_bytes[0:2999999];
    integer state=0,delay_count=0,byte_index=0,phase=0,file_size,fd,narg,bad=0;
    integer transfer_bytes=0,noinit=0;reg [27:0] lba=0;
    reg ram_we=0;reg [8:0] ram_addr=0;reg [7:0] ram_data=0;
    reg [1023:0] filename;
    initial begin
        if(!$value$plusargs("file=%s",filename)) $fatal(1,"SD model file required");
        narg=$value$plusargs("bad=%d",bad);
        narg=$value$plusargs("noinit=%d",noinit);
        fd=$fopen(filename,"rb");if(!fd)$fatal(1,"SD model open");
        file_size=$fread(file_bytes,fd);$fclose(fd);
        if(bad)file_bytes[0]=0;
    end
    ram_dual_port_simple #(.data_width(8),.data_num(512)) RD_RAM(
        .douta(),.doutb(rd_ram_dout),.dina(ram_data),.addra(ram_addr),.addrb(rd_ram_addr),.wea(ram_we),.clka(clk),.clkb(clk));
    assign idle=state==0;assign mosi=1;assign sclk=0;
    assign dbg_spi_clk=0;
    assign dbg_spi_div_value=0;
    assign dbg_spi_div_counter=0;
    assign dbg_ctrl_state=0;
    assign dbg_select_num=0;
    assign dbg_spi_start=0;
    assign dbg_spi_next=0;
    assign dbg_spi_done=0;
    assign dbg_init_state=0;
    assign dbg_init_response=0;
    assign dbg_spi_driver_state=0;
    assign dbg_spi_driver_count=0;
    assign dbg_read_state=0;
    assign dbg_read_spi_rec_data=0;
    assign dbg_read_addr_done=0;
    assign dbg_read_data_done=0;

    always @(posedge clk) begin
        if(rst)begin state<=0;done<=0;cs_n<=1;delay_count<=0;byte_index<=0;phase<=0;ram_we<=0;end
        else begin
            done<=0;ram_we<=0;
            case(state)
                0: if(start)begin lba<=sector_addr;cs_n<=0;
                    delay_count<=(mode==0)?10:2300;state<=(mode==0)?(noinit?4:3):1;end
                1: if(delay_count!=0)delay_count<=delay_count-1;
                    else begin state<=2;byte_index<=0;phase<=0;end
                2: begin
                    phase<=phase+1;
                    if(phase==31)begin
                        phase<=0;ram_addr<=byte_index;ram_we<=1;
                        if(lba>=3000000 && (lba-3000000)*512+byte_index<file_size)
                            ram_data<=file_bytes[(lba-3000000)*512+byte_index];
                        else ram_data<=0;
                        transfer_bytes<=transfer_bytes+1;
                        if(byte_index==511)begin state<=3;delay_count<=4;end
                        else byte_index<=byte_index+1;
                    end
                end
                3: if(delay_count!=0)delay_count<=delay_count-1;
                    else begin state<=0;done<=1;cs_n<=1;end
            endcase
        end
    end
endmodule

module pll_hdmi1_4b(input refclk,reset,output reg extlock=0,output clk1_out,clk2_out);
    reg c=0;always #6.818181818 c=~c;
    assign clk1_out=c;assign clk2_out=c;
    initial begin #1000;extlock=1;end
endmodule

module hdmi_phy_wrapper #(parameter DEVICE="EG")(
    input I_pixel_clk,I_serial_clk,I_rst,
    input [9:0] I_tmds_channel_0,I_tmds_channel_1,I_tmds_channel_2,I_tmds_channel_clk,
    output O_tmds_ch0_p,O_tmds_ch1_p,O_tmds_ch2_p,O_tmds_clk_p);
    assign {O_tmds_ch0_p,O_tmds_ch1_p,O_tmds_ch2_p,O_tmds_clk_p}=0;
endmodule
module hdmi_1_4b_transmitter_core_wrapper #(
    parameter DEVICE="EG",HTOTAL=1650,HSA=40,HFP=110,HBP=220,HACTIVE=1280,
    VTOTAL=750,VSA=5,VFP=5,VBP=20,VACTIVE=720,VIDEO_VIC=69,
    VIDEO_TPG="Disable",VIDEO_FORMAT="RGB",AUDIO_SAMPLE_RATE="48K",IIC_SCL_DIV=125)(
    input I_pixel_clk,I_rst,I_edid_read_trig,
    output O_edid_read_valid,output [7:0] O_edid_read_data,
    input I_axis_s_user,I_axis_s_valid,I_axis_s_last,input [23:0] I_axis_s_data,output O_axis_s_ready,
    input I_audio_valid,input [23:0] I_audio_left_data,I_audio_right_data,
    input I_acr_valid,input [19:0] I_acr_cts,I_acr_n,
    output O_video_locked,O_ddc_scl,inout IO_ddc_sda,
    output [9:0] O_ch0_tmds_data,O_ch1_tmds_data,O_ch2_tmds_data,O_clk_tmds_data);
    assign O_axis_s_ready=1;assign O_video_locked=1;assign O_edid_read_valid=0;
    assign O_edid_read_data=0;assign O_ddc_scl=1;assign IO_ddc_sda=1'bz;
    assign {O_ch0_tmds_data,O_ch1_tmds_data,O_ch2_tmds_data,O_clk_tmds_data}=0;
endmodule
module EG_PHY_SDRAM_2M_32(input clk,ras_n,cas_n,we_n,input [10:0] addr,input [1:0] ba,
    inout [31:0] dq,input cs_n,dm0,dm1,dm2,dm3,cke);
    // The service-level memory below drives DQ; no pin-level timing is claimed.
endmodule
