`timescale 1ns/1ps
module tb_mac_idle_reset;
    reg clk=0, rst_n=0;
    always #4 clk=~clk;
    wire frame_ready, frame_data_ready, gmii_tx_en, gmii_tx_er;
    wire [7:0] gmii_txd;
    wire underrun_error;
    ethernet_mac_tx dut(.clk(clk),.rst_n(rst_n),
        .frame_valid(1'b0),.frame_ready(frame_ready),.frame_length(16'd60),
        .frame_data_valid(1'b0),.frame_data_ready(frame_data_ready),
        .frame_data(8'd0),.frame_data_last(1'b0),
        .gmii_tx_en(gmii_tx_en),.gmii_tx_er(gmii_tx_er),
        .gmii_txd(gmii_txd),.underrun_error(underrun_error));
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        repeat(10) @(negedge clk);
        rst_n=0;
        repeat(5) @(negedge clk); rst_n=1;
        repeat(20) @(negedge clk);
        if(!frame_ready || gmii_tx_en || gmii_tx_er || underrun_error)
            $fatal(1,"MAC idle reset produced stale transmission");
        $display("[PASS] MAC idle reset leaves GMII quiet and ready");
        $finish;
    end
endmodule
