`timescale 1ns/1ps
module ethernet_mac_tx (
    input  wire clk,
    input  wire rst_n,

    input  wire frame_valid,
    output wire frame_ready,
    input  wire [15:0] frame_length,

    input  wire frame_data_valid,
    output wire frame_data_ready,
    input  wire [7:0] frame_data,
    input  wire frame_data_last,

    output reg  gmii_tx_en,
    output reg  gmii_tx_er,
    output reg  [7:0] gmii_txd,

    output reg  underrun_error
);
    localparam integer MIN_FRAME_NO_FCS = 60;
    localparam integer IFG_BYTES = 12;

    localparam [3:0] ST_IDLE     = 4'd0,
                     ST_PREAMBLE = 4'd1,
                     ST_SFD      = 4'd2,
                     ST_DATA     = 4'd3,
                     ST_PAD      = 4'd4,
                     ST_FCS      = 4'd5,
                     ST_IFG      = 4'd6;

    reg [3:0] state;
    reg [2:0] preamble_count;
    reg [15:0] expected_length;
    reg [15:0] data_count;
    reg [15:0] pad_remaining;
    reg [31:0] crc_reg;
    reg [31:0] fcs_reg;
    reg [1:0] fcs_index;
    reg [3:0] ifg_count;

    function [31:0] crc32_next_byte;
        input [31:0] crc_in;
        input [7:0] data_in;
        reg [31:0] c;
        integer i;
        begin
            c = crc_in;
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0] ^ data_in[i])
                    c = (c >> 1) ^ 32'hEDB88320;
                else
                    c = c >> 1;
            end
            crc32_next_byte = c;
        end
    endfunction

    assign frame_ready = (state == ST_IDLE) &&
                         (frame_length != 0);

    // Once an Ethernet transmission starts it cannot pause mid-frame.
    // The intended source is eth_frame_cdc_buffer, which guarantees one byte
    // per cycle for the complete buffered frame.
    assign frame_data_ready = (state == ST_DATA);

    always @(*) begin
        gmii_tx_en = 1'b0;
        gmii_tx_er = 1'b0;
        gmii_txd   = 8'h00;

        case (state)
            ST_PREAMBLE: begin
                gmii_tx_en = 1'b1;
                gmii_txd = 8'h55;
            end
            ST_SFD: begin
                gmii_tx_en = 1'b1;
                gmii_txd = 8'hD5;
            end
            ST_DATA: begin
                gmii_tx_en = 1'b1;
                gmii_txd = frame_data_valid ? frame_data : 8'h00;
                gmii_tx_er = !frame_data_valid;
            end
            ST_PAD: begin
                gmii_tx_en = 1'b1;
                gmii_txd = 8'h00;
            end
            ST_FCS: begin
                gmii_tx_en = 1'b1;
                case (fcs_index)
                    0: gmii_txd = fcs_reg[7:0];
                    1: gmii_txd = fcs_reg[15:8];
                    2: gmii_txd = fcs_reg[23:16];
                    3: gmii_txd = fcs_reg[31:24];
                endcase
            end
            default: begin
                gmii_tx_en = 1'b0;
                gmii_txd = 8'h00;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            preamble_count <= 3'd0;
            expected_length <= 16'd0;
            data_count     <= 16'd0;
            pad_remaining  <= 16'd0;
            crc_reg        <= 32'hFFFFFFFF;
            fcs_reg        <= 32'd0;
            fcs_index      <= 2'd0;
            ifg_count      <= 4'd0;
            underrun_error <= 1'b0;
        end else begin
            underrun_error <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (frame_valid && frame_ready) begin
                        expected_length <= frame_length;
                        data_count <= 16'd0;
                        pad_remaining <= (frame_length < MIN_FRAME_NO_FCS) ?
                                         (MIN_FRAME_NO_FCS - frame_length) :
                                         16'd0;
                        crc_reg <= 32'hFFFFFFFF;
                        preamble_count <= 3'd0;
                        state <= ST_PREAMBLE;
                    end
                end

                ST_PREAMBLE: begin
                    if (preamble_count == 3'd6)
                        state <= ST_SFD;
                    else
                        preamble_count <= preamble_count + 1'b1;
                end

                ST_SFD: begin
                    state <= ST_DATA;
                end

                ST_DATA: begin
                    if (!frame_data_valid) begin
                        underrun_error <= 1'b1;
                    end else begin
                        data_count <= data_count + 1'b1;
                        crc_reg <= crc32_next_byte(crc_reg, frame_data);

                        if (frame_data_last ||
                            data_count + 1'b1 == expected_length) begin
                            if (!frame_data_last ||
                                data_count + 1'b1 != expected_length)
                                underrun_error <= 1'b1;

                            if (pad_remaining != 0) begin
                                state <= ST_PAD;
                            end else begin
                                fcs_reg <= ~crc32_next_byte(crc_reg, frame_data);
                                fcs_index <= 2'd0;
                                state <= ST_FCS;
                            end
                        end
                    end
                end

                ST_PAD: begin
                    crc_reg <= crc32_next_byte(crc_reg, 8'h00);
                    if (pad_remaining == 16'd1) begin
                        fcs_reg <= ~crc32_next_byte(crc_reg, 8'h00);
                        fcs_index <= 2'd0;
                        pad_remaining <= 16'd0;
                        state <= ST_FCS;
                    end else begin
                        pad_remaining <= pad_remaining - 1'b1;
                    end
                end

                ST_FCS: begin
                    if (fcs_index == 2'd3) begin
                        ifg_count <= 4'd0;
                        state <= ST_IFG;
                    end else begin
                        fcs_index <= fcs_index + 1'b1;
                    end
                end

                ST_IFG: begin
                    if (ifg_count == IFG_BYTES - 1) begin
                        ifg_count <= 4'd0;
                        state <= ST_IDLE;
                    end else begin
                        ifg_count <= ifg_count + 1'b1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
