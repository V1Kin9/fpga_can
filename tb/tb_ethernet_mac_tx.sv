`timescale 1ns/1ps
module tb_ethernet_mac_tx;
    reg clk = 0;
    always #4 clk = ~clk; // 125 MHz

    reg rst_n = 0;
    reg frame_valid = 0;
    wire frame_ready;
    reg [15:0] frame_length = 16'd20;
    reg frame_data_valid = 0;
    wire frame_data_ready;
    reg [7:0] frame_data = 0;
    reg frame_data_last = 0;

    wire gmii_tx_en;
    wire gmii_tx_er;
    wire [7:0] gmii_txd;
    wire underrun_error;

    ethernet_mac_tx dut (
        .clk(clk), .rst_n(rst_n),
        .frame_valid(frame_valid), .frame_ready(frame_ready),
        .frame_length(frame_length),
        .frame_data_valid(frame_data_valid),
        .frame_data_ready(frame_data_ready),
        .frame_data(frame_data), .frame_data_last(frame_data_last),
        .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .gmii_txd(gmii_txd), .underrun_error(underrun_error)
    );

    integer source_index = 0;
    reg [7:0] sent [0:127];
    integer sent_count = 0;
    integer error_seen = 0;
    integer idle_after_frame = 0;
    integer frame_finished = 0;

    always @(*) begin
        frame_data_valid = frame_data_ready && (source_index < 20);
        frame_data = source_index[7:0];
        frame_data_last = (source_index == 19);
    end

    always @(posedge clk) begin
        if (frame_data_valid && frame_data_ready)
            source_index <= source_index + 1;
        if (underrun_error)
            error_seen = error_seen + 1;
    end

    // Sample the GMII value in the middle of each 8 ns byte period.
    always @(negedge clk) begin
        if (gmii_tx_en) begin
            sent[sent_count] = gmii_txd;
            sent_count = sent_count + 1;
            if (gmii_tx_er)
                $fatal(1, "unexpected GMII TX_ER at byte %0d", sent_count-1);
        end else if (sent_count != 0 && !frame_finished) begin
            frame_finished = 1;
            idle_after_frame = 1;
        end else if (frame_finished && !frame_ready) begin
            idle_after_frame = idle_after_frame + 1;
        end
    end

    integer i;
    integer watchdog;

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;

        frame_valid = 1;
        #1;
        if (!frame_ready)
            $fatal(1, "MAC not ready in idle");
        @(posedge clk);
        @(negedge clk);
        frame_valid = 0;

        watchdog = 0;
        while (!frame_ready && watchdog < 300) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end

        if (!frame_ready)
            $fatal(1, "MAC did not return to idle");
        if (error_seen != 0)
            $fatal(1, "MAC reported underrun on continuous source");

        // 7-byte preamble + SFD + padded 60-byte frame + 4-byte FCS.
        if (sent_count != 72)
            $fatal(1, "MAC transmitted %0d active bytes expected 72", sent_count);

        for (i=0; i<7; i=i+1)
            if (sent[i] !== 8'h55)
                $fatal(1, "preamble[%0d]=%02h", i, sent[i]);
        if (sent[7] !== 8'hD5)
            $fatal(1, "SFD=%02h", sent[7]);

        for (i=0; i<20; i=i+1)
            if (sent[8+i] !== i[7:0])
                $fatal(1, "payload[%0d]=%02h", i, sent[8+i]);
        for (i=0; i<40; i=i+1)
            if (sent[28+i] !== 8'h00)
                $fatal(1, "padding[%0d]=%02h", i, sent[28+i]);

        // IEEE 802.3 CRC32 of bytes 00..13 followed by 40 zero padding bytes.
        if (sent[68] !== 8'h72 || sent[69] !== 8'h18 ||
            sent[70] !== 8'h0E || sent[71] !== 8'hD4)
            $fatal(1, "FCS=%02h %02h %02h %02h expected 72 18 0E D4",
                   sent[68],sent[69],sent[70],sent[71]);

        if (idle_after_frame < 12)
            $fatal(1, "IFG shorter than 12 byte-times: %0d", idle_after_frame);

        $display("[PASS] Ethernet MAC TX preamble, padding, CRC32/FCS, IFG");
        $finish;
    end
endmodule
