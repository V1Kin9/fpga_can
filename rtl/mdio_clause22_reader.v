`timescale 1ns/1ps

// One Clause 22 read transaction. Change MDIO halfway through MDC low,
// leaving setup/hold margin at both clock edges. RTL8211E permits PHY data
// valid up to 300 ns after MDC rises; sample at the following falling edge.
module mdio_clause22_reader #(
    parameter integer MDC_HALF_CYCLES = 20,
    parameter integer PHY_RX_ADVANCE = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [4:0]  phy_addr,
    input  wire [4:0]  reg_addr,
    input  wire        mdio_in,
    output reg         mdc,
    output reg         mdio_out,
    output reg         mdio_oe,
    output reg         busy,
    output reg         done,
    output reg         ta_ok,
    output reg [15:0]  read_data,
    output wire [6:0] bit_index_debug
);
    reg [4:0] phy_latched;
    reg [4:0] reg_latched;
    reg [6:0] bit_index;
    reg [15:0] half_count;
    assign bit_index_debug = bit_index;

    function automatic frame_bit;
        input [6:0] index;
        input [4:0] phy;
        input [4:0] regnum;
        begin
            if (index < 7'd32) frame_bit = 1'b1;       // Preamble
            else if (index == 7'd32) frame_bit = 1'b0; // ST = 01
            else if (index == 7'd33) frame_bit = 1'b1;
            else if (index == 7'd34) frame_bit = 1'b1; // OP = 10 (read)
            else if (index == 7'd35) frame_bit = 1'b0;
            else if (index < 7'd41) frame_bit = phy[40-index];
            else if (index < 7'd46) frame_bit = regnum[45-index];
            else frame_bit = 1'b1;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mdc <= 1'b0;
            mdio_out <= 1'b1;
            mdio_oe <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            ta_ok <= 1'b0;
            read_data <= 16'h0000;
            phy_latched <= 5'd0;
            reg_latched <= 5'd0;
            bit_index <= 7'd0;
            half_count <= 16'd0;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                mdc <= 1'b0;
                if (start) begin
                    phy_latched <= phy_addr;
                    reg_latched <= reg_addr;
                    bit_index <= 7'd0;
                    half_count <= 16'd0;
                    read_data <= 16'h0000;
                    ta_ok <= 1'b0;
                    mdio_out <= 1'b1;
                    mdio_oe <= 1'b1;
                    busy <= 1'b1;
                end
            end else if (!mdc && half_count == (MDC_HALF_CYCLES/2)-1) begin
                // Do not change data/output enable on the falling MDC edge.
                mdio_oe <= (bit_index < 7'd46);
                mdio_out <= frame_bit(bit_index, phy_latched, reg_latched);
                half_count <= half_count + 16'd1;
            end else if (half_count == MDC_HALF_CYCLES-1) begin
                half_count <= 16'd0;
                if (!mdc) begin
                    mdc <= 1'b1;
                end else begin
                    mdc <= 1'b0;
                    // This board's RTL8211E readback is observed one MDC
                    // cycle ahead of the nominal Clause 22 receive slots.
                    if (bit_index == 7'd47-PHY_RX_ADVANCE)
                        ta_ok <= !mdio_in;
                    if (bit_index >= 7'd48-PHY_RX_ADVANCE &&
                        bit_index <= 7'd63-PHY_RX_ADVANCE)
                        read_data <= {read_data[14:0], mdio_in};
                    if (bit_index == 7'd64) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        mdio_oe <= 1'b0;
                    end else begin
                        bit_index <= bit_index + 7'd1;
                    end
                end
            end else begin
                half_count <= half_count + 16'd1;
            end
        end
    end
endmodule
