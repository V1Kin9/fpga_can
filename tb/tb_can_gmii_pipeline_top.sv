`timescale 1ns/1ps
module tb_can_gmii_pipeline_top;
    localparam integer FRAME_COUNT = 37;
    localparam integer GMII_BYTES_PER_FRAME = 94;

    reg clk_50m = 0;
    always #10 clk_50m = ~clk_50m;
    reg gmii_clk_125m = 0;
    always #4 gmii_clk_125m = ~gmii_clk_125m;

    reg rst_n = 0;
    wire can_rx;
    wire can_tx;
    wire gmii_tx_en;
    wire gmii_tx_er;
    wire [7:0] gmii_txd;
    wire [15:0] queue_level;
    wire can_frame_drop_event;
    wire cdc_protocol_error;
    wire mac_underrun_error;

    can_frame_encoder gen(clk_50m, can_rx);
    can_gmii_pipeline_top #(
        .QUEUE_DEPTH(64),
        .MAX_FRAMES_PER_PACKET(1),
        .FLUSH_CYCLES(1)
    ) dut (
        .clk_50m(clk_50m), .gmii_clk_125m(gmii_clk_125m),
        .rst_n(rst_n), .can_rx(can_rx), .can_tx(can_tx),
        .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .gmii_txd(gmii_txd), .queue_level(queue_level),
        .can_frame_drop_event(can_frame_drop_event),
        .cdc_protocol_error(cdc_protocol_error),
        .mac_underrun_error(mac_underrun_error)
    );

    reg [28:0] expected_id [0:FRAME_COUNT-1];
    reg expected_ide [0:FRAME_COUNT-1];
    reg expected_rtr [0:FRAME_COUNT-1];
    reg [3:0] expected_dlc [0:FRAME_COUNT-1];
    reg [63:0] expected_data [0:FRAME_COUNT-1];
    reg [63:0] expected_timestamp [0:FRAME_COUNT-1];
    reg [7:0] expected [0:GMII_BYTES_PER_FRAME-1];
    reg [7:0] actual [0:GMII_BYTES_PER_FRAME-1];

    // Independent 50 MHz tick reference with the same reset epoch as the
    // receiver. The SOF wire edge precedes its two-FF synchronized detection
    // by two counted rising edges; no DUT timestamp value enters the golden.
    wire rx_reset_n = dut.u_app_pipeline.u_can_udp_pipeline.rst_sync_n;
    reg [63:0] reference_ticks = 0;
    always @(posedge clk_50m or negedge rx_reset_n) begin
        if (!rx_reset_n)
            reference_ticks <= 0;
        else
            reference_ticks <= reference_ticks + 1'b1;
    end

    reg expect_sof = 0;
    integer sof_index = 0;
    always @(negedge can_rx) begin
        if (expect_sof) begin
            expected_timestamp[sof_index] = reference_ticks + 2;
            expect_sof = 0;
        end
    end

    integer sent_can_count = 0;
    task send_standard(input reg [10:0] id, input reg rtr,
                       input reg [3:0] dlc, input reg [63:0] data);
        begin
            if (sent_can_count >= FRAME_COUNT)
                $fatal(1, "CAN stimulus array overflow");
            expected_id[sent_can_count] = {18'd0, id};
            expected_ide[sent_can_count] = 0;
            expected_rtr[sent_can_count] = rtr;
            expected_dlc[sent_can_count] = dlc;
            expected_data[sent_can_count] = rtr ? 64'd0 : data;
            sof_index = sent_can_count;
            expect_sof = 1;
            gen.build_standard(id, rtr, dlc, data, 0, 0, 0);
            gen.transmit(0);
            if (expect_sof)
                $fatal(1, "standard SOF edge not observed");
            sent_can_count = sent_can_count + 1;
        end
    endtask

    task send_extended(input reg [28:0] id, input reg [3:0] dlc,
                       input reg [63:0] data);
        begin
            if (sent_can_count >= FRAME_COUNT)
                $fatal(1, "CAN stimulus array overflow");
            expected_id[sent_can_count] = id;
            expected_ide[sent_can_count] = 1;
            expected_rtr[sent_can_count] = 0;
            expected_dlc[sent_can_count] = dlc;
            expected_data[sent_can_count] = data;
            sof_index = sent_can_count;
            expect_sof = 1;
            gen.build_extended(id, 0, dlc, data);
            gen.transmit(0);
            if (expect_sof)
                $fatal(1, "extended SOF edge not observed");
            sent_can_count = sent_can_count + 1;
        end
    endtask

    // Reference FCS uses the normal 0x04C11DB7 polynomial and an MSB-first
    // shift register, unlike the DUT's reflected 0xEDB88320 implementation.
    // The Ethernet wire presents the final bit-reflected result low byte first.
    function [31:0] reverse32(input [31:0] value);
        integer bit_index;
        begin
            for (bit_index=0; bit_index<32; bit_index=bit_index+1)
                reverse32[bit_index] = value[31-bit_index];
        end
    endfunction

    task build_expected(input integer frame_index);
        integer p;
        integer i;
        integer bit_index;
        reg [31:0] crc;
        reg [31:0] fcs;
        reg feedback;
        reg [15:0] ip_checksum;
        begin
            p = 0;
            for (i=0; i<7; i=i+1) begin expected[p] = 8'h55; p=p+1; end
            expected[p] = 8'hD5; p=p+1;

            // Ethernet II: destination 02:00:00:00:00:02, source ...:01.
            expected[p]=8'h02; p=p+1;
            for (i=0; i<4; i=i+1) begin expected[p]=0; p=p+1; end
            expected[p]=8'h02; p=p+1;
            expected[p]=8'h02; p=p+1;
            for (i=0; i<4; i=i+1) begin expected[p]=0; p=p+1; end
            expected[p]=8'h01; p=p+1;
            expected[p]=8'h08; p=p+1; expected[p]=8'h00; p=p+1;

            // IPv4: fixed 68-byte datagram, identification = FCAN sequence.
            ip_checksum = 16'h5555 - frame_index;
            expected[p]=8'h45; p=p+1; expected[p]=0; p=p+1;
            expected[p]=0; p=p+1; expected[p]=8'd68; p=p+1;
            expected[p]=(frame_index >> 8) & 8'hff; p=p+1;
            expected[p]=frame_index & 8'hff; p=p+1;
            expected[p]=8'h40; p=p+1; expected[p]=0; p=p+1;
            expected[p]=8'd64; p=p+1; expected[p]=8'd17; p=p+1;
            expected[p]=ip_checksum[15:8]; p=p+1;
            expected[p]=ip_checksum[7:0]; p=p+1;
            expected[p]=8'hc0; p=p+1; expected[p]=8'ha8; p=p+1;
            expected[p]=8'h32; p=p+1; expected[p]=8'h02; p=p+1;
            expected[p]=8'hc0; p=p+1; expected[p]=8'ha8; p=p+1;
            expected[p]=8'h32; p=p+1; expected[p]=8'h01; p=p+1;

            // UDP: source/destination 5000, length 48, checksum disabled.
            expected[p]=8'h13; p=p+1; expected[p]=8'h88; p=p+1;
            expected[p]=8'h13; p=p+1; expected[p]=8'h88; p=p+1;
            expected[p]=0; p=p+1; expected[p]=8'd48; p=p+1;
            expected[p]=0; p=p+1; expected[p]=0; p=p+1;

            // FCAN version 1, one 24-byte record, sequence = frame_index.
            expected[p]=8'h46; p=p+1; expected[p]=8'h43; p=p+1;
            expected[p]=8'h41; p=p+1; expected[p]=8'h4e; p=p+1;
            expected[p]=1; p=p+1; expected[p]=16; p=p+1;
            expected[p]=24; p=p+1; expected[p]=1; p=p+1;
            for (i=3; i>=0; i=i-1) begin
                expected[p]=(frame_index >> (i*8)) & 8'hff; p=p+1;
            end
            for (i=0; i<4; i=i+1) begin expected[p]=0; p=p+1; end

            // CAN record: ID, IDE/RTR/CRC_OK, raw DLC, timestamp, DATA0..7.
            expected[p]={3'b000, expected_id[frame_index][28:24]}; p=p+1;
            expected[p]=expected_id[frame_index][23:16]; p=p+1;
            expected[p]=expected_id[frame_index][15:8]; p=p+1;
            expected[p]=expected_id[frame_index][7:0]; p=p+1;
            expected[p]={5'b00000, 1'b1, expected_rtr[frame_index],
                         expected_ide[frame_index]}; p=p+1;
            expected[p]={4'b0000, expected_dlc[frame_index]}; p=p+1;
            expected[p]=0; p=p+1; expected[p]=0; p=p+1;
            for (i=7; i>=0; i=i-1) begin
                expected[p]=(expected_timestamp[frame_index] >> (i*8)) & 8'hff;
                p=p+1;
            end
            for (i=0; i<8; i=i+1) begin
                expected[p]=(expected_data[frame_index] >> (i*8)) & 8'hff;
                p=p+1;
            end
            if (p != 90)
                $fatal(1, "golden MAC-client frame size %0d", p);

            crc = 32'hffffffff;
            for (i=8; i<90; i=i+1) begin
                for (bit_index=0; bit_index<8; bit_index=bit_index+1) begin
                    feedback = crc[31] ^ expected[i][bit_index];
                    crc = {crc[30:0], 1'b0};
                    if (feedback)
                        crc = crc ^ 32'h04c11db7;
                end
            end
            fcs = reverse32(~crc);
            for (i=0; i<4; i=i+1) begin
                expected[p]=(fcs >> (i*8)) & 8'hff;
                p=p+1;
            end
            if (p != GMII_BYTES_PER_FRAME)
                $fatal(1, "golden GMII frame size %0d", p);
        end
    endtask

    integer received_packets = 0;
    integer active_bytes = 0;
    integer idle_bytes = 0;
    reg in_packet = 0;
    integer k;
    always @(negedge gmii_clk_125m) begin
        if (rst_n) begin
            if (gmii_tx_er || mac_underrun_error)
                $fatal(1, "GMII TX error/underrun");
            if (gmii_tx_en) begin
                if (!in_packet) begin
                    if (received_packets != 0 && idle_bytes < 12)
                        $fatal(1, "GMII IFG only %0d byte-times", idle_bytes);
                    in_packet = 1;
                    active_bytes = 0;
                end
                if (active_bytes >= GMII_BYTES_PER_FRAME)
                    $fatal(1, "GMII frame too long");
                actual[active_bytes] = gmii_txd;
                active_bytes = active_bytes + 1;
            end else if (in_packet) begin
                if (received_packets >= FRAME_COUNT)
                    $fatal(1, "duplicate GMII frame");
                build_expected(received_packets);
                if (active_bytes != GMII_BYTES_PER_FRAME)
                    $fatal(1, "GMII frame %0d has %0d bytes",
                           received_packets, active_bytes);
                for (k=0; k<GMII_BYTES_PER_FRAME; k=k+1)
                    if (actual[k] !== expected[k])
                        $fatal(1, "GMII frame %0d byte %0d actual=%02h expected=%02h",
                               received_packets, k, actual[k], expected[k]);
                received_packets = received_packets + 1;
                in_packet = 0;
                idle_bytes = 1;
            end else if (received_packets != 0) begin
                idle_bytes = idle_bytes + 1;
            end
        end
    end

    reg saw_queue_nonempty = 0;
    reg saw_cdc_busy = 0;
    always @(posedge clk_50m) begin
        if (rst_n) begin
            if (can_tx !== 1'b1 || can_frame_drop_event || cdc_protocol_error)
                $fatal(1, "CAN TX/drop/CDC protocol error");
            if (queue_level != 0)
                saw_queue_nonempty = 1;
            if (dut.u_frame_cdc.req_toggle != dut.u_frame_cdc.ack_sync2)
                saw_cdc_busy = 1;
        end
    end

    task wait_packets(input integer target);
        integer watchdog;
        begin
            watchdog = 0;
            while (received_packets < target && watchdog < 100000) begin
                @(negedge gmii_clk_125m);
                watchdog = watchdog + 1;
            end
            if (received_packets != target)
                $fatal(1, "GMII packet count %0d expected %0d",
                       received_packets, target);
        end
    endtask

    integer frame_index;
    initial begin
        repeat (5) @(negedge clk_50m);
        rst_n = 1;
        repeat (1200) @(negedge clk_50m);

        send_standard(11'h321, 0, 8, 64'h8877665544332211);
        send_extended(29'h18daf110, 2, 64'h000000000000bbaa);
        send_standard(11'h123, 0, 0, 0);
        send_standard(11'h456, 0, 15, 64'h8070605040302010);
        send_standard(11'h789, 1, 4, 0);
        wait_packets(5);

        // Keep both clocks running while the GMII side declines the next
        // complete frame. This produces a busy CDC and a nonempty CAN queue.
        @(negedge clk_50m);
        saw_cdc_busy = 0;
        saw_queue_nonempty = 0;
        force dut.net_frame_ready = 1'b0;
        for (frame_index=0; frame_index<32; frame_index=frame_index+1)
            send_standard(11'h100 + frame_index, 0, 8,
                          64'h8877665544332200 | frame_index);
        if (!saw_cdc_busy || !saw_queue_nonempty)
            $fatal(1, "CDC/queue backpressure was not exercised");
        release dut.net_frame_ready;
        wait_packets(FRAME_COUNT);
        repeat (500) @(negedge gmii_clk_125m);
        if (queue_level != 0 || received_packets != sent_can_count || in_packet ||
            dut.app_frame_valid || dut.net_frame_valid)
            $fatal(1, "GMII drain/order mismatch packets=%0d CAN=%0d queue=%0d",
                   received_packets, sent_can_count, queue_level);

        $display("[PASS] 37 CAN waveforms to exact GMII bytes/FCS/IFG across 50/125 MHz CDC; 32-frame backlog ordered");
        $finish;
    end
endmodule
