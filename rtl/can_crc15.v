`timescale 1ns/1ps
module can_crc15 (
    input  wire clk,
    input  wire rst_n,
    input  wire clear,
    input  wire bit_valid,
    input  wire bit_value,
    output reg  [14:0] crc
);
    wire feedback = crc[14] ^ bit_value;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            crc <= 15'h0000;
        else if (clear)
            crc <= 15'h0000;
        else if (bit_valid)
            crc <= {crc[13:0], 1'b0} ^ (feedback ? 15'h4599 : 15'h0000);
    end
endmodule
