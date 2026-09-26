`timescale 1ns/1ps
module can_sniffer_top (
    input  wire clk_50m,
    input  wire rst_n,
    input  wire can_rx,
    output wire can_tx
);
    // TXD high is recessive. The external TJA1051 S pin must also be held
    // high in hardware to guarantee silent operation during FPGA startup.
    assign can_tx = 1'b1;

    wire rst_sync_n;
    reset_sync u_reset_sync (
        .clk(clk_50m),
        .arst_n(rst_n),
        .srst_n(rst_sync_n)
    );

    (* MARK_DEBUG = "TRUE" *) wire debug_sample_tick;
    (* MARK_DEBUG = "TRUE" *) wire debug_bit;
    (* MARK_DEBUG = "TRUE" *) wire [4:0] debug_state;
    (* MARK_DEBUG = "TRUE" *) wire debug_frame_valid;
    (* MARK_DEBUG = "TRUE" *) wire [28:0] debug_frame_id;
    (* MARK_DEBUG = "TRUE" *) wire debug_frame_ide;
    (* MARK_DEBUG = "TRUE" *) wire debug_frame_rtr;
    (* MARK_DEBUG = "TRUE" *) wire [3:0] debug_dlc;
    (* MARK_DEBUG = "TRUE" *) wire [63:0] debug_frame_data;
    (* MARK_DEBUG = "TRUE" *) wire debug_crc_ok;
    (* MARK_DEBUG = "TRUE" *) wire debug_stuff_error;
    (* MARK_DEBUG = "TRUE" *) wire debug_form_error;
    (* MARK_DEBUG = "TRUE" *) wire debug_frame_error;
    (* MARK_DEBUG = "TRUE" *) wire debug_error;
    (* MARK_DEBUG = "TRUE" *) wire [7:0] debug_error_code;
    (* MARK_DEBUG = "TRUE" *) wire [63:0] debug_timestamp;
    (* MARK_DEBUG = "TRUE" *) wire fifo_valid;
    (* MARK_DEBUG = "TRUE" *) wire fifo_overflow;
    wire [28:0] fifo_id;
    wire fifo_ide, fifo_rtr, fifo_crc_ok;
    wire [3:0] fifo_dlc;
    wire [63:0] fifo_data, fifo_timestamp;

    can_rx_top u_rx (
        .clk_50m(clk_50m), .rst_n(rst_sync_n), .can_rx(can_rx),
        .frame_valid(debug_frame_valid), .frame_id(debug_frame_id),
        .frame_ide(debug_frame_ide), .frame_rtr(debug_frame_rtr),
        .frame_dlc(debug_dlc), .frame_data(debug_frame_data),
        .frame_timestamp(debug_timestamp), .crc_ok(debug_crc_ok),
        .stuff_error(debug_stuff_error), .form_error(debug_form_error),
        .frame_error(debug_frame_error),
        .error_valid(debug_error), .error_code(debug_error_code),
        .fifo_ready(1'b1), .fifo_valid(fifo_valid),
        .fifo_id(fifo_id), .fifo_ide(fifo_ide), .fifo_rtr(fifo_rtr),
        .fifo_dlc(fifo_dlc), .fifo_data(fifo_data),
        .fifo_timestamp(fifo_timestamp), .fifo_crc_ok(fifo_crc_ok),
        .fifo_overflow(fifo_overflow),
        .debug_sample_tick(debug_sample_tick), .debug_bit(debug_bit),
        .debug_state(debug_state)
    );
endmodule
