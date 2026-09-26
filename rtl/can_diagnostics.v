`timescale 1ns/1ps
module can_diagnostics #(
    parameter integer STATUS_INTERVAL_CYCLES = 50000000
) (
    input wire clk,
    input wire rst_n,
    input wire frame_valid,
    input wire error_valid,
    input wire [7:0] error_code,
    input wire [63:0] event_timestamp,
    input wire queue_drop_event,
    input wire cdc_protocol_error,
    input wire [15:0] mac_underrun_count,
    input wire [15:0] queue_level,
    output reg diagnostic_error_valid,
    input wire diagnostic_error_ready,
    output reg [7:0] diagnostic_error_code,
    output reg [63:0] diagnostic_error_timestamp,
    output reg diagnostic_status_valid,
    input wire diagnostic_status_ready,
    output wire [7:0] status_flags,
    output wire [7:0] status_queue_level,
    output wire [7:0] status_queue_high_watermark,
    output wire [63:0] status_uptime_ticks,
    output wire [127:0] status_counters
);
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
            if (clog2 < 1) clog2 = 1;
        end
    endfunction

    localparam integer TIMER_WIDTH = clog2(STATUS_INTERVAL_CYCLES + 1);
    reg [TIMER_WIDTH-1:0] interval_counter;
    reg [63:0] uptime_ticks;
    reg [15:0] rx_frames_total;
    reg [15:0] crc_errors;
    reg [15:0] stuff_errors;
    reg [15:0] form_errors;
    reg [15:0] queue_drop_count;
    reg [15:0] cdc_error_count;
    reg [15:0] diagnostic_drop_count;
    reg [15:0] queue_high_watermark;
    wire interval_due = (STATUS_INTERVAL_CYCLES <= 1) ||
                        (interval_counter == STATUS_INTERVAL_CYCLES - 1);
    wire missed_error = error_valid && diagnostic_error_valid &&
                        !diagnostic_error_ready;
    wire missed_status = interval_due && diagnostic_status_valid &&
                         !diagnostic_status_ready;

    assign status_queue_level = (queue_level > 16'd255) ? 8'hff : queue_level[7:0];
    assign status_queue_high_watermark =
        (queue_high_watermark > 16'd255) ? 8'hff : queue_high_watermark[7:0];
    assign status_uptime_ticks = uptime_ticks;
    assign status_counters = {rx_frames_total, crc_errors, stuff_errors, form_errors,
                              queue_drop_count, cdc_error_count,
                              mac_underrun_count, diagnostic_drop_count};
    assign status_flags = {5'd0, (queue_high_watermark > 16'd255),
                           (queue_level > 16'd255),
                           (rx_frames_total == 16'hffff || crc_errors == 16'hffff ||
                            stuff_errors == 16'hffff || form_errors == 16'hffff ||
                            queue_drop_count == 16'hffff || cdc_error_count == 16'hffff ||
                            mac_underrun_count == 16'hffff ||
                            diagnostic_drop_count == 16'hffff)};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            interval_counter <= 0;
            uptime_ticks <= 0;
            rx_frames_total <= 0;
            crc_errors <= 0;
            stuff_errors <= 0;
            form_errors <= 0;
            queue_drop_count <= 0;
            cdc_error_count <= 0;
            diagnostic_drop_count <= 0;
            queue_high_watermark <= 0;
            diagnostic_error_valid <= 0;
            diagnostic_error_code <= 0;
            diagnostic_error_timestamp <= 0;
            diagnostic_status_valid <= 0;
        end else begin
            uptime_ticks <= uptime_ticks + 1'b1;
            if (frame_valid && rx_frames_total != 16'hffff)
                rx_frames_total <= rx_frames_total + 1'b1;
            if (error_valid) begin
                case (error_code)
                    8'h01: if (stuff_errors != 16'hffff) stuff_errors <= stuff_errors + 1'b1;
                    8'h02: if (crc_errors != 16'hffff) crc_errors <= crc_errors + 1'b1;
                    8'h03: if (form_errors != 16'hffff) form_errors <= form_errors + 1'b1;
                    default: begin end
                endcase
                if (!diagnostic_error_valid || diagnostic_error_ready) begin
                    diagnostic_error_valid <= 1'b1;
                    diagnostic_error_code <= error_code;
                    diagnostic_error_timestamp <= event_timestamp;
                end
            end else if (diagnostic_error_valid && diagnostic_error_ready) begin
                diagnostic_error_valid <= 1'b0;
            end
            if (queue_drop_event && queue_drop_count != 16'hffff)
                queue_drop_count <= queue_drop_count + 1'b1;
            if (cdc_protocol_error && cdc_error_count != 16'hffff)
                cdc_error_count <= cdc_error_count + 1'b1;
            if (queue_level > queue_high_watermark)
                queue_high_watermark <= queue_level;
            if (missed_error && missed_status) begin
                if (diagnostic_drop_count < 16'hfffe)
                    diagnostic_drop_count <= diagnostic_drop_count + 2'd2;
                else
                    diagnostic_drop_count <= 16'hffff;
            end else if ((missed_error || missed_status) &&
                         diagnostic_drop_count != 16'hffff) begin
                diagnostic_drop_count <= diagnostic_drop_count + 1'b1;
            end
            if (interval_due) begin
                interval_counter <= 0;
                if (!diagnostic_status_valid || diagnostic_status_ready)
                    diagnostic_status_valid <= 1'b1;
            end else begin
                interval_counter <= interval_counter + 1'b1;
                if (diagnostic_status_valid && diagnostic_status_ready)
                    diagnostic_status_valid <= 1'b0;
            end
        end
    end
endmodule
