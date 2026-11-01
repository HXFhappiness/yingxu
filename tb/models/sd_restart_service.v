`timescale 1ns/1ps
// Transaction model only; no SPI/card electrical behavior.
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


    integer init_commands=0,read_commands=0,delay_count=0;
    reg active=0;reg [27:0] latched_sector=0;reg [7:0] q=0;
    assign rd_ram_dout=q;assign idle=!active;assign mosi=1;assign sclk=0;
    assign dbg_spi_clk=0;assign dbg_spi_div_value=0;assign dbg_spi_div_counter=0;
    assign dbg_ctrl_state=0;assign dbg_select_num=0;assign dbg_spi_start=0;assign dbg_spi_next=0;assign dbg_spi_done=0;
    assign dbg_init_state=0;assign dbg_init_response=0;assign dbg_spi_driver_state=0;assign dbg_spi_driver_count=0;
    assign dbg_read_state=0;assign dbg_read_spi_rec_data=0;assign dbg_read_addr_done=0;assign dbg_read_data_done=0;
    always @(posedge clk)begin
        q<=latched_sector[7:0]^rd_ram_addr[7:0]^{7'd0,rd_ram_addr[8]};
        if(rst)begin done<=0;active<=0;delay_count<=0;cs_n<=1;init_commands<=0;read_commands<=0;end
        else begin
            done<=0;
            if(start)begin
                if(active)$fatal(1,"controller command while active");
                if(mode==0)begin if(init_commands!=0)$fatal(1,"unexpected repeated initialization");init_commands<=init_commands+1;end
                else if(mode==2)read_commands<=read_commands+1;
                else $fatal(1,"unexpected mode");
                latched_sector<=sector_addr;active<=1;delay_count<=4;cs_n<=0;
            end
            if(active)begin
                delay_count<=delay_count-1;
                if(delay_count==1)begin active<=0;done<=1;cs_n<=1;end
            end
        end
    end
endmodule
