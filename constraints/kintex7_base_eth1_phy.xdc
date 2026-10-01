# Kintex7 BaseC ETH1 diagnostic only. No Ethernet frame data is sent.
set_property PACKAGE_PIN G22 [get_ports clk_50m]
set_property IOSTANDARD LVCMOS33 [get_ports clk_50m]
create_clock -period 20.000 -name clk_50m [get_ports clk_50m]

set_property PACKAGE_PIN D26 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
set_false_path -from [get_ports rst_n]

set_property PACKAGE_PIN Y2 [get_ports phy_rstn]
set_property PACKAGE_PIN W1 [get_ports mdc]
set_property PACKAGE_PIN AF5 [get_ports mdio]
set_property PACKAGE_PIN AC2 [get_ports rgmii_txc]
set_property PACKAGE_PIN Y1 [get_ports rgmii_tx_ctl]
set_property PACKAGE_PIN AC1 [get_ports {rgmii_txd[0]}]
set_property PACKAGE_PIN AB1 [get_ports {rgmii_txd[1]}]
set_property PACKAGE_PIN AB4 [get_ports {rgmii_txd[2]}]
set_property PACKAGE_PIN Y3 [get_ports {rgmii_txd[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {phy_rstn mdc mdio rgmii_txc rgmii_tx_ctl rgmii_txd[*]}]

# Describe the two forwarded clocks. MDC runs only while a transaction is
# active; these generated clocks describe its active waveform and TXC.
create_generated_clock -name eth1_mdc -source [get_ports clk_50m] -divide_by 40 [get_ports mdc]
create_generated_clock -name eth1_txc -source [get_pins u_txc_oddr/C] -divide_by 1 [get_ports rgmii_txc]

# This diagnostic has no variable RGMII TX data. Timing for the later packet
# transmitter must be constrained separately against TXC and board skew.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
