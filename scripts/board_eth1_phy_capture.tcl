# JTAG-program and capture two periodic ETH1 PHY status snapshots.
if {[llength $argv] != 1} { error "usage: board_eth1_phy_capture.tcl <ASCII-work-dir>" }
set work [file normalize [lindex $argv 0]]
set bitfile [file join $work eth1_phy.bit]
set ltxfile [file join $work eth1_phy.ltx]
if {![file isfile $bitfile] || ![file isfile $ltxfile]} {
    error "Matched ETH1 PHY bitstream and probes are required"
}

open_hw_manager
connect_hw_server -url localhost:3121
set target [lindex [get_hw_targets] 0]
if {$target eq ""} { error "No JTAG target" }
open_hw_target $target
set device [lindex [get_hw_devices xc7k325t*] 0]
if {$device eq "" || [get_property PART $device] ne "xc7k325t"} {
    error "Expected xc7k325t JTAG device not found"
}
puts "ETH1_PHY_JTAG_DEVICE [get_property PART $device]"
set_property PROGRAM.FILE $bitfile $device
set_property PROBES.FILE $ltxfile $device
program_hw_devices $device
refresh_hw_device $device
set ila [lindex [get_hw_ilas] 0]
if {$ila eq ""} { error "ETH1 PHY ILA core not found" }
set probe [get_hw_probes debug_snapshot_pulse -of_objects $ila]
if {$probe eq ""} { error "debug_snapshot_pulse probe not found" }
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 $probe

foreach index {1 2} {
    run_hw_ila $ila
    if {[catch {wait_on_hw_ila -timeout 5 $ila} reason]} {
        error "ETH1 PHY ILA capture $index failed: $reason"
    }
    set data [upload_hw_ila_data $ila]
    set csv [file join $work "eth1_phy_snapshot_$index.csv"]
    write_hw_ila_data -csv_file -force $csv $data
    puts "ETH1_PHY_CAPTURED $index $csv"
    flush stdout
}
close_hw_target $target
disconnect_hw_server
close_hw_manager
puts "ETH1_PHY_BOARD_CAPTURE_PASS"
exit
