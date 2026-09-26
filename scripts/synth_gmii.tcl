# Non-project Vivado 2020.1 synthesis flow. Run from an ASCII directory
# containing all RTL .v files and gmii_virtual_clocks.xdc.
read_verilog [glob *.v]
read_xdc gmii_virtual_clocks.xdc
synth_design -top can_gmii_pipeline_top -part xc7k325tffg676-2

set latch_cells [get_cells -hier -filter {REF_NAME =~ LD*}]
if {[llength $latch_cells] != 0} {
    error "Inferred latch cells: $latch_cells"
}

report_utilization -file utilization.rpt
report_utilization -hierarchical -file utilization_hierarchical.rpt
report_timing_summary -file timing_summary.rpt
check_timing -verbose -file check_timing.rpt
report_clock_interaction -file clock_interaction.rpt
report_drc -file drc.rpt
report_cdc -details -file cdc.rpt
write_checkpoint -force synthesized_gmii.dcp
puts "GMII_SYNTH_PASS"
exit
