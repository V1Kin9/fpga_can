`timescale 1ns/1ps
module tb_fifo_if;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, in_valid=0, out_ready=0;
    reg [28:0] in_id=0;
    wire out_valid, overflow, out_ide;
    wire [28:0] out_id;
    can_rx_fifo_if dut(
        .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_id(in_id),
        .in_ide(1'b0),.in_rtr(1'b0),.in_dlc(4'd0),
        .in_data(64'b0),.in_timestamp(64'b0),.in_crc_ok(1'b1),
        .out_ready(out_ready),.out_valid(out_valid),.out_id(out_id),
        .out_ide(out_ide),
        .overflow(overflow)
    );
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        in_valid=1; in_id=29'h123;
        @(negedge clk); in_valid=0;
        if(!out_valid || out_id!=29'h123) $fatal(1,"initial enqueue");
        in_valid=1; in_id=29'h456;
        @(negedge clk); in_valid=0;
        if(!overflow || out_id!=29'h123) $fatal(1,"overflow behavior");
        out_ready=1; in_valid=1; in_id=29'h789;
        @(negedge clk); in_valid=0;
        if(!out_valid || out_id!=29'h789 || overflow)
            $fatal(1,"simultaneous dequeue/enqueue");
        @(negedge clk);
        if(out_valid) $fatal(1,"FIFO failed to drain");
        $display("[PASS] FIFO ready, overflow, replacement, drain");
        $finish;
    end
endmodule
