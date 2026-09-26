set script_dir [file dirname [file normalize [info script]]]
set root [file normalize [file join $script_dir ..]]
if {[llength $argv] >= 1} {
    set project_dir [file normalize [lindex $argv 0]]
} else {
    set project_dir [file normalize [file join $root build vivado]]
}
file mkdir $project_dir
create_project fpga_can $project_dir -part xc7k325tffg676-2 -force
set_property target_language Verilog [current_project]
add_files -norecurse [glob -directory [file join $root rtl] *.v]
add_files -fileset constrs_1 -norecurse [file join $root constraints kintex7_base_can.xdc]
set_property top can_sniffer_top [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "CAN_PROJECT_READY: $project_dir"
