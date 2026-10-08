`timescale 1ns/1ps
module tb_eth1_fixed_udp_link_loss;
    reg clk=0, rst_n=0, phy_ready=0;
    always #4 clk=~clk;
    wire [7:0] gmii_txd;
    wire gmii_tx_en, gmii_tx_er, mac_underrun_error;
    wire [31:0] packet_count;
    integer byte_number, cut, trial;
    localparam [575:0] GOLDEN2 = 576'h55555555555555d59483c42aeb74020000000001080045000024000240004011a87bc0a808fac0a808011388138800100000465047410000000200000000000000000000a8b77526;

    eth1_fixed_udp_sender #(.INTERVAL_CYCLES(200)) dut (
        .clk(clk), .rst_n(rst_n), .phy_ready(phy_ready),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .mac_underrun_error(mac_underrun_error), .packet_count(packet_count)
    );
    initial begin
        // Abort in preamble, SFD, header, payload, padding and FCS respectively.
        for (trial=0; trial<6; trial=trial+1) begin
            case (trial)
                0: cut=1;
                1: cut=8;
                2: cut=24;
                3: cut=54;
                4: cut=65;
                5: cut=70;
            endcase
            @(negedge clk); rst_n=0; phy_ready=0;
            repeat(4) @(negedge clk);
            rst_n=1;
            repeat(4) @(negedge clk);
            if (gmii_tx_en || packet_count!=0) $fatal(1,"traffic before link ready");
            phy_ready=1;
            wait(gmii_tx_en);
            repeat(cut) @(negedge clk);
            #1; phy_ready=0;
            #1;
            if (gmii_tx_en || gmii_tx_er || mac_underrun_error)
                $fatal(1,"link loss did not abort active frame at byte %0d",cut);
            // First trial uses the shortest sampled outage; others stay down.
            repeat(trial==0 ? 1 : 8) begin
                @(negedge clk); #1;
                if (gmii_tx_en || packet_count!=1)
                    $fatal(1,"continued/queued traffic while link down");
            end
            phy_ready=1;
            wait(gmii_tx_en);
            for (byte_number=0; byte_number<72; byte_number=byte_number+1) begin
                @(negedge clk); #1;
                if (!gmii_tx_en || gmii_tx_er || mac_underrun_error ||
                    gmii_txd!==GOLDEN2[(71-byte_number)*8 +: 8])
                    $fatal(1,"recovered frame mismatch trial=%0d byte=%0d got=%02x",trial,byte_number,gmii_txd);
            end
            @(negedge clk); #1;
            if (gmii_tx_en || packet_count!=2)
                $fatal(1,"recovered frame length/count mismatch");
        end
        $display("[PASS] fixed UDP abort and golden-frame recovery through all transmit phases");
        $finish;
    end
    initial begin #100000; $fatal(1,"fixed UDP link-loss timeout"); end
endmodule
