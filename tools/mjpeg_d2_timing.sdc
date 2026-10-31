# Standalone decoder synthesis/STA only; do not replace board timing.sdc.
create_clock -name mjpeg_mem_clk_100m -period 10.000 [get_ports {clk}]
