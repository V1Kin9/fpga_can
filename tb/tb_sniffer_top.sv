`timescale 1ns/1ps
module tb_sniffer_top;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0,can_rx=1;
    wire can_tx;
    can_sniffer_top dut(clk,rst_n,can_rx,can_tx);
    initial begin
        repeat(4) @(negedge clk);
        if(can_tx!==1'b1) $fatal(1,"TX must be recessive during reset");
        rst_n=1;
        repeat(40) begin
            @(negedge clk);
            can_rx=~can_rx;
            if(can_tx!==1'b1) $fatal(1,"TX must stay recessive");
        end
        $display("[PASS] Passive top never drives dominant");
        $finish;
    end
endmodule
