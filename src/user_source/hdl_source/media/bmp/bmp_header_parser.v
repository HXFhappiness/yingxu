`timescale 1ns / 1ps

//------------------------------------------------------------------------------
// YingXu BMP Header Parser R1
// Fixed: BMP multi-byte fields are LITTLE-ENDIAN.
// Supported format:
//   - Signature "BM"
//   - BITMAPINFOHEADER or compatible header (first 54 bytes are enough here)
//   - 24-bit
//   - BI_RGB / uncompressed
//
// Protocol:
//   1) pulse start before byte 0
//   2) present bytes 0..53 in file order with valid
//   3) header_valid pulses for one clk after byte 53
//------------------------------------------------------------------------------

module bmp_header_parser (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  data,
    input  wire        valid,
    input  wire        start,

    output reg  [31:0] width,
    output reg  [31:0] height,
    output reg  [15:0] bpp,
    output reg  [31:0] pixel_offset,
    output reg         header_valid,
    output reg         format_ok
);

    localparam IDLE  = 3'd0;
    localparam HEAD1 = 3'd1;
    localparam HEAD2 = 3'd2;
    localparam CHECK = 3'd3;
    localparam DONE  = 3'd4;

    reg [2:0] state, nxt_state;
    reg [7:0] byte_cnt;

    reg [15:0] temp_bpp;
    reg [31:0] temp_compression;
    reg [15:0] temp_planes;
    reg        signature_ok;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= nxt_state;
    end

    always @(*) begin
        case (state)
            IDLE:  nxt_state = start ? HEAD1 : IDLE;
            HEAD1: nxt_state = (valid && byte_cnt == 8'd13) ? HEAD2 : HEAD1;
            HEAD2: nxt_state = (valid && byte_cnt == 8'd53) ? CHECK : HEAD2;
            CHECK: nxt_state = DONE;
            DONE:  nxt_state = IDLE;
            default: nxt_state = IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt <= 8'd0;
        end
        else if (state == IDLE && start) begin
            byte_cnt <= 8'd0;
        end
        else if (valid && (state == HEAD1 || state == HEAD2)) begin
            byte_cnt <= byte_cnt + 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            width            <= 32'd0;
            height           <= 32'd0;
            bpp              <= 16'd0;
            pixel_offset     <= 32'd0;
            temp_bpp         <= 16'd0;
            temp_compression <= 32'd0;
            temp_planes      <= 16'd0;
            signature_ok     <= 1'b0;
            header_valid     <= 1'b0;
            format_ok        <= 1'b0;
        end
        else begin
            header_valid <= 1'b0;

            if (state == IDLE && start) begin
                width            <= 32'd0;
                height           <= 32'd0;
                bpp              <= 16'd0;
                pixel_offset     <= 32'd0;
                temp_bpp         <= 16'd0;
                temp_compression <= 32'd0;
                temp_planes      <= 16'd0;
                signature_ok     <= 1'b1;
                format_ok        <= 1'b0;
            end

            if (valid && (state == HEAD1 || state == HEAD2)) begin
                // BMP signature
                if (byte_cnt == 8'd0 && data != 8'h42)
                    signature_ok <= 1'b0; // 'B'
                if (byte_cnt == 8'd1 && data != 8'h4D)
                    signature_ok <= 1'b0; // 'M'

                // bfOffBits @ 10..13, little-endian
                case (byte_cnt)
                    8'd10: pixel_offset[7:0]   <= data;
                    8'd11: pixel_offset[15:8]  <= data;
                    8'd12: pixel_offset[23:16] <= data;
                    8'd13: pixel_offset[31:24] <= data;

                    // biWidth @ 18..21, little-endian
                    8'd18: width[7:0]          <= data;
                    8'd19: width[15:8]         <= data;
                    8'd20: width[23:16]        <= data;
                    8'd21: width[31:24]        <= data;

                    // biHeight @ 22..25, little-endian
                    8'd22: height[7:0]         <= data;
                    8'd23: height[15:8]        <= data;
                    8'd24: height[23:16]       <= data;
                    8'd25: height[31:24]       <= data;

                    // biPlanes @ 26..27
                    8'd26: temp_planes[7:0]    <= data;
                    8'd27: temp_planes[15:8]   <= data;

                    // biBitCount @ 28..29
                    8'd28: temp_bpp[7:0]       <= data;
                    8'd29: temp_bpp[15:8]      <= data;

                    // biCompression @ 30..33
                    8'd30: temp_compression[7:0]   <= data;
                    8'd31: temp_compression[15:8]  <= data;
                    8'd32: temp_compression[23:16] <= data;
                    8'd33: temp_compression[31:24] <= data;

                    default: ;
                endcase
            end

            if (state == CHECK) begin
                bpp          <= temp_bpp;
                header_valid <= 1'b1;

                if (signature_ok &&
                    (temp_planes == 16'd1) &&
                    (temp_bpp == 16'd24) &&
                    (temp_compression == 32'd0))
                    format_ok <= 1'b1;
                else
                    format_ok <= 1'b0;
            end
        end
    end

endmodule
