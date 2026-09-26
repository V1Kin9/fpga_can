`timescale 1ns/1ps
module tb_eth_frame_cdc_buffer;
    reg app_clk = 0;
    always #10 app_clk = ~app_clk;       // 50 MHz
    reg net_clk = 0;
    always #4 net_clk = ~net_clk;        // 125 MHz

    reg app_rst_n = 0;
    reg net_rst_n = 0;

    reg app_frame_valid = 0;
    wire app_frame_ready;
    reg [15:0] app_frame_length = 0;
    reg app_tx_valid = 0;
    wire app_tx_ready;
    reg [7:0] app_tx_data = 0;
    reg app_tx_last = 0;
    wire app_protocol_error;

    wire net_frame_valid;
    reg net_frame_ready = 0;
    wire [15:0] net_frame_length;
    wire net_tx_valid;
    reg net_tx_ready = 0;
    wire [7:0] net_tx_data;
    wire net_tx_last;

    integer saw_protocol_error = 0;

    eth_frame_cdc_buffer #(.MAX_FRAME_BYTES(32)) dut (
        .app_clk(app_clk), .app_rst_n(app_rst_n),
        .app_frame_valid(app_frame_valid), .app_frame_ready(app_frame_ready),
        .app_frame_length(app_frame_length),
        .app_tx_valid(app_tx_valid), .app_tx_ready(app_tx_ready),
        .app_tx_data(app_tx_data), .app_tx_last(app_tx_last),
        .app_protocol_error(app_protocol_error),
        .net_clk(net_clk), .net_rst_n(net_rst_n),
        .net_frame_valid(net_frame_valid), .net_frame_ready(net_frame_ready),
        .net_frame_length(net_frame_length),
        .net_tx_valid(net_tx_valid), .net_tx_ready(net_tx_ready),
        .net_tx_data(net_tx_data), .net_tx_last(net_tx_last)
    );

    always @(posedge app_clk)
        if (app_protocol_error)
            saw_protocol_error = saw_protocol_error + 1;

    task start_frame(input [15:0] length);
        integer watchdog;
        reg accepted;
        begin
            app_frame_length = length;
            app_frame_valid = 1;
            watchdog = 0;
            accepted = 0;
            while (!accepted && watchdog < 100) begin
                @(posedge app_clk);
                accepted = app_frame_ready;
                watchdog = watchdog + 1;
            end
            if (!accepted)
                $fatal(1, "CDC app frame-ready timeout");
            @(negedge app_clk);
            app_frame_valid = 0;
        end
    endtask

    task send_byte(input [7:0] value, input last);
        integer watchdog;
        reg accepted;
        begin
            app_tx_data = value;
            app_tx_last = last;
            app_tx_valid = 1;
            watchdog = 0;
            accepted = 0;
            while (!accepted && watchdog < 100) begin
                @(posedge app_clk);
                accepted = app_tx_ready;
                watchdog = watchdog + 1;
            end
            if (!accepted)
                $fatal(1, "CDC app byte-ready timeout");
            @(negedge app_clk);
            app_tx_valid = 0;
            app_tx_last = 0;
        end
    endtask

    task wait_net_frame(input [15:0] expected_length);
        integer watchdog;
        begin
            watchdog = 0;
            while (!net_frame_valid && watchdog < 200) begin
                @(negedge net_clk);
                watchdog = watchdog + 1;
            end
            if (!net_frame_valid || net_frame_length != expected_length)
                $fatal(1, "CDC net frame mismatch valid=%b len=%0d",
                       net_frame_valid, net_frame_length);
        end
    endtask

    integer i;
    integer recv_count;
    integer recv_watchdog;
    integer stalled_once;
    integer error_before;

    initial begin
        repeat (4) @(negedge app_clk);
        app_rst_n = 1;
        net_rst_n = 1;

        start_frame(16'd5);
        for (i=0; i<5; i=i+1)
            send_byte(8'hA0+i, i==4);

        wait_net_frame(16'd5);

        // Hold the consumer off and verify stable frame metadata.
        repeat (5) begin
            @(negedge net_clk);
            if (!net_frame_valid || net_frame_length != 5)
                $fatal(1, "CDC pending frame metadata changed");
        end

        net_frame_ready = 1;
        @(posedge net_clk);
        @(negedge net_clk);
        net_frame_ready = 0;

        recv_count = 0;
        recv_watchdog = 0;
        stalled_once = 0;
        while (recv_count < 5 && recv_watchdog < 20) begin
            @(negedge net_clk);
            net_tx_ready = (recv_count != 2 || stalled_once != 0);
            if (recv_count == 2 && stalled_once == 0)
                stalled_once = 1;
            @(posedge net_clk);
            if (!net_tx_valid)
                $fatal(1, "CDC stream ended before byte %0d", recv_count);
            if (net_tx_ready) begin
                if (net_tx_data !== (8'hA0 + recv_count))
                    $fatal(1, "CDC byte[%0d]=%02h", recv_count, net_tx_data);
                if (net_tx_last !== (recv_count == 4))
                    $fatal(1, "CDC last mismatch index=%0d last=%b",
                           recv_count, net_tx_last);
                recv_count = recv_count + 1;
            end else if (net_tx_data !== 8'hA2 || net_tx_last)
                $fatal(1, "CDC changed byte while backpressured");
            recv_watchdog = recv_watchdog + 1;
        end
        if (recv_count != 5 || stalled_once != 1)
            $fatal(1, "CDC receive/backpressure timeout");
        @(negedge net_clk);
        net_tx_ready = 0;

        // Allow acknowledgement to cross back before starting another frame.
        repeat (6) @(negedge app_clk);
        if (!app_frame_ready) begin
            app_frame_length = 4;
            #1;
            if (!app_frame_ready)
                $fatal(1, "CDC buffer did not become free after acknowledgement");
        end

        // Announce four bytes but terminate after two. The malformed frame must
        // be dropped and never become visible in the net domain.
        error_before = saw_protocol_error;
        start_frame(16'd4);
        send_byte(8'h11,0);
        send_byte(8'h22,1);
        repeat (6) @(negedge app_clk);
        repeat (10) @(negedge net_clk);
        if (saw_protocol_error != error_before + 1)
            $fatal(1, "CDC short frame did not raise one protocol error");
        if (net_frame_valid)
            $fatal(1, "CDC published malformed short frame");

        // An overlong frame must remain drainable through its final byte.
        // Otherwise an upstream producer waiting for ready can never finish.
        error_before = saw_protocol_error;
        start_frame(16'd2);
        send_byte(8'h31,0);
        send_byte(8'h32,0);
        send_byte(8'h33,0);
        send_byte(8'h34,1);
        repeat (6) @(negedge app_clk);
        if (saw_protocol_error != error_before + 1)
            $fatal(1, "CDC overlong frame did not raise one protocol error");
        if (net_frame_valid)
            $fatal(1, "CDC published malformed overlong frame");

        // An unsupported announced length must be accepted and drained too.
        error_before = saw_protocol_error;
        start_frame(16'd33);
        for (i=0; i<33; i=i+1)
            send_byte(i[7:0], i==32);
        repeat (6) @(negedge app_clk);
        if (saw_protocol_error != error_before + 1)
            $fatal(1, "CDC oversized frame did not raise one protocol error");
        if (net_frame_valid)
            $fatal(1, "CDC published oversized frame");

        // A zero-length frame has no bytes to drain and must be rejected at
        // the frame handshake without blocking the following valid frame.
        error_before = saw_protocol_error;
        start_frame(16'd0);
        repeat (3) @(negedge app_clk);
        if (saw_protocol_error != error_before + 1 || net_frame_valid)
            $fatal(1, "CDC zero-length frame was not rejected cleanly");

        // A correct frame must still cross after all malformed cases.
        start_frame(16'd1);
        send_byte(8'h5A,1);
        wait_net_frame(16'd1);
        net_frame_ready = 1;
        @(posedge net_clk);
        @(negedge net_clk);
        net_frame_ready = 0;
        net_tx_ready = 1;
        @(posedge net_clk);
        if (!net_tx_valid || net_tx_data !== 8'h5A || !net_tx_last)
            $fatal(1, "CDC did not recover after malformed frames");
        @(negedge net_clk);
        net_tx_ready = 0;

        $display("[PASS] Two-clock Ethernet frame CDC, backpressure, malformed-frame drain and recovery");
        $finish;
    end
endmodule
