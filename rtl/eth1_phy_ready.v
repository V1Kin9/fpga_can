`timescale 1ns/1ps

// The transmit-only MAC supports resolved 1000 Mb/s full-duplex links only.
// Keep this mode predicate separate from board primitives for direct testing.
module eth1_phy_ready (
    input  wire        found_valid,
    input  wire [4:0]  found_addr,
    input  wire [15:0] phy_id1,
    input  wire        link_up,
    input  wire        autoneg_complete,
    input  wire [15:0] physr,
    output wire        ready
);
    assign ready = found_valid && (found_addr == 5'd1) &&
                   (phy_id1 == 16'h001c) && link_up && autoneg_complete &&
                   physr[11] && physr[10] && physr[13] &&
                   (physr[15:14] == 2'b10);
endmodule
