`timescale 1ns/1ps
module tb_bit_timing;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;
    reg can_rx = 1;
    wire rx_sync, rx_prev, edge_detect;
    wire sample_tick, bit_value, bit_boundary, sync_event, hard_sync_event;

    can_rx_sync u_sync(clk, rst_n, can_rx, rx_sync, rx_prev, edge_detect);
    can_bit_timing u_timing(
        .clk(clk), .rst_n(rst_n), .rx_sync(rx_sync),
        .edge_detect(edge_detect), .hard_sync_enable(1'b0),
        .resync_enable(1'b1), .sample_tick(sample_tick),
        .bit_value(bit_value), .bit_boundary(bit_boundary),
        .sync_event(sync_event), .hard_sync_event(hard_sync_event)
    );

    integer cycle = 0;
    integer sample_count = 0;
    integer last_sample = -1;
    integer hard_count = 0;
    reg [7:0] observed = 0;

    always @(posedge clk) begin
        cycle = cycle + 1;
        if (hard_sync_event)
            hard_count = hard_count + 1;
        if (sample_tick) begin
            if (last_sample >= 0 && cycle - last_sample != 100)
                $fatal(1, "nominal sample spacing %0d, expected 100", cycle-last_sample);
            last_sample = cycle;
            observed[sample_count] = bit_value;
            sample_count = sample_count + 1;
        end
    end

    task drive_bit(input reg value);
        begin
            can_rx = value;
            repeat (100) @(negedge clk);
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (200) @(negedge clk);
        drive_bit(0);
        drive_bit(1);
        drive_bit(0);
        drive_bit(0);
        drive_bit(1);
        drive_bit(1);
        repeat (10) @(negedge clk);
        if (sample_count != 6 || observed[5:0] !== 6'b110010)
            $fatal(1, "samples count=%0d data=%b", sample_count, observed[5:0]);
        if (hard_count != 1)
            $fatal(1, "hard sync count=%0d", hard_count);
        $display("[PASS] Stage 1 sync, 100 clocks/bit, 80%% sampling");
        $finish;
    end
endmodule
