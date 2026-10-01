`timescale 1ns/1ps
// Count event pulses in source clock domain, then synchronize a saturating
// Gray-coded count. Destination samples may skip counts, but never invent one.
module gray_event_counter_cdc #(
    parameter integer WIDTH = 16
) (
    input wire source_clk,
    input wire source_rst_n,
    input wire source_event,
    input wire dest_clk,
    input wire dest_rst_n,
    output reg [WIDTH-1:0] dest_count
);
    reg [WIDTH-1:0] source_binary;
    reg [WIDTH-1:0] source_gray;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [WIDTH-1:0] gray_sync_1;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [WIDTH-1:0] gray_sync_2;
    reg [WIDTH-1:0] decoded_gray;
    wire [WIDTH-1:0] next_binary = source_binary + 1'b1;
    integer i;
    always @(*) begin
        decoded_gray[WIDTH-1] = gray_sync_2[WIDTH-1];
        for (i = WIDTH-2; i >= 0; i = i-1)
            decoded_gray[i] = decoded_gray[i+1] ^ gray_sync_2[i];
    end
    always @(posedge source_clk or negedge source_rst_n) begin
        if (!source_rst_n) begin
            source_binary <= 0;
            source_gray <= 0;
        end else if (source_event && source_binary != {WIDTH{1'b1}}) begin
            source_binary <= next_binary;
            source_gray <= (next_binary >> 1) ^ next_binary;
        end
    end
    always @(posedge dest_clk or negedge dest_rst_n) begin
        if (!dest_rst_n) begin
            gray_sync_1 <= 0;
            gray_sync_2 <= 0;
            dest_count <= 0;
        end else begin
            gray_sync_1 <= source_gray;
            gray_sync_2 <= gray_sync_1;
            dest_count <= decoded_gray;
        end
    end
endmodule
