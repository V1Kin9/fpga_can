`timescale 1ns/1ps
module eth_frame_cdc_buffer #(
    parameter integer MAX_FRAME_BYTES = 512
) (
    input  wire app_clk,
    input  wire app_rst_n,

    input  wire app_frame_valid,
    output wire app_frame_ready,
    input  wire [15:0] app_frame_length,

    input  wire app_tx_valid,
    output wire app_tx_ready,
    input  wire [7:0] app_tx_data,
    input  wire app_tx_last,

    output reg  app_protocol_error,

    input  wire net_clk,
    input  wire net_rst_n,

    output wire net_frame_valid,
    input  wire net_frame_ready,
    output wire [15:0] net_frame_length,

    output wire net_tx_valid,
    input  wire net_tx_ready,
    output wire [7:0] net_tx_data,
    output wire net_tx_last
);
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
            if (clog2 < 1)
                clog2 = 1;
        end
    endfunction

    localparam integer ADDR_WIDTH = clog2(MAX_FRAME_BYTES);

    reg [7:0] mem [0:MAX_FRAME_BYTES-1];

    reg req_toggle;
    reg ack_sync1, ack_sync2;
    reg capture_active;
    reg [ADDR_WIDTH:0] wr_count;
    reg [15:0] stored_length;

    reg req_sync1, req_sync2;
    reg ack_toggle;
    reg stream_active;
    reg [ADDR_WIDTH:0] rd_count;
    reg [15:0] active_length;

    wire buffer_free = (req_toggle == ack_sync2);
    wire length_supported = (app_frame_length != 0) &&
                            (app_frame_length <= MAX_FRAME_BYTES);

    assign app_frame_ready = !capture_active && buffer_free && length_supported;
    assign app_tx_ready = capture_active && (wr_count < MAX_FRAME_BYTES);

    assign net_frame_valid = (req_sync2 != ack_toggle) && !stream_active;
    assign net_frame_length = stored_length;
    assign net_tx_valid = stream_active;
    assign net_tx_data = mem[rd_count[ADDR_WIDTH-1:0]];
    assign net_tx_last = stream_active &&
                         (rd_count == active_length - 1'b1);

    // A complete frame is written before req_toggle changes. The frame memory
    // and stored_length remain stable until the net domain returns ack_toggle.
    // This is a bundled-data CDC handshake; only the toggles require 2-FF sync.

    always @(posedge app_clk or negedge app_rst_n) begin
        if (!app_rst_n) begin
            req_toggle        <= 1'b0;
            ack_sync1         <= 1'b0;
            ack_sync2         <= 1'b0;
            capture_active    <= 1'b0;
            wr_count          <= {(ADDR_WIDTH+1){1'b0}};
            stored_length     <= 16'd0;
            app_protocol_error <= 1'b0;
        end else begin
            ack_sync1 <= ack_toggle;
            ack_sync2 <= ack_sync1;
            app_protocol_error <= 1'b0;

            if (!capture_active) begin
                if (app_frame_valid && buffer_free) begin
                    if (length_supported) begin
                        capture_active <= 1'b1;
                        wr_count <= {(ADDR_WIDTH+1){1'b0}};
                        stored_length <= app_frame_length;
                    end else begin
                        app_protocol_error <= 1'b1;
                    end
                end
            end else if (app_tx_valid && app_tx_ready) begin
                mem[wr_count[ADDR_WIDTH-1:0]] <= app_tx_data;
                if (app_tx_last) begin
                    if (wr_count + 1'b1 != stored_length)
                        app_protocol_error <= 1'b1;
                    capture_active <= 1'b0;
                    req_toggle <= ~req_toggle;
                end else if (wr_count + 1'b1 >= stored_length) begin
                    // The source exceeded the announced frame length.
                    app_protocol_error <= 1'b1;
                    capture_active <= 1'b0;
                    req_toggle <= ~req_toggle;
                end else begin
                    wr_count <= wr_count + 1'b1;
                end
            end
        end
    end

    always @(posedge net_clk or negedge net_rst_n) begin
        if (!net_rst_n) begin
            req_sync1    <= 1'b0;
            req_sync2    <= 1'b0;
            ack_toggle   <= 1'b0;
            stream_active <= 1'b0;
            rd_count     <= {(ADDR_WIDTH+1){1'b0}};
            active_length <= 16'd0;
        end else begin
            req_sync1 <= req_toggle;
            req_sync2 <= req_sync1;

            if (!stream_active) begin
                if (net_frame_valid && net_frame_ready) begin
                    active_length <= stored_length;
                    rd_count <= {(ADDR_WIDTH+1){1'b0}};
                    stream_active <= 1'b1;
                end
            end else if (net_tx_valid && net_tx_ready) begin
                if (net_tx_last) begin
                    stream_active <= 1'b0;
                    ack_toggle <= req_sync2;
                    rd_count <= {(ADDR_WIDTH+1){1'b0}};
                end else begin
                    rd_count <= rd_count + 1'b1;
                end
            end
        end
    end
endmodule
