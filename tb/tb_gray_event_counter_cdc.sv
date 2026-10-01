`timescale 1ns/1ps
module tb_gray_event_counter_cdc;
    reg source_clk=0, dest_clk=0, rst_n=0, source_event=0;
    wire [3:0] dest_count;
    integer i;
    always #4 source_clk=~source_clk;
    always #10 dest_clk=~dest_clk;
    gray_event_counter_cdc #(.WIDTH(4)) dut (
        .source_clk(source_clk),.source_rst_n(rst_n),.source_event(source_event),
        .dest_clk(dest_clk),.dest_rst_n(rst_n),.dest_count(dest_count)
    );
    task events(input integer count);
        integer j;
        begin
            for(j=0;j<count;j=j+1) begin
                @(negedge source_clk); source_event=1;
                @(negedge source_clk); source_event=0;
            end
        end
    endtask
    initial begin
        repeat(3) @(negedge dest_clk); rst_n=1;
        events(7);
        repeat(8) @(negedge dest_clk);
        if(dest_count!==7) $fatal(1,"Gray CDC expected 7, got %0d",dest_count);
        events(20);
        repeat(8) @(negedge dest_clk);
        if(dest_count!==15) $fatal(1,"Gray CDC saturation expected 15, got %0d",dest_count);
        $display("[PASS] MAC native-domain Gray count CDC and saturation");
        $finish;
    end
    initial begin #100000; $fatal(1,"Gray CDC timeout"); end
endmodule
