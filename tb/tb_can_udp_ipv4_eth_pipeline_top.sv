`timescale 1ns/1ps
module tb_can_udp_ipv4_eth_pipeline_top;
    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    wire bus;
    wire can_tx;
    wire frame_valid;
    reg frame_ready = 1;
    wire [15:0] frame_length;
    wire tx_valid;
    reg tx_ready = 1;
    wire [7:0] tx_data;
    wire tx_last;
    wire [15:0] queue_level;
    wire frame_drop_event;

    can_frame_encoder gen(clk, bus);

    can_udp_ipv4_eth_pipeline_top #(
        .QUEUE_DEPTH(8),
        .MAX_FRAMES_PER_PACKET(2),
        .FLUSH_CYCLES(20),
        .FCAN_PROTOCOL_VERSION(1)
    ) dut (
        .clk_50m(clk), .rst_n(rst_n),
        .can_rx(bus), .can_tx(can_tx),
        .session_id(32'd0), .cdc_protocol_error(1'b0),
        .mac_underrun_count(16'd0),
        .eth_frame_valid(frame_valid), .eth_frame_ready(frame_ready),
        .eth_frame_length(frame_length),
        .eth_tx_valid(tx_valid), .eth_tx_ready(tx_ready),
        .eth_tx_data(tx_data), .eth_tx_last(tx_last),
        .queue_level(queue_level), .frame_drop_event(frame_drop_event)
    );

    reg [7:0] captured [0:127];
    integer captured_count = 0;
    integer frame_done = 0;
    integer announced_length = 0;
    reg saw_drop = 0;

    always @(posedge clk) begin
        if (can_tx !== 1'b1)
            $fatal(1, "CAN TX must remain recessive");
        if (frame_drop_event)
            saw_drop = 1;
        if (frame_valid && frame_ready) begin
            captured_count = 0;
            announced_length = frame_length;
        end
        if (tx_valid && tx_ready) begin
            captured[captured_count] = tx_data;
            captured_count = captured_count + 1;
            if (tx_last)
                frame_done = frame_done + 1;
        end
    end

    task expect_byte(input integer index, input [7:0] value);
        begin
            if (captured[index] !== value)
                $fatal(1, "pipeline eth byte[%0d]=%02h expected=%02h",
                       index, captured[index], value);
        end
    endtask

    integer watchdog;

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (1200) @(negedge clk);

        gen.build_standard(11'h321,0,8,64'h8877665544332211,0,0,0);
        gen.transmit(0);

        watchdog = 0;
        while (frame_done == 0 && watchdog < 10000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (frame_done != 1 || announced_length != 82 ||
            captured_count != 82 || saw_drop)
            $fatal(1, "end-to-end Ethernet frame done=%0d len=%0d bytes=%0d drop=%b",
                   frame_done, announced_length, captured_count, saw_drop);

        // L2/L3/L4 header checks.
        expect_byte(0,8'h02); expect_byte(5,8'h02);
        expect_byte(6,8'h02); expect_byte(11,8'h01);
        expect_byte(12,8'h08); expect_byte(13,8'h00);
        expect_byte(14,8'h45);
        expect_byte(16,8'h00); expect_byte(17,8'h44);
        // Sequence 0 is also the IPv4 identification.
        expect_byte(18,8'h00); expect_byte(19,8'h00);
        // Checksum for total length 68 and identification 0 = 0x5555.
        expect_byte(24,8'h55); expect_byte(25,8'h55);
        expect_byte(34,8'h13); expect_byte(35,8'h88);
        expect_byte(38,8'h00); expect_byte(39,8'h30);

        // FCAN begins at Ethernet offset 42.
        expect_byte(42,8'h46); expect_byte(43,8'h43);
        expect_byte(44,8'h41); expect_byte(45,8'h4e);
        expect_byte(49,8'h01); // FCAN frame count
        // CAN record begins at FCAN offset 16 => Ethernet offset 58.
        expect_byte(60,8'h03); expect_byte(61,8'h21);
        expect_byte(62,8'h04); expect_byte(63,8'h08);
        expect_byte(74,8'h11); expect_byte(75,8'h22);
        expect_byte(80,8'h77); expect_byte(81,8'h88);

        if (queue_level != 0)
            $fatal(1, "queue did not drain level=%0d", queue_level);

        $display("[PASS] CAN waveform to Ethernet/IPv4/UDP/FCAN frame stream");
        $finish;
    end
endmodule
