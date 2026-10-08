# Program an exact ETH1 UDP bitstream on the Kintex-7 over JTAG.
if {[llength $argv] != 1} { error "usage: program_eth1_udp.tcl <ASCII-bitstream-path>" }
set bitfile [lindex $argv 0]
if {![file isfile $bitfile]} { error "ETH1 UDP bitstream not found: $bitfile" }
open_hw_manager
connect_hw_server -url localhost:3121
set target [lindex [get_hw_targets] 0]
if {$target eq ""} { error "No JTAG target" }
open_hw_target $target
set device [lindex [get_hw_devices xc7k325t*] 0]
if {$device eq "" || [get_property PART $device] ne "xc7k325t"} {
    error "Expected xc7k325t JTAG device not found"
}
set_property PROGRAM.FILE $bitfile $device
set_property PROBES.FILE {} $device
program_hw_devices $device
refresh_hw_device $device
puts "ETH1_UDP_JTAG_PROGRAM_PASS [get_property PART $device] $bitfile"
close_hw_target $target
disconnect_hw_server
close_hw_manager
exit
