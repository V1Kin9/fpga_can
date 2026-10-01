# Non-project ETH1 PHY/MDIO probe implementation. Run from an ASCII path.
set source_dir [file dirname [string map [list "\\" "/"] [info script]]]
cd $source_dir
read_verilog reset_sync.v
read_verilog mdio_clause22_reader.v
read_verilog eth1_phy_probe_core.v
read_verilog eth1_phy_probe_top.v
read_xdc kintex7_base_eth1_phy.xdc
synth_design -top eth1_phy_probe_top -part xc7k325tffg676-2
report_utilization -file synth_utilization.rpt
report_timing_summary -file synth_timing.rpt
write_checkpoint -force synthesized.dcp

proc require_nets {names} {
    set nets [get_nets -quiet $names]
    if {[llength $nets] != [llength $names]} {
        error "ETH1 ILA nets missing: requested $names, found $nets"
    }
    return $nets
}
proc bus_names {base width} {
    set names [list]
    for {set bit 0} {$bit < $width} {incr bit} {
        lappend names [format {%s[%d]} $base $bit]
    }
    return $names
}
proc add_probe {core index names} {
    if {$index > 0} { create_debug_port $core probe }
    set port [get_debug_ports [format {%s/probe%d} $core $index]]
    set_property PORT_WIDTH [llength $names] $port
    connect_debug_port $port [require_nets $names]
}

create_debug_core eth1_phy_ila ila
set_property C_DATA_DEPTH 1024 [get_debug_cores eth1_phy_ila]
set_property C_TRIGIN_EN false [get_debug_cores eth1_phy_ila]
set_property C_TRIGOUT_EN false [get_debug_cores eth1_phy_ila]
set_property C_ADV_TRIGGER false [get_debug_cores eth1_phy_ila]
set_property PORT_WIDTH 1 [get_debug_ports eth1_phy_ila/clk]
set clk50_net [get_nets -of_objects [get_pins u_bufg_50m/O]]
connect_debug_port eth1_phy_ila/clk [require_nets $clk50_net]
add_probe eth1_phy_ila 0 [list debug_snapshot_pulse]
add_probe eth1_phy_ila 1 [bus_names debug_snapshot_count 8]
add_probe eth1_phy_ila 2 [bus_names debug_found_mask 32]
add_probe eth1_phy_ila 3 [bus_names debug_found_addr 5]
add_probe eth1_phy_ila 4 [list debug_found_valid]
add_probe eth1_phy_ila 5 [bus_names debug_phy_id1 16]
add_probe eth1_phy_ila 6 [bus_names debug_phy_id2 16]
add_probe eth1_phy_ila 7 [bus_names debug_bmcr 16]
add_probe eth1_phy_ila 8 [bus_names debug_bmsr 16]
add_probe eth1_phy_ila 9 [bus_names debug_physr 16]
add_probe eth1_phy_ila 10 [list debug_link_up]
add_probe eth1_phy_ila 11 [list debug_autoneg_complete]
add_probe eth1_phy_ila 12 [list debug_mmcm_locked]
add_probe eth1_phy_ila 13 [list debug_phy_rstn]
add_probe eth1_phy_ila 14 [list debug_clk125_toggle]
report_debug_core -file debug_core.rpt
puts "ETH1_PHY_ILA_PROBES_CONNECTED"

opt_design
place_design
report_drc -file placed_drc.rpt
report_timing_summary -delay_type min_max -check_timing_verbose -file placed_timing.rpt
route_design
report_drc -file routed_drc.rpt
report_timing_summary -delay_type min_max -check_timing_verbose -file routed_timing.rpt
report_bus_skew -file routed_bus_skew.rpt
check_timing -verbose -file check_timing.rpt
report_clock_interaction -file clock_interaction.rpt
report_utilization -file routed_utilization.rpt
write_checkpoint -force routed_eth1_phy.dcp
write_debug_probes -force eth1_phy.ltx
write_bitstream -force eth1_phy.bit
puts "ETH1_PHY_IMPL_PASS"
exit
