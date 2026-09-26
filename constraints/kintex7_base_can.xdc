set_property PACKAGE_PIN G22 [get_ports clk_50m]
set_property IOSTANDARD LVCMOS33 [get_ports clk_50m]
create_clock -period 20.000 -name clk_50m [get_ports clk_50m]

set_property PACKAGE_PIN D26 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

set_property PACKAGE_PIN D13 [get_ports can_rx]
set_property IOSTANDARD LVCMOS33 [get_ports can_rx]

set_property PACKAGE_PIN B14 [get_ports can_tx]
set_property IOSTANDARD LVCMOS33 [get_ports can_tx]

# Match the Kintex7_BaseC vendor XDC configuration-bank settings.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
