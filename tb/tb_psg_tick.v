`timescale 1ns/1ps
// tb_psg_tick.v - measure yingxu_psg audio_valid rate (the CPU-free sample strobe
// that drives both HDMI audio and the WAV player's out_tick)
module tb_psg_tick;
    reg clk = 0;
    // 73.3333 MHz -> period 13.63636 ns
    always #6.81818 clk = ~clk;
    reg rst = 1;
    wire valid;
    wire [23:0] l, r;

    integer ticks = 0;
    always @(posedge clk) if (valid) ticks = ticks + 1;

    yingxu_psg #(.CLK_HZ(73_333_333), .SAMPLE_HZ(48_000)) dut (
        .clk(clk), .rst(rst),
        .ev_hit(1'b0), .ev_paddle(1'b0), .ev_lose(1'b0), .ev_win(1'b0),
        .enable(1'b1),
        .audio_valid(valid), .audio_left(l), .audio_right(r)
    );

    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        // run 200 ms
        #200_000_000;
        $display("valid pulses in 200ms = %0d  -> rate = %0.1f Hz (expect 48000)",
                 ticks, ticks * 5.0);
        if (ticks > 9000) $display("VERDICT: PSG tick OK");
        else              $display("VERDICT: PSG tick TOO SLOW (~%0d Hz)", ticks * 5);
        $finish;
    end
endmodule
