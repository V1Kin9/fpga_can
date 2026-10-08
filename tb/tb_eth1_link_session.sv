`timescale 1ns/1ps
module tb_eth1_link_session;
    reg clk=0, core_rst_n=0, phy_ready=0;
    always #10 clk=~clk;
    wire pipeline_rst_n;
    wire [31:0] session_id;
    reg frame_valid=0, tx_ready=1;
    reg [28:0] frame_id=0;
    wire frame_ready, packet_valid, tx_valid, tx_last;
    wire [7:0] tx_data;
    reg [7:0] captured[0:51];
    integer pos=0, packets=0;

    // A non-default seed also exercises wrap without millions of resets.
    eth1_link_session #(.INITIAL_SESSION(32'hfffffffe)) dut (
        .clk_50m(clk), .core_rst_n(core_rst_n),
        .phy_ready_125m(phy_ready), .pipeline_rst_n(pipeline_rst_n),
        .session_id(session_id)
    );
    can_udp_payload_packetizer #(
        .MAX_FRAMES(1), .FLUSH_CYCLES(4), .FCAN_PROTOCOL_VERSION(2)
    ) packetizer (
        .clk(clk), .rst_n(pipeline_rst_n), .session_id(session_id),
        .frame_valid(frame_valid), .frame_ready(frame_ready),
        .frame_id(frame_id), .frame_ide(1'b0), .frame_rtr(1'b0),
        .frame_dlc(4'd0), .frame_data(64'd0),
        .frame_timestamp(64'd1000), .frame_crc_ok(1'b1),
        .error_valid(1'b0), .error_ready(), .error_code(8'd0),
        .error_timestamp(64'd0), .status_valid(1'b0), .status_ready(),
        .status_flags(8'd0), .status_queue_level(8'd0),
        .status_queue_high_watermark(8'd0), .status_uptime_ticks(64'd0),
        .status_counters(128'd0), .packet_valid(packet_valid),
        .packet_ready(1'b1), .packet_length(), .packet_sequence(),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_data(tx_data),
        .tx_last(tx_last)
    );
    always @(posedge clk or negedge pipeline_rst_n) begin
        if (!pipeline_rst_n) pos=0;
        else if (tx_valid && tx_ready) begin
            captured[pos]=tx_data;
            pos=pos+1;
            if (tx_last) begin
                if (pos!=52) $fatal(1,"FCAN packet length %0d",pos);
                pos=0;
                packets=packets+1;
            end
        end
    end
    task queue_frame(input reg [28:0] id);
        begin
            @(negedge clk); frame_id=id; frame_valid=1;
            do @(posedge clk); while (!pipeline_rst_n || !frame_ready);
            @(negedge clk); frame_valid=0;
        end
    endtask
    task send_packet(input reg [31:0] seq, input reg [31:0] session,
                     input reg [28:0] id);
        integer target;
        begin
            target=packets+1;
            queue_frame(id);
            wait(packets==target); @(negedge clk);
            if ({captured[8],captured[9],captured[10],captured[11]}!==seq)
                $fatal(1,"sequence did not restart/advance correctly");
            if ({captured[12],captured[13],captured[14],captured[15]}!==session)
                $fatal(1,"session changed too late or stale session leaked");
            if ({captured[24],captured[25],captured[26],captured[27]}!=={3'b0,id})
                $fatal(1,"stale pre-reset frame leaked");
        end
    endtask
    task drop_link(input reg [31:0] next_session);
        begin
            @(negedge clk); phy_ready=0;
            repeat(8) @(negedge clk);
            if (pipeline_rst_n!==0 || session_id!==next_session)
                $fatal(1,"link loss must reset pipeline and advance session once");
            repeat(8) @(negedge clk);
            if (session_id!==next_session)
                $fatal(1,"session advanced repeatedly while link stayed down");
        end
    endtask
    task restore_link;
        begin
            @(negedge clk); phy_ready=1;
            wait(pipeline_rst_n); repeat(4) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); core_rst_n=1;
        repeat(8) @(negedge clk);
        if (pipeline_rst_n!==0 || session_id!==32'hfffffffe)
            $fatal(1,"startup without link must preserve seed and hold reset");
        restore_link;
        send_packet(0,32'hfffffffe,29'h100);
        send_packet(1,32'hfffffffe,29'h101);
        drop_link(32'hffffffff);
        restore_link;
        // Both packets use the new ID; a receiver can lose zero and still
        // recognize sequence one as a new session (host regression covers it).
        send_packet(0,32'hffffffff,29'h102);
        send_packet(1,32'hffffffff,29'h103);
        @(negedge clk); tx_ready=0;
        queue_frame(29'h777);
        wait(tx_valid);
        drop_link(32'h00000000);
        @(negedge clk); tx_ready=1;
        restore_link;
        send_packet(0,32'h00000000,29'h104);
        // Even the shortest sampled low pulse must change the session before
        // the first post-reset packet. It must not leave seq0 under the old ID.
        @(negedge clk); phy_ready=0;
        @(negedge clk); phy_ready=1;
        wait(!pipeline_rst_n);
        // Offer a frame during reset so it handshakes at the earliest possible
        // release, instead of masking a late session update with an idle gap.
        send_packet(0,32'h00000001,29'h105);
        // Deliberately document the boundary: a full core reset reuses seed.
        @(negedge clk); core_rst_n=0;
        repeat(4) @(negedge clk);
        if (session_id!==32'hfffffffe || pipeline_rst_n!==0)
            $fatal(1,"core reset must restore configured bench seed");
        core_rst_n=1;
        wait(pipeline_rst_n); repeat(4) @(negedge clk);
        send_packet(0,32'hfffffffe,29'h106);
        $display("[PASS] link reset session identity, packet abort, sequence restart, wrap and boot boundary");
        $finish;
    end
    initial begin #100000; $fatal(1,"ETH1 link-session timeout"); end
endmodule
