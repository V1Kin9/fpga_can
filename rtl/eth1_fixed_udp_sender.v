`timescale 1ns/1ps

// One 8-byte UDP test payload every INTERVAL_CYCLES while the 1 Gb/s link is ready.
// Payload: ASCII "FPGA" followed by a big-endian sequence number.
module eth1_fixed_udp_sender #(
    parameter integer INTERVAL_CYCLES = 12_500_000,
    parameter [47:0] SRC_MAC = 48'h020000000001,
    parameter [47:0] DST_MAC = 48'h9483c42aeb74,
    parameter [31:0] SRC_IP = 32'hc0a808fa,
    parameter [31:0] DST_IP = 32'hc0a80801,
    parameter [15:0] SRC_PORT = 16'd5000,
    parameter [15:0] DST_PORT = 16'd5000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       phy_ready,
    output wire [7:0] gmii_txd,
    output wire       gmii_tx_en,
    output wire       gmii_tx_er,
    output wire       mac_underrun_error,
    output reg [31:0] packet_count
);
    reg [31:0] interval_count;
    reg pending;
    reg [31:0] next_sequence;
    reg [31:0] active_sequence;
    reg [2:0] payload_index;
    wire packet_ready;
    wire payload_ready;

    wire frame_valid;
    wire frame_ready;
    wire [15:0] frame_length;
    wire tx_valid;
    wire tx_ready;
    wire [7:0] tx_data;
    wire tx_last;
    wire tx_rst_n;

    // Link loss must abort both the frame builder and the MAC, including a
    // frame already on GMII. Keep sequence/count outside this reset domain so
    // the next probe cannot reuse the aborted frame's sequence number.
    reset_sync u_tx_reset (
        .clk(clk), .arst_n(rst_n && phy_ready), .srst_n(tx_rst_n)
    );

    wire [7:0] payload_data =
        payload_index == 3'd0 ? 8'h46 : // F
        payload_index == 3'd1 ? 8'h50 : // P
        payload_index == 3'd2 ? 8'h47 : // G
        payload_index == 3'd3 ? 8'h41 : // A
        payload_index == 3'd4 ? active_sequence[31:24] :
        payload_index == 3'd5 ? active_sequence[23:16] :
        payload_index == 3'd6 ? active_sequence[15:8] :
                                active_sequence[7:0];

    udp_ipv4_eth_frame_builder #(
        .SRC_MAC(SRC_MAC), .DST_MAC(DST_MAC),
        .SRC_IP(SRC_IP), .DST_IP(DST_IP),
        .SRC_PORT(SRC_PORT), .DST_PORT(DST_PORT)
    ) u_frame_builder (
        .clk(clk), .rst_n(tx_rst_n),
        .packet_valid(pending && tx_rst_n), .packet_ready(packet_ready),
        .packet_length(16'd8), .packet_sequence(next_sequence),
        .payload_valid(1'b1), .payload_ready(payload_ready),
        .payload_data(payload_data), .payload_last(payload_index == 3'd7),
        .frame_valid(frame_valid), .frame_ready(frame_ready),
        .frame_length(frame_length),
        .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx_data(tx_data), .tx_last(tx_last)
    );

    ethernet_mac_tx u_mac (
        .clk(clk), .rst_n(tx_rst_n),
        .frame_valid(frame_valid), .frame_ready(frame_ready),
        .frame_length(frame_length),
        .frame_data_valid(tx_valid), .frame_data_ready(tx_ready),
        .frame_data(tx_data), .frame_data_last(tx_last),
        .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .gmii_txd(gmii_txd), .underrun_error(mac_underrun_error)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            interval_count <= 32'd0;
            pending <= 1'b0;
            next_sequence <= 32'd1;
            active_sequence <= 32'd0;
            payload_index <= 3'd0;
            packet_count <= 32'd0;
        end else begin
            if (!tx_rst_n) begin
                interval_count <= 32'd0;
                pending <= 1'b0;
                payload_index <= 3'd0;
            end else if (pending && packet_ready) begin
                pending <= 1'b0;
                interval_count <= INTERVAL_CYCLES - 1;
                active_sequence <= next_sequence;
                next_sequence <= next_sequence + 1'b1;
                payload_index <= 3'd0;
                packet_count <= packet_count + 1'b1;
            end else if (!pending && interval_count == 0) begin
                pending <= 1'b1;
            end else if (!pending) begin
                interval_count <= interval_count - 1'b1;
            end

            if (tx_rst_n && payload_ready)
                payload_index <= payload_index + 1'b1;
        end
    end
endmodule
