`timescale 1ns/1ps
module tb_can_udp_payload_packetizer;
    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg frame_valid = 0;
    wire frame_ready;
    reg [28:0] frame_id = 0;
    reg frame_ide = 0;
    reg frame_rtr = 0;
    reg [3:0] frame_dlc = 0;
    reg [63:0] frame_data = 0;
    reg [63:0] frame_timestamp = 0;
    reg frame_crc_ok = 1;

    wire packet_valid;
    reg packet_ready = 1;
    wire [15:0] packet_length;
    wire [31:0] packet_sequence;

    wire tx_valid;
    reg tx_ready = 1;
    wire [7:0] tx_data;
    wire tx_last;

    reg [7:0] captured [0:255];
    integer captured_count = 0;
    integer packet_done = 0;
    integer announced_length = 0;
    reg [31:0] announced_sequence = 0;

    can_udp_payload_packetizer #(
        .MAX_FRAMES(3),
        .FLUSH_CYCLES(12)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .frame_valid(frame_valid), .frame_ready(frame_ready),
        .frame_id(frame_id), .frame_ide(frame_ide), .frame_rtr(frame_rtr),
        .frame_dlc(frame_dlc), .frame_data(frame_data),
        .frame_timestamp(frame_timestamp), .frame_crc_ok(frame_crc_ok),
        .session_id(32'd0), .error_valid(1'b0), .error_code(8'd0),
        .error_timestamp(64'd0), .status_valid(1'b0), .status_flags(8'd0),
        .status_queue_level(8'd0), .status_queue_high_watermark(8'd0),
        .status_uptime_ticks(64'd0), .status_counters(128'd0),
        .packet_valid(packet_valid), .packet_ready(packet_ready),
        .packet_length(packet_length), .packet_sequence(packet_sequence),
        .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx_data(tx_data), .tx_last(tx_last)
    );

    always @(posedge clk) begin
        if (packet_valid && packet_ready) begin
            announced_length = packet_length;
            announced_sequence = packet_sequence;
            captured_count = 0;
        end
        if (tx_valid && tx_ready) begin
            captured[captured_count] = tx_data;
            captured_count = captured_count + 1;
            if (tx_last)
                packet_done = packet_done + 1;
        end
    end

    task send_frame(
        input [28:0] id,
        input ide,
        input rtr,
        input [3:0] dlc,
        input [63:0] data,
        input [63:0] ts
    );
        begin
            while (!frame_ready)
                @(negedge clk);
            frame_id = id;
            frame_ide = ide;
            frame_rtr = rtr;
            frame_dlc = dlc;
            frame_data = data;
            frame_timestamp = ts;
            frame_crc_ok = 1;
            frame_valid = 1;
            @(negedge clk);
            frame_valid = 0;
        end
    endtask

    task wait_packet(input integer expected_done);
        integer watchdog;
        begin
            watchdog = 0;
            while (packet_done < expected_done && watchdog < 2000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (packet_done != expected_done)
                $fatal(1, "packet timeout expected=%0d got=%0d", expected_done, packet_done);
        end
    endtask

    task expect_byte(input integer index, input [7:0] value);
        begin
            if (captured[index] !== value)
                $fatal(1, "payload byte[%0d]=%02h expected=%02h",
                       index, captured[index], value);
        end
    endtask

    integer i;
    reg [7:0] held_data;

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        // Two frames should be flushed by the latency timer.
        send_frame(29'h123, 0, 0, 8,
                   64'h8877665544332211, 64'h0102030405060708);
        send_frame(29'h18DAF110, 1, 0, 2,
                   64'h000000000000BBAA, 64'h1112131415161718);
        wait_packet(1);

        if (announced_length != 64 || announced_sequence != 0 || captured_count != 64)
            $fatal(1, "packet1 metadata len=%0d seq=%0d bytes=%0d",
                   announced_length, announced_sequence, captured_count);

        expect_byte(0, 8'h46); expect_byte(1, 8'h43);
        expect_byte(2, 8'h41); expect_byte(3, 8'h4e);
        expect_byte(4, 8'h01); expect_byte(5, 8'd16);
        expect_byte(6, 8'd24); expect_byte(7, 8'd2);
        expect_byte(8, 8'h00); expect_byte(9, 8'h00);
        expect_byte(10,8'h00); expect_byte(11,8'h00);

        // Record 0: ID 0x123, CRC flag, DLC 8, timestamp, DATA0..DATA7.
        expect_byte(16, 8'h00); expect_byte(17, 8'h00);
        expect_byte(18, 8'h01); expect_byte(19, 8'h23);
        expect_byte(20, 8'h04); expect_byte(21, 8'h08);
        for (i=0; i<8; i=i+1)
            expect_byte(24+i, 8'h01 + i);
        expect_byte(32,8'h11); expect_byte(33,8'h22);
        expect_byte(34,8'h33); expect_byte(35,8'h44);
        expect_byte(36,8'h55); expect_byte(37,8'h66);
        expect_byte(38,8'h77); expect_byte(39,8'h88);

        // Record 1: extended ID, IDE+CRC flags, DLC 2.
        expect_byte(40,8'h18); expect_byte(41,8'hda);
        expect_byte(42,8'hf1); expect_byte(43,8'h10);
        expect_byte(44,8'h05); expect_byte(45,8'h02);
        for (i=0; i<8; i=i+1)
            expect_byte(48+i, 8'h11 + i);
        expect_byte(56,8'haa); expect_byte(57,8'hbb);
        if (captured[63] !== 8'h00)
            $fatal(1, "record tail mismatch");

        $display("[PASS] UDP payload timeout flush and wire format");

        // A full batch of three frames should request immediately. Hold the
        // payload consumer off briefly and verify the first byte remains stable.
        send_frame(29'h201,0,0,0,64'h0,64'h21);
        send_frame(29'h202,0,0,0,64'h0,64'h22);
        send_frame(29'h203,0,0,0,64'h0,64'h23);

        while (!tx_valid)
            @(negedge clk);
        tx_ready = 0;
        held_data = tx_data;
        repeat (4) begin
            @(posedge clk); #1;
            if (!tx_valid || tx_data !== held_data)
                $fatal(1, "payload byte changed under backpressure");
        end
        tx_ready = 1;

        wait_packet(2);
        if (announced_length != 88 || announced_sequence != 1 || captured_count != 88)
            $fatal(1, "packet2 metadata len=%0d seq=%0d bytes=%0d",
                   announced_length, announced_sequence, captured_count);
        expect_byte(7, 8'd3);
        expect_byte(8, 8'h00); expect_byte(9, 8'h00);
        expect_byte(10,8'h00); expect_byte(11,8'h01);

        $display("[PASS] UDP payload full-batch flush, sequence, and backpressure");
        $finish;
    end
endmodule
