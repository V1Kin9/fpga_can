`timescale 1ns/1ps
module can_udp_pipeline_top #(
    parameter integer QUEUE_DEPTH = 64,
    parameter integer MAX_FRAMES_PER_PACKET = 16,
    parameter integer FLUSH_CYCLES = 50000
) (
    input  wire clk_50m,
    input  wire rst_n,
    input  wire can_rx,
    output wire can_tx,

    output wire packet_valid,
    input  wire packet_ready,
    output wire [15:0] packet_length,
    output wire [31:0] packet_sequence,

    output wire tx_valid,
    input  wire tx_ready,
    output wire [7:0] tx_data,
    output wire tx_last,

    output wire [15:0] queue_level,
    output wire frame_drop_event
);
    wire rst_sync_n;
    reset_sync u_reset_sync (
        .clk(clk_50m),
        .arst_n(rst_n),
        .srst_n(rst_sync_n)
    );

    // Passive-only safety invariant: never drive a dominant CAN bit.
    assign can_tx = 1'b1;

    wire rx_fifo_ready;
    wire rx_fifo_valid;
    wire [28:0] rx_fifo_id;
    wire rx_fifo_ide;
    wire rx_fifo_rtr;
    wire [3:0] rx_fifo_dlc;
    wire [63:0] rx_fifo_data;
    wire [63:0] rx_fifo_timestamp;
    wire rx_fifo_crc_ok;
    wire rx_fifo_overflow;

    wire queue_in_ready;
    wire queue_out_valid;
    wire queue_out_ready;
    wire [28:0] queue_out_id;
    wire queue_out_ide;
    wire queue_out_rtr;
    wire [3:0] queue_out_dlc;
    wire [63:0] queue_out_data;
    wire [63:0] queue_out_timestamp;
    wire queue_out_crc_ok;

    can_rx_top u_rx (
        .clk_50m(clk_50m),
        .rst_n(rst_sync_n),
        .can_rx(can_rx),
        .frame_valid(),
        .frame_id(),
        .frame_ide(),
        .frame_rtr(),
        .frame_dlc(),
        .frame_data(),
        .frame_timestamp(),
        .crc_ok(),
        .stuff_error(),
        .form_error(),
        .frame_error(),
        .error_valid(),
        .error_code(),
        .fifo_ready(rx_fifo_ready),
        .fifo_valid(rx_fifo_valid),
        .fifo_id(rx_fifo_id),
        .fifo_ide(rx_fifo_ide),
        .fifo_rtr(rx_fifo_rtr),
        .fifo_dlc(rx_fifo_dlc),
        .fifo_data(rx_fifo_data),
        .fifo_timestamp(rx_fifo_timestamp),
        .fifo_crc_ok(rx_fifo_crc_ok),
        .fifo_overflow(rx_fifo_overflow),
        .debug_sample_tick(),
        .debug_bit(),
        .debug_state()
    );

    assign rx_fifo_ready = queue_in_ready;
    assign frame_drop_event = rx_fifo_overflow;

    can_frame_queue #(
        .DEPTH(QUEUE_DEPTH)
    ) u_queue (
        .clk(clk_50m),
        .rst_n(rst_sync_n),
        .in_valid(rx_fifo_valid),
        .in_ready(queue_in_ready),
        .in_id(rx_fifo_id),
        .in_ide(rx_fifo_ide),
        .in_rtr(rx_fifo_rtr),
        .in_dlc(rx_fifo_dlc),
        .in_data(rx_fifo_data),
        .in_timestamp(rx_fifo_timestamp),
        .in_crc_ok(rx_fifo_crc_ok),
        .out_valid(queue_out_valid),
        .out_ready(queue_out_ready),
        .out_id(queue_out_id),
        .out_ide(queue_out_ide),
        .out_rtr(queue_out_rtr),
        .out_dlc(queue_out_dlc),
        .out_data(queue_out_data),
        .out_timestamp(queue_out_timestamp),
        .out_crc_ok(queue_out_crc_ok),
        .level(queue_level)
    );

    can_udp_payload_packetizer #(
        .MAX_FRAMES(MAX_FRAMES_PER_PACKET),
        .FLUSH_CYCLES(FLUSH_CYCLES)
    ) u_packetizer (
        .clk(clk_50m),
        .rst_n(rst_sync_n),
        .frame_valid(queue_out_valid),
        .frame_ready(queue_out_ready),
        .frame_id(queue_out_id),
        .frame_ide(queue_out_ide),
        .frame_rtr(queue_out_rtr),
        .frame_dlc(queue_out_dlc),
        .frame_data(queue_out_data),
        .frame_timestamp(queue_out_timestamp),
        .frame_crc_ok(queue_out_crc_ok),
        .packet_valid(packet_valid),
        .packet_ready(packet_ready),
        .packet_length(packet_length),
        .packet_sequence(packet_sequence),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_data(tx_data),
        .tx_last(tx_last)
    );
endmodule
