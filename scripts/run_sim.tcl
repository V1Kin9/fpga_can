set script_dir [file dirname [file normalize [info script]]]
set root [file normalize [file join $script_dir ..]]
if {[llength $argv] >= 1} {
    set top [lindex $argv 0]
} else {
    set top tb_can_rx_top
}
set project_dir [file normalize [file join $root build vivado_sim]]
file mkdir $project_dir
create_project fpga_can_sim $project_dir -part xc7k325tffg676-2 -force
add_files -norecurse [glob -directory [file join $root rtl] *.v]
add_files -fileset sim_1 -norecurse [glob -directory [file join $root tb] *.sv]
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sim_1]]
set_property top $top [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
