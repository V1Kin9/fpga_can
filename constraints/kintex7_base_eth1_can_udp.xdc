# Additional isolated bench CAN pins for eth1_can_udp_top only.
set_property PACKAGE_PIN D13 [get_ports can_rx]
set_property IOSTANDARD LVCMOS33 [get_ports can_rx]
set_property PACKAGE_PIN B14 [get_ports can_tx]
set_property IOSTANDARD LVCMOS33 [get_ports can_tx]
set_false_path -from [get_ports can_rx]
