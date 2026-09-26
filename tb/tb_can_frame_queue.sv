`timescale 1ns/1ps
module tb_can_frame_queue;
    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg in_valid = 0;
    wire in_ready;
    reg [28:0] in_id = 0;
    reg in_ide = 0;
    reg in_rtr = 0;
    reg [3:0] in_dlc = 0;
    reg [63:0] in_data = 0;
    reg [63:0] in_timestamp = 0;
    reg in_crc_ok = 1;

    wire out_valid;
    reg out_ready = 0;
    wire [28:0] out_id;
    wire out_ide, out_rtr;
    wire [3:0] out_dlc;
    wire [63:0] out_data, out_timestamp;
    wire out_crc_ok;
    wire [15:0] level;

    can_frame_queue #(.DEPTH(4)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_id(in_id), .in_ide(in_ide), .in_rtr(in_rtr),
        .in_dlc(in_dlc), .in_data(in_data),
        .in_timestamp(in_timestamp), .in_crc_ok(in_crc_ok),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_id(out_id), .out_ide(out_ide), .out_rtr(out_rtr),
        .out_dlc(out_dlc), .out_data(out_data),
        .out_timestamp(out_timestamp), .out_crc_ok(out_crc_ok),
        .level(level)
    );

    task push(input [28:0] id, input [63:0] data);
        begin
            while (!in_ready)
                @(negedge clk);
            in_id = id;
            in_data = data;
            in_dlc = 8;
            in_timestamp = {35'd0, id};
            in_valid = 1;
            @(negedge clk);
            in_valid = 0;
        end
    endtask

    task pop_expect(input [28:0] id, input [63:0] data);
        begin
            if (!out_valid || out_id !== id || out_data !== data)
                $fatal(1, "queue head mismatch valid=%b id=%h data=%h expected=%h/%h",
                       out_valid, out_id, out_data, id, data);
            out_ready = 1;
            @(negedge clk);
            out_ready = 0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        push(29'h001, 64'h11);
        push(29'h002, 64'h22);
        push(29'h003, 64'h33);
        push(29'h004, 64'h44);

        if (level != 4 || in_ready)
            $fatal(1, "queue did not report full level=%0d ready=%b", level, in_ready);

        // Full queue must still accept one frame when the head is consumed
        // in the same cycle.
        in_id = 29'h005;
        in_data = 64'h55;
        in_dlc = 8;
        in_timestamp = 64'h5;
        in_valid = 1;
        out_ready = 1;
        #1;
        if (!in_ready)
            $fatal(1, "full queue did not allow simultaneous pop/push");
        @(negedge clk);
        in_valid = 0;
        out_ready = 0;

        if (level != 4)
            $fatal(1, "simultaneous pop/push changed level=%0d", level);

        pop_expect(29'h002, 64'h22);
        pop_expect(29'h003, 64'h33);
        pop_expect(29'h004, 64'h44);
        pop_expect(29'h005, 64'h55);

        if (out_valid || level != 0)
            $fatal(1, "queue failed to drain valid=%b level=%0d", out_valid, level);

        $display("[PASS] Multi-frame queue order, full backpressure, simultaneous pop/push");
        $finish;
    end
endmodule
