# Kintex7 BaseC ETH1 (RTL8211E, J1), transmit-only 1000 Mb/s RGMII.
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

create_generated_clock -name eth1_mdc -source [get_ports clk_50m] -divide_by 40 [get_ports mdc]
create_generated_clock -name eth1_phy_txc \
    -source [get_pins u_board/u_rgmii_tx/u_txc/C] \
    -edges {1 2 3} -edge_shift {2.0 2.0 2.0} [get_ports rgmii_txc]

# TXDLY strap adds approximately 2 ns inside the PHY, represented by the
# shifted forwarded clock above. The RTL8211E specifies >=1.2 ns setup and
# hold in this mode. Add 0.2 ns modeled board skew on each side. Actual PCB
# trace skew and PHY delay tolerance remain unknown, so this is not signoff.
set rgmii_data [get_ports {rgmii_tx_ctl rgmii_txd[*]}]
set_output_delay -clock [get_clocks eth1_phy_txc] -max 1.4 $rgmii_data
set_output_delay -clock [get_clocks eth1_phy_txc] -min -1.4 $rgmii_data
set_output_delay -clock [get_clocks eth1_phy_txc] -clock_fall -max 1.4 -add_delay $rgmii_data
set_output_delay -clock [get_clocks eth1_phy_txc] -clock_fall -min -1.4 -add_delay $rgmii_data

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
