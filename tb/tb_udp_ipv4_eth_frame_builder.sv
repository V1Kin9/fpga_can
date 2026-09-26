`timescale 1ns/1ps
module tb_udp_ipv4_eth_frame_builder;
    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg packet_valid = 0;
    wire packet_ready;
    reg [15:0] packet_length = 16'd40;
    reg [31:0] packet_sequence = 32'h00001234;

    reg payload_valid = 0;
    wire payload_ready;
    reg [7:0] payload_data = 0;
    reg payload_last = 0;

    wire frame_valid;
    reg frame_ready = 1;
    wire [15:0] frame_length;
    wire tx_valid;
    reg tx_ready = 1;
    wire [7:0] tx_data;
    wire tx_last;

    reg [7:0] captured [0:127];
    integer captured_count = 0;
    integer frame_done = 0;
    integer payload_index = 0;

    udp_ipv4_eth_frame_builder dut (
        .clk(clk), .rst_n(rst_n),
        .packet_valid(packet_valid), .packet_ready(packet_ready),
        .packet_length(packet_length), .packet_sequence(packet_sequence),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_data(payload_data), .payload_last(payload_last),
        .frame_valid(frame_valid), .frame_ready(frame_ready),
        .frame_length(frame_length),
        .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx_data(tx_data), .tx_last(tx_last)
    );

    always @(posedge clk) begin
        if (tx_valid && tx_ready) begin
            captured[captured_count] = tx_data;
            captured_count = captured_count + 1;
            if (tx_last)
                frame_done = frame_done + 1;
        end
    end

    always @(*) begin
        payload_valid = (dut.state == 3'd4) && (payload_index < 40);
        payload_data = payload_index[7:0];
        payload_last = (payload_index == 39);
    end

    always @(posedge clk) begin
        if (payload_valid && payload_ready)
            payload_index <= payload_index + 1;
    end

    task expect_byte(input integer index, input [7:0] value);
        begin
            if (captured[index] !== value)
                $fatal(1, "eth byte[%0d]=%02h expected=%02h",
                       index, captured[index], value);
        end
    endtask

    integer watchdog;
    integer i;
    reg [7:0] held_data;

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        packet_valid = 1;
        @(posedge clk); #1;
        if (!frame_valid || frame_length != 82)
            $fatal(1, "frame request metadata valid=%b len=%0d",
                   frame_valid, frame_length);
        @(negedge clk);
        packet_valid = 0;

        // Exercise header backpressure.
        while (!tx_valid)
            @(negedge clk);
        tx_ready = 0;
        held_data = tx_data;
        repeat (3) begin
            @(posedge clk); #1;
            if (!tx_valid || tx_data !== held_data)
                $fatal(1, "Ethernet header changed under backpressure");
        end
        tx_ready = 1;

        watchdog = 0;
        while (frame_done == 0 && watchdog < 1000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (frame_done != 1 || captured_count != 82)
            $fatal(1, "Ethernet frame timeout/count=%0d bytes=%0d",
                   frame_done, captured_count);

        // Ethernet II
        expect_byte(0,8'h02); expect_byte(1,8'h00); expect_byte(2,8'h00);
        expect_byte(3,8'h00); expect_byte(4,8'h00); expect_byte(5,8'h02);
        expect_byte(6,8'h02); expect_byte(7,8'h00); expect_byte(8,8'h00);
        expect_byte(9,8'h00); expect_byte(10,8'h00); expect_byte(11,8'h01);
        expect_byte(12,8'h08); expect_byte(13,8'h00);

        // IPv4: total length 68, identification 0x1234, DF, TTL 64, UDP.
        expect_byte(14,8'h45); expect_byte(15,8'h00);
        expect_byte(16,8'h00); expect_byte(17,8'h44);
        expect_byte(18,8'h12); expect_byte(19,8'h34);
        expect_byte(20,8'h40); expect_byte(21,8'h00);
        expect_byte(22,8'h40); expect_byte(23,8'h11);
        expect_byte(24,8'h43); expect_byte(25,8'h21);
        expect_byte(26,8'hc0); expect_byte(27,8'ha8);
        expect_byte(28,8'h32); expect_byte(29,8'h02);
        expect_byte(30,8'hc0); expect_byte(31,8'ha8);
        expect_byte(32,8'h32); expect_byte(33,8'h01);

        // UDP: ports 5000, length 48, zero checksum (valid for IPv4).
        expect_byte(34,8'h13); expect_byte(35,8'h88);
        expect_byte(36,8'h13); expect_byte(37,8'h88);
        expect_byte(38,8'h00); expect_byte(39,8'h30);
        expect_byte(40,8'h00); expect_byte(41,8'h00);

        for (i=0; i<40; i=i+1)
            expect_byte(42+i, i[7:0]);

        $display("[PASS] Ethernet II + IPv4 checksum + UDP header + payload framing");
        $finish;
    end
endmodule
