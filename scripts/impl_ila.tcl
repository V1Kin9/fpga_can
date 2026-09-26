# Non-project Vivado 2020.1 flow. Run from an ASCII working directory that
# contains the RTL files and kintex7_base_can.xdc.
read_verilog [glob *.v]
read_xdc kintex7_base_can.xdc
synth_design -top can_sniffer_top -part xc7k325tffg676-2
report_utilization -file synth_utilization.rpt
report_timing_summary -file synth_timing.rpt
write_checkpoint -force synthesized.dcp

proc require_nets {names} {
    set nets [get_nets -quiet $names]
    if {[llength $nets] != [llength $names]} {
        error "ILA nets missing: requested $names, found $nets"
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
    if {$index > 0} {
        create_debug_port $core probe
    }
    set port [get_debug_ports [format {%s/probe%d} $core $index]]
    set_property PORT_WIDTH [llength $names] $port
    connect_debug_port $port [require_nets $names]
}

create_debug_core can_ila ila
set_property C_DATA_DEPTH 1024 [get_debug_cores can_ila]
set_property C_TRIGIN_EN false [get_debug_cores can_ila]
set_property C_TRIGOUT_EN false [get_debug_cores can_ila]
set_property C_ADV_TRIGGER false [get_debug_cores can_ila]
set_property PORT_WIDTH 1 [get_debug_ports can_ila/clk]
connect_debug_port can_ila/clk [require_nets [list clk_50m_IBUF_BUFG]]

# One probe per semantic field. Bus bit 0 maps to probe bit 0.
add_probe can_ila 0 [list debug_sample_tick]
add_probe can_ila 1 [list debug_bit]
add_probe can_ila 2 [bus_names debug_state 5]
add_probe can_ila 3 [list debug_frame_valid]
add_probe can_ila 4 [bus_names debug_frame_id 29]
add_probe can_ila 5 [list debug_frame_ide]
add_probe can_ila 6 [list debug_frame_rtr]
add_probe can_ila 7 [bus_names debug_dlc 4]
add_probe can_ila 8 [bus_names debug_frame_data 64]
add_probe can_ila 9 [list debug_crc_ok]
add_probe can_ila 10 [list debug_error]
add_probe can_ila 11 [bus_names debug_error_code 8]
add_probe can_ila 12 [bus_names debug_timestamp 32]
add_probe can_ila 13 [list fifo_valid]
add_probe can_ila 14 [list fifo_overflow]
report_debug_core -file debug_core.rpt
puts "CAN_ILA_PROBES_CONNECTED"

opt_design
place_design
report_drc -file placed_drc.rpt
report_timing_summary -file placed_timing.rpt
route_design
report_drc -file routed_drc.rpt
report_timing_summary -file routed_timing.rpt
report_bus_skew -file routed_bus_skew.rpt
report_utilization -file routed_utilization.rpt
write_checkpoint -force routed_ila.dcp
write_debug_probes -force can_ila.ltx
write_bitstream -force can_ila.bit
puts "CAN_ILA_IMPL_PASS"
exit
