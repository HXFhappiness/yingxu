# YingXu V0.4B timing constraints
# Baseline + explicit CDC declarations (three async clock domains bridged by
# dual-clock FIFOs: 50 MHz board, HDMI PLL outputs, SDRAM PLL outputs).

create_clock -name sys_clk_50m -period 20.000 -waveform {0.000 10.000} [get_ports {clk}]
derive_pll_clocks

set_clock_groups -name cdc_sdram_pll -asynchronous -group [get_clocks {*sdram_pll1*clkc[0]}] -group [get_clocks {*sdram_pll1*clkc[1]}]
set_clock_groups -name cdc_sys_sdram -asynchronous -group [get_clocks {sys_clk_50m}] -group [get_clocks {*sdram_pll1*clkc*}]
set_clock_groups -name cdc_hdmi_sdram -asynchronous -group [get_clocks {*U_pll/pll_inst.clkc*}] -group [get_clocks {*sdram_pll1*clkc*}]
set_clock_groups -name cdc_sys_hdmi -asynchronous -group [get_clocks {sys_clk_50m}] -group [get_clocks {*U_pll/pll_inst.clkc*}]
