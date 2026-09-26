`timescale 1ns/1ps
module tb_can_diagnostics;
    reg clk=0, rst_n=0, frame_valid=0, error_valid=0;
    reg [7:0] error_code=0;
    reg [63:0] event_timestamp=0;
    reg queue_drop_event=0, cdc_protocol_error=0;
    reg [15:0] mac_underrun_count=7, queue_level=0;
    reg diagnostic_error_ready=0, diagnostic_status_ready=0;
    wire diagnostic_error_valid, diagnostic_status_valid;
    wire [7:0] diagnostic_error_code, status_flags, status_queue_level;
    wire [7:0] status_queue_high_watermark;
    wire [63:0] diagnostic_error_timestamp, status_uptime_ticks;
    wire [127:0] status_counters;
    always #10 clk=~clk;
    can_diagnostics #(.STATUS_INTERVAL_CYCLES(50)) dut (
        .clk(clk),.rst_n(rst_n),.frame_valid(frame_valid),
        .error_valid(error_valid),.error_code(error_code),
        .event_timestamp(event_timestamp),.queue_drop_event(queue_drop_event),
        .cdc_protocol_error(cdc_protocol_error),.mac_underrun_count(mac_underrun_count),
        .queue_level(queue_level),.diagnostic_error_valid(diagnostic_error_valid),
        .diagnostic_error_ready(diagnostic_error_ready),
        .diagnostic_error_code(diagnostic_error_code),
        .diagnostic_error_timestamp(diagnostic_error_timestamp),
        .diagnostic_status_valid(diagnostic_status_valid),
        .diagnostic_status_ready(diagnostic_status_ready),
        .status_flags(status_flags),.status_queue_level(status_queue_level),
        .status_queue_high_watermark(status_queue_high_watermark),
        .status_uptime_ticks(status_uptime_ticks),.status_counters(status_counters)
    );
    task pulse(input [7:0] code);
        begin
            @(negedge clk); error_valid=1; error_code=code; event_timestamp=event_timestamp+10;
            @(negedge clk); error_valid=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        @(negedge clk); frame_valid=1; queue_level=12;
        @(negedge clk); frame_valid=0; queue_level=4;
        pulse(1); pulse(2); pulse(3);
        @(negedge clk); frame_valid=1; queue_drop_event=1; cdc_protocol_error=1;
        @(negedge clk); frame_valid=0; queue_drop_event=0; cdc_protocol_error=0;
        @(negedge clk); frame_valid=1;
        @(negedge clk); frame_valid=0;
        wait(diagnostic_status_valid); #1;
        if(!diagnostic_error_valid || diagnostic_error_code!=1 ||
           diagnostic_error_timestamp!=10 || status_queue_level!=4 ||
           status_queue_high_watermark!=12 ||
           status_counters!==128'h00030001000100010001000100070002)
            $fatal(1,"diagnostics mismatch counters=%h err=%b/%h watermark=%d",
                   status_counters,diagnostic_error_valid,diagnostic_error_code,
                   status_queue_high_watermark);
        $display("[PASS] diagnostic counters, error backlog and watermark");
        diagnostic_status_ready=1;
        @(negedge clk); frame_valid=1;
        repeat(65540) @(negedge clk);
        frame_valid=0;
        #1;
        if(status_counters[127:112]!==16'hffff || !status_flags[0])
            $fatal(1,"diagnostic counter did not saturate at u16 max");
        $display("[PASS] diagnostic u16 saturation");
        $finish;
    end
    initial begin #2000000; $fatal(1,"diagnostics timeout"); end
endmodule
