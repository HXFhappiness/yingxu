`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// YingXu V0.3C-B-R1
// Unified media-stream test source
//
// Contract:
//   media_clk supplied by framebuffer sink.
//   Transfer occurs only when media_valid && media_ready.
//
// One transferred word:
//   media_data[31:16] = left  RGB565 pixel
//   media_data[15:0]  = right RGB565 pixel
//
// One fixed frame:
//   1280 x 720 RGB565
//   640 x 720 = 460800 32-bit words
//
// frame_start / frame_end are sidebands aligned to the transferred word.
// The source holds data and sidebands stable while media_ready == 0.
//
// Future TF/BMP source only needs to implement this same interface.
//------------------------------------------------------------------------------

module yingxu_test_media_source #(
    parameter integer H_ACTIVE = 1280,
    parameter integer V_ACTIVE = 720
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [1:0]  scene_request,

    output wire        media_valid,
    input  wire        media_ready,
    output wire [31:0] media_data,
    output wire        media_frame_start,
    output wire        media_frame_end
);

    localparam integer WORDS_PER_LINE = H_ACTIVE / 2;

    reg [9:0] word_x;
    reg [9:0] y;
    reg [3:0] phase;

    reg [1:0] scene_meta;
    reg [1:0] scene_sync;
    reg [1:0] scene_active;

    wire media_fire = media_valid && media_ready;

    function [15:0] pattern565;
        input [9:0] x_word;
        input [9:0] y_line;
        input [3:0] frame_phase;
        input [1:0] scene_sel;
        reg [9:0] marker_left;
        begin
            marker_left = 10'd20 + {frame_phase, 5'b00000};

            case (scene_sel)
                // Scene 0: keep the proven C-A picture.
                2'd0: begin
                    if ((x_word < 10'd4) ||
                        (x_word >= WORDS_PER_LINE - 4) ||
                        (y_line < 10'd8) ||
                        (y_line >= V_ACTIVE - 8)) begin
                        pattern565 = 16'hFFFF;
                    end
                    else if ((y_line >= 10'd220) && (y_line < 10'd340) &&
                             (x_word >= marker_left) &&
                             (x_word < marker_left + 10'd60)) begin
                        pattern565 = 16'hFD20;
                    end
                    else if ((y_line >= 10'd650) && (y_line < 10'd680)) begin
                        case (frame_phase[2:0])
                            3'd0: pattern565 = 16'hF800;
                            3'd1: pattern565 = 16'h001F;
                            3'd2: pattern565 = 16'hF81F;
                            3'd3: pattern565 = 16'hFFFF;
                            3'd4: pattern565 = 16'h07E0;
                            3'd5: pattern565 = 16'h07FF;
                            3'd6: pattern565 = 16'hFFE0;
                            default: pattern565 = 16'h8410;
                        endcase
                    end
                    else if (x_word < 10'd80)
                        pattern565 = 16'h0000;
                    else if (x_word < 10'd160)
                        pattern565 = 16'h001F;
                    else if (x_word < 10'd240)
                        pattern565 = 16'h07E0;
                    else if (x_word < 10'd320)
                        pattern565 = 16'h07FF;
                    else if (x_word < 10'd400)
                        pattern565 = 16'hF800;
                    else if (x_word < 10'd480)
                        pattern565 = 16'hF81F;
                    else if (x_word < 10'd560)
                        pattern565 = 16'hFFE0;
                    else
                        pattern565 = 16'hFFFF;
                end

                // Scene 1: very light logic, solid blue with a white box.
                2'd1: begin
                    if ((x_word < 10'd4) ||
                        (x_word >= WORDS_PER_LINE - 4) ||
                        (y_line < 10'd8) ||
                        (y_line >= V_ACTIVE - 8)) begin
                        pattern565 = 16'hFFFF;
                    end
                    else if ((x_word >= 10'd140) && (x_word < 10'd500) &&
                             (y_line >= 10'd170) && (y_line < 10'd550) &&
                             ((x_word < 10'd148) || (x_word >= 10'd492) ||
                              (y_line < 10'd178) || (y_line >= 10'd542))) begin
                        pattern565 = 16'hFFFF;
                    end
                    else begin
                        pattern565 = 16'h001F;
                    end
                end

                // Scene 2: very light logic, dark background with cyan/orange bars.
                default: begin
                    if ((x_word < 10'd4) ||
                        (x_word >= WORDS_PER_LINE - 4) ||
                        (y_line < 10'd8) ||
                        (y_line >= V_ACTIVE - 8)) begin
                        pattern565 = 16'h07FF;
                    end
                    else if ((y_line >= 10'd180) && (y_line < 10'd260) &&
                             (x_word >= 10'd100) && (x_word < 10'd540)) begin
                        pattern565 = 16'hFD20;
                    end
                    else if ((y_line >= 10'd420) && (y_line < 10'd500) &&
                             (x_word >= 10'd100) && (x_word < 10'd540)) begin
                        pattern565 = 16'h07FF;
                    end
                    else begin
                        pattern565 = 16'h0841;
                    end
                end
            endcase
        end
    endfunction

    wire [15:0] pixel565 = pattern565(word_x, y, phase, scene_active);

    // Test source is always willing to provide a word after reset.
    // Backpressure is handled by freezing word_x/y/phase until media_ready.
    assign media_valid       = ~rst;
    assign media_data        = {pixel565, pixel565};
    assign media_frame_start = (word_x == 10'd0) &&
                               (y      == 10'd0);
    assign media_frame_end   = (word_x == WORDS_PER_LINE - 1) &&
                               (y      == V_ACTIVE - 1);


    // Lightweight scene select CDC.
    // scene_active only changes while parked at frame start.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            scene_meta   <= 2'd0;
            scene_sync   <= 2'd0;
            scene_active <= 2'd0;
        end
        else begin
            scene_meta <= scene_request;
            scene_sync <= scene_meta;

            if ((word_x == 10'd0) && (y == 10'd0))
                scene_active <= scene_sync;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            word_x <= 10'd0;
            y      <= 10'd0;
            phase  <= 4'd0;
        end
        else if (media_fire) begin
            if (word_x == WORDS_PER_LINE - 1) begin
                word_x <= 10'd0;

                if (y == V_ACTIVE - 1) begin
                    y     <= 10'd0;
                    phase <= phase + 1'b1;
                end
                else begin
                    y <= y + 1'b1;
                end
            end
            else begin
                word_x <= word_x + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
