`timescale 1ns/1ps
module tb_eth1_phy_ready;
    reg found_valid=1, link_up=1, autoneg_complete=1;
    reg [4:0] found_addr=5'd1;
    reg [15:0] phy_id1=16'h001c;
    reg [15:0] physr=16'had02;
    wire ready;
    integer speed;

    eth1_phy_ready dut (
        .found_valid(found_valid), .found_addr(found_addr), .phy_id1(phy_id1),
        .link_up(link_up), .autoneg_complete(autoneg_complete),
        .physr(physr), .ready(ready)
    );
    task expect_ready(input reg expected);
        begin
            #1;
            if (ready !== expected)
                $fatal(1,"PHY mode gate got %b expected %b PHYSR=%h",ready,expected,physr);
        end
    endtask
    initial begin
        expect_ready(1);
        // Same resolved/link/speed bits, but 1000 Mb/s half duplex.
        physr[13]=0; expect_ready(0);
        physr[13]=1; expect_ready(1);
        for (speed=0; speed<4; speed=speed+1) begin
            physr[15:14]=speed; expect_ready(speed==2);
        end
        physr=16'had02;
        physr[11]=0; expect_ready(0); physr[11]=1;
        physr[10]=0; expect_ready(0); physr[10]=1;
        found_valid=0; expect_ready(0); found_valid=1;
        found_addr=2; expect_ready(0); found_addr=1;
        phy_id1=16'hffff; expect_ready(0); phy_id1=16'h001c;
        link_up=0; expect_ready(0); link_up=1;
        autoneg_complete=0; expect_ready(0); autoneg_complete=1;
        expect_ready(1);
        $display("[PASS] ETH1 PHY identity, speed, link, resolution and full-duplex gate");
        $finish;
    end
endmodule
