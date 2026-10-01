`timescale 1ns/1ps
module can_udp_ipv4_eth_pipeline_top #(
    parameter integer QUEUE_DEPTH = 64,
    parameter integer MAX_FRAMES_PER_PACKET = 16,
    parameter integer FLUSH_CYCLES = 50000,
    parameter integer CAN_BITRATE = 500000,
    parameter integer FCAN_PROTOCOL_VERSION = 2,
    parameter integer STATUS_INTERVAL_CYCLES = 50000000,
    parameter [47:0] SRC_MAC = 48'h020000000001,
    parameter [47:0] DST_MAC = 48'h020000000002,
    parameter [31:0] SRC_IP  = 32'hC0A83202,
    parameter [31:0] DST_IP  = 32'hC0A83201,
    parameter [15:0] SRC_PORT = 16'd5000,
    parameter [15:0] DST_PORT = 16'd5000
) (
    input  wire clk_50m,
    input  wire rst_n,
    input  wire can_rx,
    input  wire [31:0] session_id,
    input  wire cdc_protocol_error,
    input  wire [15:0] mac_underrun_count,
    output wire can_tx,

    output wire eth_frame_valid,
    input  wire eth_frame_ready,
    output wire [15:0] eth_frame_length,

    output wire eth_tx_valid,
    input  wire eth_tx_ready,
    output wire [7:0] eth_tx_data,
    output wire eth_tx_last,

    output wire [15:0] queue_level,
    output wire frame_drop_event
);
    wire payload_packet_valid;
    wire payload_packet_ready;
    wire [15:0] payload_packet_length;
    wire [31:0] payload_packet_sequence;
    wire payload_valid;
    wire payload_ready;
    wire [7:0] payload_data;
    wire payload_last;

    can_udp_pipeline_top #(
        .QUEUE_DEPTH(QUEUE_DEPTH),
        .MAX_FRAMES_PER_PACKET(MAX_FRAMES_PER_PACKET),
        .FLUSH_CYCLES(FLUSH_CYCLES),
        .CAN_BITRATE(CAN_BITRATE),
        .FCAN_PROTOCOL_VERSION(FCAN_PROTOCOL_VERSION),
        .STATUS_INTERVAL_CYCLES(STATUS_INTERVAL_CYCLES)
    ) u_can_udp_pipeline (
        .clk_50m(clk_50m),
        .rst_n(rst_n),
        .can_rx(can_rx),
        .session_id(session_id),
        .cdc_protocol_error(cdc_protocol_error),
        .mac_underrun_count(mac_underrun_count),
        .can_tx(can_tx),
        .packet_valid(payload_packet_valid),
        .packet_ready(payload_packet_ready),
        .packet_length(payload_packet_length),
        .packet_sequence(payload_packet_sequence),
        .tx_valid(payload_valid),
        .tx_ready(payload_ready),
        .tx_data(payload_data),
        .tx_last(payload_last),
        .queue_level(queue_level),
        .frame_drop_event(frame_drop_event)
    );

    wire rst_sync_n;
    reset_sync u_eth_reset_sync (
        .clk(clk_50m),
        .arst_n(rst_n),
        .srst_n(rst_sync_n)
    );

    udp_ipv4_eth_frame_builder #(
        .SRC_MAC(SRC_MAC),
        .DST_MAC(DST_MAC),
        .SRC_IP(SRC_IP),
        .DST_IP(DST_IP),
        .SRC_PORT(SRC_PORT),
        .DST_PORT(DST_PORT)
    ) u_eth_builder (
        .clk(clk_50m),
        .rst_n(rst_sync_n),
        .packet_valid(payload_packet_valid),
        .packet_ready(payload_packet_ready),
        .packet_length(payload_packet_length),
        .packet_sequence(payload_packet_sequence),
        .payload_valid(payload_valid),
        .payload_ready(payload_ready),
        .payload_data(payload_data),
        .payload_last(payload_last),
        .frame_valid(eth_frame_valid),
        .frame_ready(eth_frame_ready),
        .frame_length(eth_frame_length),
        .tx_valid(eth_tx_valid),
        .tx_ready(eth_tx_ready),
        .tx_data(eth_tx_data),
        .tx_last(eth_tx_last)
    );
endmodule
