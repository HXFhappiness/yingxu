module init_once_formal(input clk,rst,start,ctrl_done,stream_ready,input [27:0] lba,input [15:0] sectors,input [7:0] data,output safe);
wire init_done,ctrl_start;wire [1:0] ctrl_mode;
reg seen;
always @(posedge clk)if(rst)seen<=0;else if(init_done)seen<=1;
sd_stream_reader_core dut(.clk(clk),.rst(rst),.start(start),.start_sector(lba),.sector_count(sectors),.ctrl_done(ctrl_done),.ctrl_rd_ram_data(data),.stream_ready(stream_ready),.init_done(init_done),.ctrl_start(ctrl_start),.ctrl_mode(ctrl_mode));
assign safe=!seen || (init_done && !(ctrl_start && ctrl_mode==0));
endmodule
