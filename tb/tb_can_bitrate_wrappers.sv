`timescale 1ns/1ps
module tb_can_bitrate_125000;
    tb_can_bitrate_matrix #(.CAN_BITRATE(125000)) run();
endmodule
module tb_can_bitrate_250000;
    tb_can_bitrate_matrix #(.CAN_BITRATE(250000)) run();
endmodule
module tb_can_bitrate_500000;
    tb_can_bitrate_matrix #(.CAN_BITRATE(500000)) run();
endmodule
module tb_can_bitrate_1000000;
    tb_can_bitrate_matrix #(.CAN_BITRATE(1000000)) run();
endmodule
