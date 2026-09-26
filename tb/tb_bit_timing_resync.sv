`timescale 1ns/1ps
module tb_bit_timing_resync;
    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg rx_sync = 1;
    reg edge_detect = 0;
    reg hard_sync_enable = 0;
    reg resync_enable = 1;

    wire sample_tick, bit_value, bit_boundary, sync_event, hard_sync_event;

    can_bit_timing dut(
        .clk(clk), .rst_n(rst_n), .rx_sync(rx_sync),
        .edge_detect(edge_detect), .hard_sync_enable(hard_sync_enable),
        .resync_enable(resync_enable), .sample_tick(sample_tick),
        .bit_value(bit_value), .bit_boundary(bit_boundary),
        .sync_event(sync_event), .hard_sync_event(hard_sync_event)
    );

    task reset_dut;
        begin
            rst_n = 0;
            edge_detect = 0;
            hard_sync_enable = 0;
            repeat (3) @(negedge clk);
            rst_n = 1;
            repeat (2) @(negedge clk);
        end
    endtask

    task hard_sync;
        begin
            hard_sync_enable = 1;
            edge_detect = 1;
            @(posedge clk); #1;
            if (!hard_sync_event || dut.phase_clock != 0)
                $fatal(1, "hard sync failed phase=%0d event=%b",
                       dut.phase_clock, hard_sync_event);
            @(negedge clk);
            edge_detect = 0;
            hard_sync_enable = 0;
        end
    endtask

    task pulse_edge_at(input integer phase, input integer expected_phase);
        begin
            while (dut.phase_clock != phase)
                @(negedge clk);
            edge_detect = 1;
            @(posedge clk); #1;
            if (!sync_event || dut.phase_clock != expected_phase)
                $fatal(1, "resync phase=%0d expected=%0d got=%0d event=%b",
                       phase, expected_phase, dut.phase_clock, sync_event);
            @(negedge clk);
            edge_detect = 0;
        end
    endtask

    initial begin
        // Positive phase error inside TSEG1, smaller than SJW: fully correct it.
        reset_dut();
        hard_sync();
        pulse_edge_at(5, 0);
        $display("[PASS] Resync TSEG1 phase error <= SJW");

        // Positive phase error inside TSEG1, larger than SJW: limit correction.
        reset_dut();
        hard_sync();
        pulse_edge_at(20, 10);
        $display("[PASS] Resync TSEG1 phase error > SJW");

        // A phase value past 50%% but still before the 80%% sample point is
        // TSEG1 and must still lengthen, not shorten.
        reset_dut();
        hard_sync();
        pulse_edge_at(60, 50);
        $display("[PASS] Resync classification follows 80%% sample point");

        // Negative phase error in TSEG2: shorten by at most SJW.
        reset_dut();
        hard_sync();
        pulse_edge_at(85, 95);
        $display("[PASS] Resync TSEG2 bounded shortening");

        // Edge within SJW of the next boundary may move boundary immediately.
        reset_dut();
        hard_sync();
        pulse_edge_at(95, 0);
        if (!bit_boundary)
            $fatal(1, "near-boundary negative phase error did not close bit");
        $display("[PASS] Resync TSEG2 near-boundary correction");

        $finish;
    end
endmodule
