`timescale 1ns / 1ps
`default_nettype none

// 映序 V0.2D-R2：精简 8x16 字模。
// 字符集：空格、冒号、0~9，以及当前 OSD 所需大写字母。
module yingxu_font8x16_lite (
    input  wire [7:0] char_code,
    input  wire [3:0] row,
    output reg  [7:0] row_bits
);
    wire [2:0] row_idx;
    assign row_idx = row[3:1];

    always @(*) begin
        row_bits = 8'b00000000;

        case (char_code)
        8'h20: begin
            case (row_idx)
                3'd0: row_bits = 8'b00000000;
                3'd1: row_bits = 8'b00000000;
                3'd2: row_bits = 8'b00000000;
                3'd3: row_bits = 8'b00000000;
                3'd4: row_bits = 8'b00000000;
                3'd5: row_bits = 8'b00000000;
                3'd6: row_bits = 8'b00000000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h3A: begin
            case (row_idx)
                3'd0: row_bits = 8'b00000000;
                3'd1: row_bits = 8'b00010000;
                3'd2: row_bits = 8'b00010000;
                3'd3: row_bits = 8'b00000000;
                3'd4: row_bits = 8'b00010000;
                3'd5: row_bits = 8'b00010000;
                3'd6: row_bits = 8'b00000000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h30: begin
            case (row_idx)
                3'd0: row_bits = 8'b00111000;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b01001100;
                3'd3: row_bits = 8'b01010100;
                3'd4: row_bits = 8'b01100100;
                3'd5: row_bits = 8'b01000100;
                3'd6: row_bits = 8'b00111000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h31: begin
            case (row_idx)
                3'd0: row_bits = 8'b00010000;
                3'd1: row_bits = 8'b00110000;
                3'd2: row_bits = 8'b00010000;
                3'd3: row_bits = 8'b00010000;
                3'd4: row_bits = 8'b00010000;
                3'd5: row_bits = 8'b00010000;
                3'd6: row_bits = 8'b00111000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h32: begin
            case (row_idx)
                3'd0: row_bits = 8'b00111000;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b00000100;
                3'd3: row_bits = 8'b00001000;
                3'd4: row_bits = 8'b00010000;
                3'd5: row_bits = 8'b00100000;
                3'd6: row_bits = 8'b01111100;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h33: begin
            case (row_idx)
                3'd0: row_bits = 8'b01111000;
                3'd1: row_bits = 8'b00000100;
                3'd2: row_bits = 8'b00000100;
                3'd3: row_bits = 8'b00111000;
                3'd4: row_bits = 8'b00000100;
                3'd5: row_bits = 8'b00000100;
                3'd6: row_bits = 8'b01111000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h34: begin
            case (row_idx)
                3'd0: row_bits = 8'b00001000;
                3'd1: row_bits = 8'b00011000;
                3'd2: row_bits = 8'b00101000;
                3'd3: row_bits = 8'b01001000;
                3'd4: row_bits = 8'b01111100;
                3'd5: row_bits = 8'b00001000;
                3'd6: row_bits = 8'b00001000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h35: begin
            case (row_idx)
                3'd0: row_bits = 8'b01111100;
                3'd1: row_bits = 8'b01000000;
                3'd2: row_bits = 8'b01000000;
                3'd3: row_bits = 8'b01111000;
                3'd4: row_bits = 8'b00000100;
                3'd5: row_bits = 8'b00000100;
                3'd6: row_bits = 8'b01111000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h36: begin
            case (row_idx)
                3'd0: row_bits = 8'b00111000;
                3'd1: row_bits = 8'b01000000;
                3'd2: row_bits = 8'b01000000;
                3'd3: row_bits = 8'b01111000;
                3'd4: row_bits = 8'b01000100;
                3'd5: row_bits = 8'b01000100;
                3'd6: row_bits = 8'b00111000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h37: begin
            case (row_idx)
                3'd0: row_bits = 8'b01111100;
                3'd1: row_bits = 8'b00000100;
                3'd2: row_bits = 8'b00001000;
                3'd3: row_bits = 8'b00010000;
                3'd4: row_bits = 8'b00100000;
                3'd5: row_bits = 8'b00100000;
                3'd6: row_bits = 8'b00100000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h38: begin
            case (row_idx)
                3'd0: row_bits = 8'b00111000;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b01000100;
                3'd3: row_bits = 8'b00111000;
                3'd4: row_bits = 8'b01000100;
                3'd5: row_bits = 8'b01000100;
                3'd6: row_bits = 8'b00111000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h39: begin
            case (row_idx)
                3'd0: row_bits = 8'b00111000;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b01000100;
                3'd3: row_bits = 8'b00111100;
                3'd4: row_bits = 8'b00000100;
                3'd5: row_bits = 8'b00000100;
                3'd6: row_bits = 8'b00111000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h41: begin
            case (row_idx)
                3'd0: row_bits = 8'b00111000;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b01000100;
                3'd3: row_bits = 8'b01111100;
                3'd4: row_bits = 8'b01000100;
                3'd5: row_bits = 8'b01000100;
                3'd6: row_bits = 8'b01000100;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h43: begin
            case (row_idx)
                3'd0: row_bits = 8'b00111100;
                3'd1: row_bits = 8'b01000000;
                3'd2: row_bits = 8'b01000000;
                3'd3: row_bits = 8'b01000000;
                3'd4: row_bits = 8'b01000000;
                3'd5: row_bits = 8'b01000000;
                3'd6: row_bits = 8'b00111100;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h44: begin
            case (row_idx)
                3'd0: row_bits = 8'b01111000;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b01000100;
                3'd3: row_bits = 8'b01000100;
                3'd4: row_bits = 8'b01000100;
                3'd5: row_bits = 8'b01000100;
                3'd6: row_bits = 8'b01111000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h45: begin
            case (row_idx)
                3'd0: row_bits = 8'b01111100;
                3'd1: row_bits = 8'b01000000;
                3'd2: row_bits = 8'b01000000;
                3'd3: row_bits = 8'b01111000;
                3'd4: row_bits = 8'b01000000;
                3'd5: row_bits = 8'b01000000;
                3'd6: row_bits = 8'b01111100;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h47: begin
            case (row_idx)
                3'd0: row_bits = 8'b00111100;
                3'd1: row_bits = 8'b01000000;
                3'd2: row_bits = 8'b01000000;
                3'd3: row_bits = 8'b01011100;
                3'd4: row_bits = 8'b01000100;
                3'd5: row_bits = 8'b01000100;
                3'd6: row_bits = 8'b00111100;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h48: begin
            case (row_idx)
                3'd0: row_bits = 8'b01000100;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b01000100;
                3'd3: row_bits = 8'b01111100;
                3'd4: row_bits = 8'b01000100;
                3'd5: row_bits = 8'b01000100;
                3'd6: row_bits = 8'b01000100;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h49: begin
            case (row_idx)
                3'd0: row_bits = 8'b00111000;
                3'd1: row_bits = 8'b00010000;
                3'd2: row_bits = 8'b00010000;
                3'd3: row_bits = 8'b00010000;
                3'd4: row_bits = 8'b00010000;
                3'd5: row_bits = 8'b00010000;
                3'd6: row_bits = 8'b00111000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h4C: begin
            case (row_idx)
                3'd0: row_bits = 8'b01000000;
                3'd1: row_bits = 8'b01000000;
                3'd2: row_bits = 8'b01000000;
                3'd3: row_bits = 8'b01000000;
                3'd4: row_bits = 8'b01000000;
                3'd5: row_bits = 8'b01000000;
                3'd6: row_bits = 8'b01111100;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h4D: begin
            case (row_idx)
                3'd0: row_bits = 8'b01000100;
                3'd1: row_bits = 8'b01101100;
                3'd2: row_bits = 8'b01010100;
                3'd3: row_bits = 8'b01010100;
                3'd4: row_bits = 8'b01000100;
                3'd5: row_bits = 8'b01000100;
                3'd6: row_bits = 8'b01000100;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h4E: begin
            case (row_idx)
                3'd0: row_bits = 8'b01000100;
                3'd1: row_bits = 8'b01100100;
                3'd2: row_bits = 8'b01010100;
                3'd3: row_bits = 8'b01001100;
                3'd4: row_bits = 8'b01000100;
                3'd5: row_bits = 8'b01000100;
                3'd6: row_bits = 8'b01000100;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h4F: begin
            case (row_idx)
                3'd0: row_bits = 8'b00111000;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b01000100;
                3'd3: row_bits = 8'b01000100;
                3'd4: row_bits = 8'b01000100;
                3'd5: row_bits = 8'b01000100;
                3'd6: row_bits = 8'b00111000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h52: begin
            case (row_idx)
                3'd0: row_bits = 8'b01111000;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b01000100;
                3'd3: row_bits = 8'b01111000;
                3'd4: row_bits = 8'b01010000;
                3'd5: row_bits = 8'b01001000;
                3'd6: row_bits = 8'b01000100;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h54: begin
            case (row_idx)
                3'd0: row_bits = 8'b01111100;
                3'd1: row_bits = 8'b00010000;
                3'd2: row_bits = 8'b00010000;
                3'd3: row_bits = 8'b00010000;
                3'd4: row_bits = 8'b00010000;
                3'd5: row_bits = 8'b00010000;
                3'd6: row_bits = 8'b00010000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h55: begin
            case (row_idx)
                3'd0: row_bits = 8'b01000100;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b01000100;
                3'd3: row_bits = 8'b01000100;
                3'd4: row_bits = 8'b01000100;
                3'd5: row_bits = 8'b01000100;
                3'd6: row_bits = 8'b00111000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h56: begin
            case (row_idx)
                3'd0: row_bits = 8'b01000100;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b01000100;
                3'd3: row_bits = 8'b01000100;
                3'd4: row_bits = 8'b01000100;
                3'd5: row_bits = 8'b00101000;
                3'd6: row_bits = 8'b00010000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h58: begin
            case (row_idx)
                3'd0: row_bits = 8'b01000100;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b00101000;
                3'd3: row_bits = 8'b00010000;
                3'd4: row_bits = 8'b00101000;
                3'd5: row_bits = 8'b01000100;
                3'd6: row_bits = 8'b01000100;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h59: begin
            case (row_idx)
                3'd0: row_bits = 8'b01000100;
                3'd1: row_bits = 8'b01000100;
                3'd2: row_bits = 8'b00101000;
                3'd3: row_bits = 8'b00010000;
                3'd4: row_bits = 8'b00010000;
                3'd5: row_bits = 8'b00010000;
                3'd6: row_bits = 8'b00010000;
                default: row_bits = 8'b00000000;
            endcase
        end
        8'h5A: begin
            case (row_idx)
                3'd0: row_bits = 8'b01111100;
                3'd1: row_bits = 8'b00000100;
                3'd2: row_bits = 8'b00001000;
                3'd3: row_bits = 8'b00010000;
                3'd4: row_bits = 8'b00100000;
                3'd5: row_bits = 8'b01000000;
                3'd6: row_bits = 8'b01111100;
                default: row_bits = 8'b00000000;
            endcase
        end
        default: row_bits = 8'b00000000;
        endcase
    end

endmodule

`default_nettype wire
