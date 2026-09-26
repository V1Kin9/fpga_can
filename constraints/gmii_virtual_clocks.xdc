# Portable internal timing model. No board pins or RGMII source-synchronous
# delays are asserted before the actual clock source and PHY are available.
create_clock -name clk_50m -period 20.000 [get_ports clk_50m]
create_clock -name gmii_clk_125m -period 8.000 [get_ports gmii_clk_125m]

# The two input clocks are independent. report_cdc and the documented
# bundled-data handshake review remain mandatory despite this exception.
set_clock_groups -asynchronous \
    -group [get_clocks clk_50m] \
    -group [get_clocks gmii_clk_125m]

set_false_path -from [get_ports can_rx]
set_false_path -from [get_ports rst_n]
