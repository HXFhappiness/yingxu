`timescale 1ns/1ps
`default_nettype none
// Eight parallel Q16 MAC lanes; 1R/1W synchronous transposition RAM.
module yingxu_jpeg_idct(
    input wire clk,rst,start,input wire bank,
    output reg busy,done,
    output wire [7:0] coeff_addr,input wire [15:0] coeff_data,
    output wire sample_valid,output wire [5:0] sample_addr,
    output wire [7:0] sample_data
);
    reg phase,bank_r;
    reg [7:0] issued;
    reg rd_valid,mul_valid;
    reg [6:0] rd_tag;reg [5:0] mul_tag;
    reg [15:0] low_half;
    reg [15:0] temp[0:127];
    reg [15:0] temp_q;
    wire [15:0] memory_q=phase ? temp_q:coeff_data;
    wire signed [26:0] mac_input={memory_q[10:0],low_half};
    reg signed [42:0] product[0:7];
    reg signed [47:0] accum[0:7];
    reg signed [26:0] result[0:7];
    reg serial;
    reg [3:0] serial_pos;reg [2:0] serial_vector;
    wire issuing=busy && issued<128;
    wire [6:0] temp_raddr={issued[3:1],issued[6:4],issued[0]};
    assign coeff_addr={bank_r,issued[6:0]};
    function automatic signed [15:0] basis(input [5:0] index);
        begin case(index)
            6'd0: basis=16'sd23170;
            6'd1: basis=16'sd32138;
            6'd2: basis=16'sd30274;
            6'd3: basis=16'sd27246;
            6'd4: basis=16'sd23170;
            6'd5: basis=16'sd18205;
            6'd6: basis=16'sd12540;
            6'd7: basis=16'sd6393;
            6'd8: basis=16'sd23170;
            6'd9: basis=16'sd27246;
            6'd10: basis=16'sd12540;
            6'd11: basis=-16'sd6393;
            6'd12: basis=-16'sd23170;
            6'd13: basis=-16'sd32138;
            6'd14: basis=-16'sd30274;
            6'd15: basis=-16'sd18205;
            6'd16: basis=16'sd23170;
            6'd17: basis=16'sd18205;
            6'd18: basis=-16'sd12540;
            6'd19: basis=-16'sd32138;
            6'd20: basis=-16'sd23170;
            6'd21: basis=16'sd6393;
            6'd22: basis=16'sd30274;
            6'd23: basis=16'sd27246;
            6'd24: basis=16'sd23170;
            6'd25: basis=16'sd6393;
            6'd26: basis=-16'sd30274;
            6'd27: basis=-16'sd18205;
            6'd28: basis=16'sd23170;
            6'd29: basis=16'sd27246;
            6'd30: basis=-16'sd12540;
            6'd31: basis=-16'sd32138;
            6'd32: basis=16'sd23170;
            6'd33: basis=-16'sd6393;
            6'd34: basis=-16'sd30274;
            6'd35: basis=16'sd18205;
            6'd36: basis=16'sd23170;
            6'd37: basis=-16'sd27246;
            6'd38: basis=-16'sd12540;
            6'd39: basis=16'sd32138;
            6'd40: basis=16'sd23170;
            6'd41: basis=-16'sd18205;
            6'd42: basis=-16'sd12540;
            6'd43: basis=16'sd32138;
            6'd44: basis=-16'sd23170;
            6'd45: basis=-16'sd6393;
            6'd46: basis=16'sd30274;
            6'd47: basis=-16'sd27246;
            6'd48: basis=16'sd23170;
            6'd49: basis=-16'sd27246;
            6'd50: basis=16'sd12540;
            6'd51: basis=16'sd6393;
            6'd52: basis=-16'sd23170;
            6'd53: basis=16'sd32138;
            6'd54: basis=-16'sd30274;
            6'd55: basis=16'sd18205;
            6'd56: basis=16'sd23170;
            6'd57: basis=-16'sd32138;
            6'd58: basis=16'sd30274;
            6'd59: basis=-16'sd27246;
            6'd60: basis=16'sd23170;
            6'd61: basis=-16'sd18205;
            6'd62: basis=16'sd12540;
            6'd63: basis=-16'sd6393;
            default: basis=0;
        endcase end
    endfunction
    function automatic [7:0] clip_sample(input signed [26:0] value);
        reg signed [27:0] shifted;
        begin shifted=value+28'sd128;
            if(shifted<0) clip_sample=0;
            else if(shifted>255) clip_sample=255;
            else clip_sample=shifted[7:0];
        end
    endfunction
    assign sample_valid=busy && phase && serial && !serial_pos[0];
    assign sample_addr={serial_pos[3:1],serial_vector};
    assign sample_data=clip_sample(result[serial_pos[3:1]]);
    // Both memory read ports are registered. No array-wide reset.
    always @(posedge clk) begin
        temp_q<=temp[temp_raddr];
        if(busy && !phase && serial)
            temp[{serial_vector,serial_pos}]<=serial_pos[0] ?
                {{5{result[serial_pos[3:1]][26]}},result[serial_pos[3:1]][26:16]} : result[serial_pos[3:1]][15:0];
    end
    integer lane;
    reg signed [47:0] total;
    always @(posedge clk) begin
        if(rst) begin
            busy<=0;done<=0;phase<=0;bank_r<=0;issued<=0;
            rd_valid<=0;mul_valid<=0;serial<=0;serial_pos<=0;
            serial_vector<=0;rd_tag<=0;mul_tag<=0;low_half<=0;
        end else begin
            done<=0;
            if(start && !busy) begin
                busy<=1;phase<=0;bank_r<=bank;issued<=0;
                rd_valid<=0;mul_valid<=0;serial<=0;
            end else if(busy) begin
                rd_valid<=issuing; rd_tag<=issued[6:0];
                if(issuing) issued<=issued+1'b1;
                mul_valid<=rd_valid && rd_tag[0]; mul_tag<=rd_tag[6:1];
                if(rd_valid && !rd_tag[0]) low_half<=memory_q;
                for(lane=0;lane<8;lane=lane+1)
                    if(rd_valid && rd_tag[0]) product[lane]<=mac_input*basis({lane[2:0],rd_tag[3:1]});
                if(serial) begin
                    serial_pos<=serial_pos+1'b1;
                    if(serial_pos==15) begin
                        serial<=0;
                        if(serial_vector==7) begin
                            rd_valid<=0;mul_valid<=0;issued<=0;
                            if(!phase) phase<=1;
                            else begin busy<=0;done<=1;end
                        end
                    end
                end
                if(mul_valid) begin
                    for(lane=0;lane<8;lane=lane+1) begin
                        total=(mul_tag[2:0]==0 ? 48'sd0 : accum[lane])+$signed(product[lane]);
                        accum[lane]<=total;
                        if(mul_tag[2:0]==7) result[lane]<=(total+48'sd32768)>>>16;
                    end
                    if(mul_tag[2:0]==7) begin
                        serial<=1;serial_pos<=0;serial_vector<=mul_tag[5:3];
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
