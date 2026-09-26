`timescale 1ns/1ps
module can_frame_queue #(
    parameter integer DEPTH = 64
) (
    input  wire clk,
    input  wire rst_n,

    input  wire in_valid,
    output wire in_ready,
    input  wire [28:0] in_id,
    input  wire in_ide,
    input  wire in_rtr,
    input  wire [3:0] in_dlc,
    input  wire [63:0] in_data,
    input  wire [63:0] in_timestamp,
    input  wire in_crc_ok,

    output wire out_valid,
    input  wire out_ready,
    output wire [28:0] out_id,
    output wire out_ide,
    output wire out_rtr,
    output wire [3:0] out_dlc,
    output wire [63:0] out_data,
    output wire [63:0] out_timestamp,
    output wire out_crc_ok,

    output wire [15:0] level
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

    localparam integer PTR_WIDTH = clog2(DEPTH);
    localparam integer COUNT_WIDTH = clog2(DEPTH + 1);
    localparam integer FRAME_WIDTH = 164;

    reg [FRAME_WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [COUNT_WIDTH-1:0] count;

    wire [FRAME_WIDTH-1:0] in_word =
        {in_timestamp, in_data, in_id, in_dlc, in_ide, in_rtr, in_crc_ok};
    wire [FRAME_WIDTH-1:0] out_word = mem[rd_ptr];

    wire pop = out_valid && out_ready;
    wire push = in_valid && in_ready;

    assign out_valid = (count != 0);
    // Allow a push on a full queue when the head is consumed in the same cycle.
    assign in_ready = (count < DEPTH) || pop;
    assign level = count;

    assign out_timestamp = out_word[163:100];
    assign out_data      = out_word[99:36];
    assign out_id        = out_word[35:7];
    assign out_dlc       = out_word[6:3];
    assign out_ide       = out_word[2];
    assign out_rtr       = out_word[1];
    assign out_crc_ok    = out_word[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {PTR_WIDTH{1'b0}};
            rd_ptr <= {PTR_WIDTH{1'b0}};
            count  <= {COUNT_WIDTH{1'b0}};
        end else begin
            case ({push, pop})
                2'b10: begin
                    mem[wr_ptr] <= in_word;
                    if (wr_ptr == DEPTH-1)
                        wr_ptr <= {PTR_WIDTH{1'b0}};
                    else
                        wr_ptr <= wr_ptr + 1'b1;
                    count <= count + 1'b1;
                end
                2'b01: begin
                    if (rd_ptr == DEPTH-1)
                        rd_ptr <= {PTR_WIDTH{1'b0}};
                    else
                        rd_ptr <= rd_ptr + 1'b1;
                    count <= count - 1'b1;
                end
                2'b11: begin
                    mem[wr_ptr] <= in_word;
                    if (wr_ptr == DEPTH-1)
                        wr_ptr <= {PTR_WIDTH{1'b0}};
                    else
                        wr_ptr <= wr_ptr + 1'b1;
                    if (rd_ptr == DEPTH-1)
                        rd_ptr <= {PTR_WIDTH{1'b0}};
                    else
                        rd_ptr <= rd_ptr + 1'b1;
                end
                default: begin
                    // Hold state.
                end
            endcase
        end
    end
endmodule
