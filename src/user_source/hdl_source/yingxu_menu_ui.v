`timescale 1ns/1ps
`default_nettype none
// D7: coordinate-locked background and glyphs; no SD/SDRAM inputs or state.
// Combinational output has the same coordinate phase as sprite bg_rgb.
// Selection is drawn separately by the existing slot-15 sprite.
module yingxu_menu_ui(
    input wire clk,rst,
    input wire [10:0] pixel_x,pixel_y,
    input wire pixel_active,menu_visible,page,
    input wire [2:0] sel,
    output wire [23:0] menu_rgb
);
    wire panel = pixel_x>=11'd820 && pixel_x<=11'd1190 &&
                 pixel_y>=11'd240 && pixel_y<=11'd700;
    wire interior = pixel_x>=11'd826 && pixel_x<=11'd1184 &&
                    pixel_y>=11'd246 && pixel_y<=11'd694;
    wire [23:0] background = panel ? (interior ? 24'hC8B45A : 24'h000000) : 24'h0A1030;
    reg text_row;
    reg [2:0] line_idx;
    reg [4:0] glyph_row;
    always @* begin
        text_row=1'b1;line_idx=3'd0;glyph_row=5'd0;
        if(pixel_y>=280 && pixel_y<312)begin line_idx=0;glyph_row=pixel_y-280;end
        else if(pixel_y>=367 && pixel_y<399)begin line_idx=1;glyph_row=pixel_y-367;end
        else if(!page && pixel_y>=454 && pixel_y<486)begin line_idx=2;glyph_row=pixel_y-454;end
        else if(!page && pixel_y>=541 && pixel_y<573)begin line_idx=3;glyph_row=pixel_y-541;end
        else if(!page && pixel_y>=628 && pixel_y<660)begin line_idx=4;glyph_row=pixel_y-628;end
        else text_row=1'b0;
    end
    wire [10:0] dx=pixel_x-11'd950;
    wire [1:0] column=dx[6:5];
    reg [4:0] char_idx;
    reg char_valid;
    always @* begin
        char_idx=5'd31;char_valid=1'b0;
        if(text_row && pixel_x>=950 && dx<128)begin
            if(!page && dx<64)begin
                char_valid=1'b1;
                case(line_idx)
                    0:char_idx=column[0] ? 5'd1:5'd0; // 图片
                    1:char_idx=column[0] ? 5'd3:5'd2; // 游戏
                    2:char_idx=column[0] ? 5'd5:5'd4; // 视频
                    3:char_idx=column[0] ? 5'd7:5'd6; // 音乐
                    default:char_idx=column[0] ? 5'd9:5'd8; // 关于
                endcase
            end else if(page)begin
                if(line_idx==0 && dx<96)begin
                    char_valid=1'b1;
                    case(column)
                        0:char_idx=10;1:char_idx=11;default:char_idx=12;
                    endcase
                end else if(line_idx==1)begin
                    char_valid=1'b1;
                    case(column)
                        0:char_idx=13;1:char_idx=14;2:char_idx=15;default:char_idx=16;
                    endcase
                end
            end
        end
    end
    wire [31:0] bits;
    yingxu_cn_font font(.char_idx(char_idx),.row(glyph_row),.bits(bits));
    wire ink=char_valid && bits[5'd31-dx[4:0]];
    assign menu_rgb = (!rst && menu_visible && pixel_active) ?
                      (ink ? 24'h000000 : background) : 24'h000000;
endmodule
`default_nettype wire
