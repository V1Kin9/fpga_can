# Vivado 2020.1 hardware capture half of run_board_can_matrix.ps1.
# Arguments: relative output directory containing cases.txt.
if {[llength $argv] != 1} { error "usage: board_can_capture.tcl <output-dir>" }
set out_dir [file normalize [lindex $argv 0]]
set list_file [file join $out_dir cases.txt]
if {![file isfile $list_file]} { error "Missing case list: $list_file" }
set fh [open $list_file r]
set cases [split [string trim [read $fh]] "\n"]
close $fh

set bitfile [file join $out_dir can_ila.bit]
set ltxfile [file join $out_dir can_ila.ltx]
if {![file isfile $bitfile] || ![file isfile $ltxfile]} {
    error "Matched CAN-only bitstream and probes are required"
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
set_property PROGRAM.FILE $bitfile $device
set_property PROBES.FILE $ltxfile $device
program_hw_devices $device
refresh_hw_device $device
set ila [lindex [get_hw_ilas] 0]
if {$ila eq ""} { error "CAN-only ILA core not found" }
set probe [get_hw_probes debug_frame_valid -of_objects $ila]
if {$probe eq ""} { error "debug_frame_valid probe not found" }
set_property CONTROL.TRIGGER_CONDITION AND $ila
set_property CONTROL.TRIGGER_POSITION 0 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 $probe

foreach case_name $cases {
    set case_name [string trim $case_name]
    if {![regexp {^[a-z0-9_]+$} $case_name]} { error "Invalid case name: $case_name" }
    run_hw_ila $ila
    set flag [open [file join $out_dir "$case_name.armed"] w]
    puts $flag "armed"
    close $flag
    puts "BOARD_MATRIX_ARMED $case_name"
    flush stdout

    if {[catch {wait_on_hw_ila -timeout 0.5 $ila} reason]} {
        error "ILA capture failed for $case_name: $reason"
    }
    set data [upload_hw_ila_data $ila]
    set csv [file join $out_dir "$case_name.csv"]
    write_hw_ila_data -csv_file -force $csv $data
    set flag [open [file join $out_dir "$case_name.captured"] w]
    puts $flag $csv
    close $flag
    puts "BOARD_MATRIX_CAPTURED $case_name $csv"
    flush stdout
}

close_hw_target $target
disconnect_hw_server
close_hw_manager
puts "BOARD_MATRIX_CAPTURE_COMPLETE"
exit
