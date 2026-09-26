`timescale 1ns/1ps
module can_rx_fifo_if (
    input  wire clk,
    input  wire rst_n,
    input  wire in_valid,
    input  wire [28:0] in_id,
    input  wire in_ide,
    input  wire in_rtr,
    input  wire [3:0] in_dlc,
    input  wire [63:0] in_data,
    input  wire [63:0] in_timestamp,
    input  wire in_crc_ok,
    input  wire out_ready,
    output reg  out_valid,
    output reg  [28:0] out_id,
    output reg  out_ide,
    output reg  out_rtr,
    output reg  [3:0] out_dlc,
    output reg  [63:0] out_data,
    output reg  [63:0] out_timestamp,
    output reg  out_crc_ok,
    output reg  overflow
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid     <= 0;
            out_id        <= 0;
            out_ide       <= 0;
            out_rtr       <= 0;
            out_dlc       <= 0;
            out_data      <= 0;
            out_timestamp <= 0;
            out_crc_ok    <= 0;
            overflow      <= 0;
        end else begin
            overflow <= 0;
            if (in_valid && (!out_valid || out_ready)) begin
                out_valid     <= 1;
                out_id        <= in_id;
                out_ide       <= in_ide;
                out_rtr       <= in_rtr;
                out_dlc       <= in_dlc;
                out_data      <= in_data;
                out_timestamp <= in_timestamp;
                out_crc_ok    <= in_crc_ok;
            end else if (in_valid) begin
                overflow <= 1;
            end else if (out_ready) begin
                out_valid <= 0;
            end
        end
    end
endmodule
