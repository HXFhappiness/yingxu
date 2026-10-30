`timescale 1ns / 1ps
`default_nettype none

module yingxu_key_debounce #(
    parameter integer DEBOUNCE_COUNT = 1113750
) (
    input  wire clk,
    input  wire rst,
    input  wire key_n,
    output reg  press
);

    reg        sync_ff0;
    reg        sync_ff1;
    reg        stable_n;
    reg [20:0] cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sync_ff0 <= 1'b1;
            sync_ff1 <= 1'b1;
        end else begin
            sync_ff0 <= key_n;
            sync_ff1 <= sync_ff0;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            stable_n <= 1'b1;
            cnt      <= 21'd0;
            press    <= 1'b0;
        end else begin
            press <= 1'b0;

            if (sync_ff1 == stable_n) begin
                cnt <= 21'd0;
            end else if (cnt >= DEBOUNCE_COUNT - 1) begin
                cnt      <= 21'd0;
                stable_n <= sync_ff1;

                if ((stable_n == 1'b1) && (sync_ff1 == 1'b0))
                    press <= 1'b1;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
