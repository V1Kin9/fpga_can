`timescale 1ns/1ps
module tb_fcan_v2;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0;
    reg [31:0] session_id=32'h12345678;
    reg frame_valid=0, error_valid=0, status_valid=0;
    wire frame_ready, error_ready, status_ready;
    reg [28:0] frame_id=29'h18DAF110;
    reg frame_ide=1, frame_rtr=0, frame_crc_ok=1;
    reg [3:0] frame_dlc=4'd15;
    reg [63:0] frame_data=64'h0807060504030201;
    reg [63:0] frame_timestamp=64'h1020304050607080;
    reg [7:0] error_code=8'h02;
    reg [63:0] error_timestamp=64'h1112131415161718;
    reg [7:0] status_flags=8'h01, status_queue_level=8'd4;
    reg [7:0] status_queue_high_watermark=8'd12;
    reg [63:0] status_uptime_ticks=64'h2122232425262728;
    reg [127:0] status_counters=128'h00010002000300040005000600070008;
    wire packet_valid, tx_valid, tx_last;
    wire [15:0] packet_length;
    wire [31:0] packet_sequence;
    wire [7:0] tx_data;
    reg tx_ready=1;
    reg [7:0] captured[0:511];
    integer length=0, packets=0;
    integer announced_length=0;
    can_udp_payload_packetizer #(
        .MAX_FRAMES(3), .FLUSH_CYCLES(100), .FCAN_PROTOCOL_VERSION(2)
    ) dut (
        .clk(clk), .rst_n(rst_n), .session_id(session_id),
        .frame_valid(frame_valid), .frame_ready(frame_ready),
        .frame_id(frame_id), .frame_ide(frame_ide), .frame_rtr(frame_rtr),
        .frame_dlc(frame_dlc), .frame_data(frame_data),
        .frame_timestamp(frame_timestamp), .frame_crc_ok(frame_crc_ok),
        .error_valid(error_valid), .error_ready(error_ready),
        .error_code(error_code), .error_timestamp(error_timestamp),
        .status_valid(status_valid), .status_ready(status_ready),
        .status_flags(status_flags), .status_queue_level(status_queue_level),
        .status_queue_high_watermark(status_queue_high_watermark),
        .status_uptime_ticks(status_uptime_ticks), .status_counters(status_counters),
        .packet_valid(packet_valid), .packet_ready(1'b1),
        .packet_length(packet_length), .packet_sequence(packet_sequence),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_data(tx_data), .tx_last(tx_last)
    );
    always @(posedge clk) if (rst_n && tx_valid && tx_ready) begin
        captured[length]=tx_data;
        length=length+1;
        if (tx_last) packets=packets+1;
    end
    always @(posedge clk) if (rst_n && packet_valid) announced_length=packet_length;
    task check(input integer offset, input reg [7:0] value);
        begin if(captured[offset] !== value)
            $fatal(1,"offset %0d got %02x expected %02x",offset,captured[offset],value);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        @(negedge clk); frame_valid=1;
        do @(negedge clk); while (!frame_ready);
        frame_valid=0; error_valid=1;
        do @(negedge clk); while (!error_ready);
        error_valid=0; status_valid=1;
        do @(negedge clk); while (!status_ready);
        status_valid=0;
        wait(packets==1); @(negedge clk);
        if(length!=116 || announced_length!=116 || packet_sequence!=1)
            $fatal(1,"packet length/sequence %0d/%0d/%0d",length,announced_length,packet_sequence);
        check(4,2); check(5,20); check(6,32); check(7,3);
        check(12,8'h12); check(13,8'h34); check(14,8'h56); check(15,8'h78);
        check(20,0); check(21,8'h05); check(22,15); check(24,8'h18); check(25,8'hDA);
        check(36,1); check(43,8'h08); check(44,0); check(51,0);
        check(52,1); check(53,2); check(60,8'h11); check(67,8'h18);
        check(84,2); check(85,1); check(86,4); check(87,12);
        check(100,0); check(101,1); check(114,0); check(115,8);
        $display("[PASS] FCAN v2 frame/error/status wire layout and session");
        length=0;
        // Abort a partially aggregated packet before changing session.
        @(negedge clk); frame_valid=1;
        do @(negedge clk); while (!frame_ready);
        frame_valid=0;
        @(negedge clk); rst_n=0; session_id=32'h87654321;
        repeat(4) @(negedge clk); rst_n=1;
        @(negedge clk); frame_valid=1;
        do @(negedge clk); while (!frame_ready);
        frame_valid=0;
        wait(packets==2); @(negedge clk);
        if(length!=52) $fatal(1,"stale pre-reset record leaked");
        check(8,0); check(12,8'h87); check(13,8'h65);
        $display("[PASS] FCAN v2 reset restarts sequence with externally changed session");
        $finish;
    end
    initial begin #1000000; $fatal(1,"FCAN v2 timeout"); end
endmodule
