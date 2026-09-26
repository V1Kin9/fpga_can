`timescale 1ns/1ps
module tb_can_reset_midframe;
    reg clk=0, rst_n=0;
    always #10 clk=~clk;
    wire bus, frame_valid, error_valid;
    wire [28:0] frame_id;
    integer frames=0;
    can_frame_encoder gen(clk,bus);
    can_rx_top dut(.clk_50m(clk),.rst_n(rst_n),.can_rx(bus),
                   .frame_valid(frame_valid),.frame_id(frame_id),
                   .error_valid(error_valid),.fifo_ready(1'b1));
    always @(posedge clk) if(rst_n && frame_valid) begin
        frames=frames+1;
        if(frames!=1 || frame_id!==29'h456)
            $fatal(1,"stale frame from aborted CAN epoch id=%h count=%0d",frame_id,frames);
    end
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        repeat(1200) @(negedge clk);
        gen.build_standard(11'h123,0,8,64'h1122334455667788,0,0,0);
        fork
            gen.transmit(0);
            begin repeat(2000) @(negedge clk); rst_n=0; end
        join
        repeat(1200) @(negedge clk);
        if(frames!=0) $fatal(1,"partial CAN frame emitted before reset");
        rst_n=1;
        repeat(1200) @(negedge clk);
        gen.build_standard(11'h456,0,1,64'hA5,0,0,0);
        gen.transmit(0);
        repeat(5) @(negedge clk);
        if(frames!=1) $fatal(1,"CAN RX did not recover after midframe reset");
        $display("[PASS] CAN mid-frame reset aborts epoch and recovers without stale frame");
        $finish;
    end
    initial begin #10000000; $fatal(1,"CAN reset timeout"); end
endmodule
