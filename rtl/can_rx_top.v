`timescale 1ns/1ps
module can_rx_top (
    input  wire clk_50m,
    input  wire rst_n,
    input  wire can_rx,
    output wire frame_valid,
    output wire [28:0] frame_id,
    output wire frame_ide,
    output wire frame_rtr,
    output wire [3:0] frame_dlc,
    output wire [63:0] frame_data,
    output reg  [63:0] frame_timestamp,
    output wire crc_ok,
    output wire stuff_error,
    output wire form_error,
    output wire frame_error,
    output wire error_valid,
    output wire [7:0] error_code,
    input  wire fifo_ready,
    output wire fifo_valid,
    output wire [28:0] fifo_id,
    output wire fifo_ide,
    output wire fifo_rtr,
    output wire [3:0] fifo_dlc,
    output wire [63:0] fifo_data,
    output wire [63:0] fifo_timestamp,
    output wire fifo_crc_ok,
    output wire fifo_overflow,
    output wire debug_sample_tick,
    output wire debug_bit,
    output wire [4:0] debug_state
);
    wire rx_sync, rx_prev, edge_detect;
    wire sample_tick, bit_value, bit_boundary, sync_event, hard_sync_event;
    wire data_valid, data_bit, destuff_error, stuff_enable;
    wire hard_sync_enable, resync_enable;
    wire crc_clear, crc_bit_valid, crc_bit;
    wire [14:0] calculated_crc;
    reg [63:0] timestamp_counter;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            timestamp_counter <= 0;
            frame_timestamp   <= 0;
        end else begin
            timestamp_counter <= timestamp_counter + 1'b1;
            if (edge_detect && hard_sync_enable)
                frame_timestamp <= timestamp_counter;
        end
    end

    can_rx_sync u_sync(
        .clk(clk_50m), .rst_n(rst_n), .can_rx(can_rx),
        .rx_sync(rx_sync), .rx_prev(rx_prev), .edge_detect(edge_detect)
    );
    can_bit_timing u_timing(
        .clk(clk_50m), .rst_n(rst_n), .rx_sync(rx_sync),
        .edge_detect(edge_detect), .hard_sync_enable(hard_sync_enable),
        .resync_enable(resync_enable), .sample_tick(sample_tick),
        .bit_value(bit_value), .bit_boundary(bit_boundary),
        .sync_event(sync_event), .hard_sync_event(hard_sync_event)
    );
    can_destuff u_destuff(
        .clk(clk_50m), .rst_n(rst_n), .clear(hard_sync_event),
        .sample_valid(sample_tick), .sample_bit(bit_value),
        .stuff_enable(stuff_enable), .data_valid(data_valid),
        .data_bit(data_bit), .stuff_error(destuff_error)
    );
    can_crc15 u_crc(
        .clk(clk_50m), .rst_n(rst_n), .clear(crc_clear),
        .bit_valid(crc_bit_valid), .bit_value(crc_bit),
        .crc(calculated_crc)
    );
    can_frame_parser u_parser(
        .clk(clk_50m), .rst_n(rst_n), .start_frame(hard_sync_event),
        .bit_valid(data_valid), .bit_value(data_bit),
        .destuff_error(destuff_error), .calculated_crc(calculated_crc),
        .stuff_enable(stuff_enable), .hard_sync_enable(hard_sync_enable),
        .resync_enable(resync_enable), .crc_clear(crc_clear),
        .crc_bit_valid(crc_bit_valid), .crc_bit(crc_bit),
        .frame_valid(frame_valid), .frame_id(frame_id), .frame_ide(frame_ide),
        .frame_rtr(frame_rtr), .frame_dlc(frame_dlc), .frame_data(frame_data),
        .crc_ok(crc_ok), .stuff_error(stuff_error),
        .form_error(form_error), .frame_error(frame_error),
        .error_valid(error_valid), .error_code(error_code),
        .debug_state(debug_state)
    );
    can_rx_fifo_if u_fifo_if(
        .clk(clk_50m), .rst_n(rst_n),
        .in_valid(frame_valid), .in_id(frame_id), .in_ide(frame_ide),
        .in_rtr(frame_rtr), .in_dlc(frame_dlc), .in_data(frame_data),
        .in_timestamp(frame_timestamp), .in_crc_ok(crc_ok),
        .out_ready(fifo_ready), .out_valid(fifo_valid), .out_id(fifo_id),
        .out_ide(fifo_ide), .out_rtr(fifo_rtr), .out_dlc(fifo_dlc),
        .out_data(fifo_data), .out_timestamp(fifo_timestamp),
        .out_crc_ok(fifo_crc_ok), .overflow(fifo_overflow)
    );
    assign debug_sample_tick = sample_tick;
    assign debug_bit = bit_value;
endmodule
