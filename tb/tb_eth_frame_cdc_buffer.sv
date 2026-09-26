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
        begin
            app_frame_length = length;
            app_frame_valid = 1;
            watchdog = 0;
            while (!app_frame_ready && watchdog < 100) begin
                @(negedge app_clk);
                watchdog = watchdog + 1;
            end
            if (!app_frame_ready)
                $fatal(1, "CDC app frame-ready timeout");
            @(posedge app_clk);
            @(negedge app_clk);
            app_frame_valid = 0;
        end
    endtask

    task send_byte(input [7:0] value, input last);
        integer watchdog;
        begin
            app_tx_data = value;
            app_tx_last = last;
            app_tx_valid = 1;
            watchdog = 0;
            while (!app_tx_ready && watchdog < 100) begin
                @(negedge app_clk);
                watchdog = watchdog + 1;
            end
            if (!app_tx_ready)
                $fatal(1, "CDC app byte-ready timeout");
            @(posedge app_clk);
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
        while (recv_count < 5) begin
            net_tx_ready = (recv_count != 2); // one-cycle backpressure
            @(negedge net_clk);
            if (net_tx_valid && net_tx_ready) begin
                if (net_tx_data !== (8'hA0 + recv_count))
                    $fatal(1, "CDC byte[%0d]=%02h", recv_count, net_tx_data);
                if (net_tx_last !== (recv_count == 4))
                    $fatal(1, "CDC last mismatch index=%0d last=%b",
                           recv_count, net_tx_last);
                recv_count = recv_count + 1;
            end
            if (recv_count == 2) begin
                // Release after one stalled cycle.
                net_tx_ready = 1;
            end
        end
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
        start_frame(16'd4);
        send_byte(8'h11,0);
        send_byte(8'h22,1);
        repeat (6) @(negedge app_clk);
        repeat (10) @(negedge net_clk);
        if (saw_protocol_error == 0)
            $fatal(1, "CDC malformed frame did not raise protocol error");
        if (net_frame_valid)
            $fatal(1, "CDC published malformed short frame");

        $display("[PASS] Two-clock Ethernet frame CDC, backpressure, malformed-frame drop");
        $finish;
    end
endmodule
