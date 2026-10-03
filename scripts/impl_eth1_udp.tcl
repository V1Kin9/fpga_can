# Non-project physical ETH1 UDP implementation from staged ASCII files.
set source_dir [file dirname [string map [list "\\" "/"] [info script]]]
cd $source_dir
set top $::env(FPGA_CAN_TOP)
set rtl_sources [glob -nocomplain -directory $source_dir *.v]
puts "ETH1 RTL source directory: $source_dir; count: [llength $rtl_sources]"
if {[llength $rtl_sources] == 0} { error "No staged ETH1 RTL sources" }
foreach source $rtl_sources { read_verilog $source }
read_xdc kintex7_base_eth1_udp.xdc
if {$top eq "eth1_can_udp_top"} { read_xdc kintex7_base_eth1_can_udp.xdc }
if {$top eq "eth1_can_udp_top"} {
    if {![info exists ::env(FPGA_CAN_BITRATE)] ||
        $::env(FPGA_CAN_BITRATE) ni {250000 500000}} {
        error "ETH1 CAN bitrate must be 250000 or 500000"
    }
    puts "ETH1_CAN_BITRATE=$::env(FPGA_CAN_BITRATE)"
    synth_design -top $top -part xc7k325tffg676-2 \
        -generic CAN_BITRATE=$::env(FPGA_CAN_BITRATE)
} else {
    synth_design -top $top -part xc7k325tffg676-2
}
if {$top eq "eth1_can_udp_top"} {
    # The bundled frame data and length are stable from req_toggle until ACK.
    # Bound propagation to 8 ns (less than two 125 MHz synchronizer cycles)
    # instead of imposing an unrelated 4 ns 50-to-125 MHz edge relationship.
    set cdc_mem [get_cells -hier -regexp {.*u_frame_cdc/mem_reg.*}]
    set cdc_length [get_cells -hier -regexp {.*u_frame_cdc/stored_length_reg.*}]
    if {[llength $cdc_mem] == 0 || [llength $cdc_length] == 0} {
        error "ETH1 bundled-data CDC endpoints not found"
    }
    set net_clock [get_clocks clk_125m_unbuf]
    if {[llength $net_clock] != 1} { error "ETH1 125 MHz clock not found" }
    set_max_delay 8.0 -datapath_only -from $cdc_mem -to $net_clock
    set_max_delay 8.0 -datapath_only -from $cdc_length -to $net_clock
    puts "ETH1_BUNDLED_CDC_BOUND mem=[llength $cdc_mem] length=[llength $cdc_length] max_ns=8"
}
report_utilization -file synth_utilization.rpt
report_timing_summary -file synth_timing.rpt
write_checkpoint -force synthesized.dcp
opt_design
place_design
report_drc -file placed_drc.rpt
report_timing_summary -delay_type min_max -check_timing_verbose -file placed_timing.rpt
route_design
report_drc -file routed_drc.rpt
report_timing_summary -delay_type min_max -check_timing_verbose -file routed_timing.rpt
report_timing -delay_type max -to [get_ports {rgmii_tx_ctl rgmii_txd[*]}] -max_paths 20 -file rgmii_setup.rpt
report_timing -delay_type min -to [get_ports {rgmii_tx_ctl rgmii_txd[*]}] -max_paths 20 -file rgmii_hold.rpt
check_timing -verbose -file check_timing.rpt
report_clock_interaction -file clock_interaction.rpt
report_utilization -file routed_utilization.rpt
write_checkpoint -force routed_eth1_udp.dcp
write_bitstream -force eth1_udp.bit
puts "ETH1_UDP_IMPL_PASS"
exit
