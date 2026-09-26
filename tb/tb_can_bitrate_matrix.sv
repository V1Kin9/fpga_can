`timescale 1ns/1ps
module tb_can_bitrate_matrix;
    parameter integer CAN_BITRATE = 500000;
    localparam integer CLOCKS_PER_BIT = 50000000 / CAN_BITRATE;
    reg clk=0, rst_n=0;
    always #10 clk=~clk;
    wire bus, frame_valid, frame_ide, frame_rtr, crc_ok, error_valid;
    wire [28:0] frame_id;
    wire [3:0] frame_dlc;
    wire [63:0] frame_data, frame_timestamp;
    integer frames=0;
    reg [63:0] previous_timestamp=0;
    can_frame_encoder #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) gen(clk,bus);
    can_rx_top #(.CAN_BITRATE(CAN_BITRATE)) dut (
        .clk_50m(clk),.rst_n(rst_n),.can_rx(bus),
        .frame_valid(frame_valid),.frame_id(frame_id),.frame_ide(frame_ide),
        .frame_rtr(frame_rtr),.frame_dlc(frame_dlc),.frame_data(frame_data),
        .frame_timestamp(frame_timestamp),.crc_ok(crc_ok),.error_valid(error_valid),
        .fifo_ready(1'b1)
    );
    always @(posedge clk) if (rst_n) begin
        if (error_valid) $fatal(1,"bitrate=%0d unexpected CAN error",CAN_BITRATE);
        if (frame_valid) begin
            if (!crc_ok || frame_timestamp<=previous_timestamp)
                $fatal(1,"bitrate=%0d CRC/timestamp failed",CAN_BITRATE);
            previous_timestamp=frame_timestamp;
            if(frames==0 && (frame_id!==29'h321 || frame_ide ||
                             frame_dlc!==8 || frame_data!==64'h0807060504030201))
                $fatal(1,"bitrate=%0d standard frame mismatch",CAN_BITRATE);
            if(frames==1 && (frame_id!==29'h18DAF110 || !frame_ide ||
                             frame_dlc!==8 || frame_data!==64'h8877665544332211))
                $fatal(1,"bitrate=%0d extended frame mismatch",CAN_BITRATE);
            frames=frames+1;
        end
    end
    initial begin
        if (50000000 % CAN_BITRATE != 0 || CLOCKS_PER_BIT % 10 != 0)
            $fatal(1,"unsupported bitrate %0d", CAN_BITRATE);
        repeat(5) @(negedge clk); rst_n=1;
        repeat(CLOCKS_PER_BIT*12) @(negedge clk);
        gen.build_standard(11'h321,0,8,64'h0807060504030201,0,0,0);
        gen.transmit(0);
        gen.build_extended(29'h18DAF110,0,8,64'h8877665544332211);
        gen.transmit(0);
        repeat(CLOCKS_PER_BIT*12) @(negedge clk);
        if(frames!=2) $fatal(1,"bitrate=%0d frames=%0d",CAN_BITRATE,frames);
        $display("[PASS] %0d",CAN_BITRATE);
        $finish;
    end
    initial begin #100000000; $fatal(1,"bitrate matrix timeout %0d",CAN_BITRATE); end
endmodule
