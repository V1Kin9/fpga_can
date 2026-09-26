`timescale 1ns/1ps
module tb_can_udp_pipeline_top;
    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    wire bus;
    wire can_tx;

    wire packet_valid;
    reg packet_ready = 1;
    wire [15:0] packet_length;
    wire [31:0] packet_sequence;
    wire tx_valid;
    reg tx_ready = 1;
    wire [7:0] tx_data;
    wire tx_last;
    wire [15:0] queue_level;
    wire frame_drop_event;

    can_frame_encoder gen(clk, bus);

    can_udp_pipeline_top #(
        .QUEUE_DEPTH(8),
        .MAX_FRAMES_PER_PACKET(2),
        .FLUSH_CYCLES(20),
        .FCAN_PROTOCOL_VERSION(1)
    ) dut (
        .clk_50m(clk),
        .rst_n(rst_n),
        .can_rx(bus),
        .session_id(32'd0), .cdc_protocol_error(1'b0),
        .mac_underrun_count(16'd0),
        .can_tx(can_tx),
        .packet_valid(packet_valid),
        .packet_ready(packet_ready),
        .packet_length(packet_length),
        .packet_sequence(packet_sequence),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_data(tx_data),
        .tx_last(tx_last),
        .queue_level(queue_level),
        .frame_drop_event(frame_drop_event)
    );

    reg [7:0] captured [0:127];
    integer captured_count = 0;
    integer packet_done = 0;
    integer announced_length = 0;
    reg [31:0] announced_sequence = 0;
    reg saw_drop = 0;

    always @(posedge clk) begin
        if (can_tx !== 1'b1)
            $fatal(1, "pipeline CAN TX must remain recessive");
        if (frame_drop_event)
            saw_drop = 1;
        if (packet_valid && packet_ready) begin
            captured_count = 0;
            announced_length = packet_length;
            announced_sequence = packet_sequence;
        end
        if (tx_valid && tx_ready) begin
            captured[captured_count] = tx_data;
            captured_count = captured_count + 1;
            if (tx_last)
                packet_done = packet_done + 1;
        end
    end

    task wait_packet(input integer expected_done);
        integer watchdog;
        begin
            watchdog = 0;
            while (packet_done < expected_done && watchdog < 5000) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (packet_done != expected_done)
                $fatal(1, "pipeline packet timeout got=%0d expected=%0d",
                       packet_done, expected_done);
        end
    endtask

    task expect_byte(input integer index, input [7:0] value);
        begin
            if (captured[index] !== value)
                $fatal(1, "pipeline payload[%0d]=%02h expected=%02h",
                       index, captured[index], value);
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (1200) @(negedge clk);

        gen.build_standard(11'h321, 0, 8, 64'h8877665544332211, 0, 0, 0);
        gen.transmit(0);
        wait_packet(1);

        if (announced_length != 40 || announced_sequence != 0 ||
            captured_count != 40 || saw_drop)
            $fatal(1, "pipeline metadata len=%0d seq=%0d bytes=%0d drop=%b",
                   announced_length, announced_sequence, captured_count, saw_drop);

        expect_byte(0,8'h46); expect_byte(1,8'h43);
        expect_byte(2,8'h41); expect_byte(3,8'h4e);
        expect_byte(4,8'h01); expect_byte(5,8'd16);
        expect_byte(6,8'd24); expect_byte(7,8'd1);

        expect_byte(16,8'h00); expect_byte(17,8'h00);
        expect_byte(18,8'h03); expect_byte(19,8'h21);
        expect_byte(20,8'h04); // CRC-valid standard data frame
        expect_byte(21,8'h08);
        expect_byte(32,8'h11); expect_byte(33,8'h22);
        expect_byte(34,8'h33); expect_byte(35,8'h44);
        expect_byte(36,8'h55); expect_byte(37,8'h66);
        expect_byte(38,8'h77); expect_byte(39,8'h88);

        if (queue_level != 0)
            $fatal(1, "queue did not drain level=%0d", queue_level);

        $display("[PASS] CAN waveform to queued FCAN UDP payload pipeline");
        $finish;
    end
endmodule
