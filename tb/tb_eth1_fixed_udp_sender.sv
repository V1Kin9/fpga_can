`timescale 1ns/1ps

module tb_eth1_fixed_udp_sender;
    reg clk = 1'b0;
    always #4 clk = ~clk;
    reg rst_n = 1'b0;
    reg phy_ready = 1'b0;
    wire [7:0] gmii_txd;
    wire gmii_tx_en;
    wire gmii_tx_er;
    wire mac_underrun_error;
    wire [31:0] packet_count;
    integer frame_number = 0;
    integer byte_number = 0;
    integer cycles = 0;
    reg [575:0] golden;

    localparam [575:0] GOLDEN1 = 576'h55555555555555d59483c42aeb74020000000001080045000024000140004011a87cc0a808fac0a808011388138800100000465047410000000100000000000000000000b00b975f;
    localparam [575:0] GOLDEN2 = 576'h55555555555555d59483c42aeb74020000000001080045000024000240004011a87bc0a808fac0a808011388138800100000465047410000000200000000000000000000a8b77526;

    eth1_fixed_udp_sender #(.INTERVAL_CYCLES(200)) dut (
        .clk(clk), .rst_n(rst_n), .phy_ready(phy_ready),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en),
        .gmii_tx_er(gmii_tx_er),
        .mac_underrun_error(mac_underrun_error),
        .packet_count(packet_count)
    );

    always @(negedge clk) begin
        if (rst_n) begin
            if (mac_underrun_error || gmii_tx_er)
                $fatal(1, "MAC underrun or TX_ER");
            if (gmii_tx_en) begin
                if (!phy_ready || frame_number >= 2 || byte_number >= 72)
                    $fatal(1, "unexpected GMII transmission");
                golden = (frame_number == 0) ? GOLDEN1 : GOLDEN2;
                if (gmii_txd !== golden[(71-byte_number)*8 +: 8])
                    $fatal(1, "frame %0d byte %0d got %02x expected %02x",
                           frame_number, byte_number, gmii_txd,
                           golden[(71-byte_number)*8 +: 8]);
                byte_number = byte_number + 1;
            end else if (byte_number != 0) begin
                if (byte_number != 72)
                    $fatal(1, "frame length %0d", byte_number);
                frame_number = frame_number + 1;
                byte_number = 0;
            end
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (30) @(posedge clk);
        if (packet_count != 0 || gmii_tx_en)
            $fatal(1, "sent before PHY ready");
        phy_ready = 1'b1;
        while (frame_number < 2 && cycles < 1000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (frame_number != 2 || packet_count != 2)
            $fatal(1, "missing test packets: frames=%0d count=%0d",
                   frame_number, packet_count);
        phy_ready = 1'b0;
        repeat (20) @(posedge clk);
        $display("[PASS] ETH1 fixed UDP GMII bytes, FCS, sequence, and link gate");
        $finish;
    end
endmodule
