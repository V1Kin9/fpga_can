`timescale 1ns/1ps
module can_udp_payload_packetizer #(
    parameter integer MAX_FRAMES = 16,
    parameter integer FLUSH_CYCLES = 50000
) (
    input  wire clk,
    input  wire rst_n,

    input  wire frame_valid,
    output wire frame_ready,
    input  wire [28:0] frame_id,
    input  wire frame_ide,
    input  wire frame_rtr,
    input  wire [3:0] frame_dlc,
    input  wire [63:0] frame_data,
    input  wire [63:0] frame_timestamp,
    input  wire frame_crc_ok,

    output wire packet_valid,
    input  wire packet_ready,
    output wire [15:0] packet_length,
    output wire [31:0] packet_sequence,

    output wire tx_valid,
    input  wire tx_ready,
    output reg  [7:0] tx_data,
    output wire tx_last
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

    localparam integer HEADER_BYTES = 16;
    localparam integer RECORD_BYTES = 24;
    localparam integer FRAME_WIDTH = 164;
    localparam integer FRAME_COUNT_WIDTH = clog2(MAX_FRAMES + 1);
    localparam integer FRAME_INDEX_WIDTH = clog2(MAX_FRAMES);
    localparam integer FLUSH_WIDTH = clog2(FLUSH_CYCLES + 1);

    localparam [2:0] ST_COLLECT = 3'd0,
                     ST_REQUEST = 3'd1,
                     ST_HEADER  = 3'd2,
                     ST_RECORD  = 3'd3;

    reg [2:0] state;
    reg [FRAME_WIDTH-1:0] frame_mem [0:MAX_FRAMES-1];
    reg [FRAME_COUNT_WIDTH-1:0] frame_count;
    reg [FRAME_INDEX_WIDTH-1:0] record_index;
    reg [4:0] record_byte_index;
    reg [4:0] header_index;
    reg [FLUSH_WIDTH-1:0] flush_count;
    reg [31:0] sequence_counter;

    wire [FRAME_WIDTH-1:0] frame_word =
        {frame_timestamp, frame_data, frame_id, frame_dlc,
         frame_ide, frame_rtr, frame_crc_ok};
    wire [FRAME_WIDTH-1:0] current_frame = frame_mem[record_index];

    wire [63:0] current_timestamp = current_frame[163:100];
    wire [63:0] current_data      = current_frame[99:36];
    wire [28:0] current_id        = current_frame[35:7];
    wire [3:0]  current_dlc       = current_frame[6:3];
    wire current_ide              = current_frame[2];
    wire current_rtr              = current_frame[1];
    wire current_crc_ok           = current_frame[0];

    assign frame_ready = (state == ST_COLLECT) && (frame_count < MAX_FRAMES);
    assign packet_valid = (state == ST_REQUEST);
    assign packet_length = HEADER_BYTES + frame_count * RECORD_BYTES;
    assign packet_sequence = sequence_counter;
    assign tx_valid = (state == ST_HEADER) || (state == ST_RECORD);
    assign tx_last = (state == ST_RECORD) &&
                     (record_index == frame_count - 1'b1) &&
                     (record_byte_index == RECORD_BYTES - 1);

    always @(*) begin
        tx_data = 8'h00;
        if (state == ST_HEADER) begin
            case (header_index)
                0:  tx_data = 8'h46; // F
                1:  tx_data = 8'h43; // C
                2:  tx_data = 8'h41; // A
                3:  tx_data = 8'h4e; // N
                4:  tx_data = 8'h01; // protocol version
                5:  tx_data = HEADER_BYTES[7:0];
                6:  tx_data = RECORD_BYTES[7:0];
                7:  tx_data = frame_count[7:0];
                8:  tx_data = sequence_counter[31:24];
                9:  tx_data = sequence_counter[23:16];
                10: tx_data = sequence_counter[15:8];
                11: tx_data = sequence_counter[7:0];
                default: tx_data = 8'h00;
            endcase
        end else if (state == ST_RECORD) begin
            case (record_byte_index)
                0:  tx_data = {3'b000, current_id[28:24]};
                1:  tx_data = current_id[23:16];
                2:  tx_data = current_id[15:8];
                3:  tx_data = current_id[7:0];
                4:  tx_data = {5'b00000, current_crc_ok, current_rtr, current_ide};
                5:  tx_data = {4'b0000, current_dlc};
                6:  tx_data = 8'h00;
                7:  tx_data = 8'h00;
                8:  tx_data = current_timestamp[63:56];
                9:  tx_data = current_timestamp[55:48];
                10: tx_data = current_timestamp[47:40];
                11: tx_data = current_timestamp[39:32];
                12: tx_data = current_timestamp[31:24];
                13: tx_data = current_timestamp[23:16];
                14: tx_data = current_timestamp[15:8];
                15: tx_data = current_timestamp[7:0];
                16: tx_data = current_data[7:0];
                17: tx_data = current_data[15:8];
                18: tx_data = current_data[23:16];
                19: tx_data = current_data[31:24];
                20: tx_data = current_data[39:32];
                21: tx_data = current_data[47:40];
                22: tx_data = current_data[55:48];
                23: tx_data = current_data[63:56];
                default: tx_data = 8'h00;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_COLLECT;
            frame_count       <= {FRAME_COUNT_WIDTH{1'b0}};
            record_index      <= {FRAME_INDEX_WIDTH{1'b0}};
            record_byte_index <= 5'd0;
            header_index      <= 5'd0;
            flush_count       <= {FLUSH_WIDTH{1'b0}};
            sequence_counter  <= 32'd0;
        end else begin
            case (state)
                ST_COLLECT: begin
                    if (frame_valid && frame_ready) begin
                        frame_mem[frame_count] <= frame_word;
                        if (frame_count == 0)
                            flush_count <= {FLUSH_WIDTH{1'b0}};
                        frame_count <= frame_count + 1'b1;
                        if (frame_count == MAX_FRAMES - 1) begin
                            state <= ST_REQUEST;
                            flush_count <= {FLUSH_WIDTH{1'b0}};
                        end
                    end else if (frame_count != 0) begin
                        if (FLUSH_CYCLES <= 1 || flush_count == FLUSH_CYCLES - 1) begin
                            state <= ST_REQUEST;
                            flush_count <= {FLUSH_WIDTH{1'b0}};
                        end else begin
                            flush_count <= flush_count + 1'b1;
                        end
                    end
                end

                ST_REQUEST: begin
                    if (packet_ready) begin
                        state <= ST_HEADER;
                        header_index <= 5'd0;
                    end
                end

                ST_HEADER: begin
                    if (tx_valid && tx_ready) begin
                        if (header_index == HEADER_BYTES - 1) begin
                            state <= ST_RECORD;
                            record_index <= {FRAME_INDEX_WIDTH{1'b0}};
                            record_byte_index <= 5'd0;
                        end else begin
                            header_index <= header_index + 1'b1;
                        end
                    end
                end

                ST_RECORD: begin
                    if (tx_valid && tx_ready) begin
                        if (record_byte_index == RECORD_BYTES - 1) begin
                            if (record_index == frame_count - 1'b1) begin
                                state <= ST_COLLECT;
                                frame_count <= {FRAME_COUNT_WIDTH{1'b0}};
                                record_index <= {FRAME_INDEX_WIDTH{1'b0}};
                                record_byte_index <= 5'd0;
                                flush_count <= {FLUSH_WIDTH{1'b0}};
                                sequence_counter <= sequence_counter + 1'b1;
                            end else begin
                                record_index <= record_index + 1'b1;
                                record_byte_index <= 5'd0;
                            end
                        end else begin
                            record_byte_index <= record_byte_index + 1'b1;
                        end
                    end
                end

                default: begin
                    state <= ST_COLLECT;
                    frame_count <= {FRAME_COUNT_WIDTH{1'b0}};
                end
            endcase
        end
    end
endmodule
