`timescale 1ns/1ps
module can_frame_parser #(
    parameter integer CHECK_CRC = 1
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start_frame,
    input  wire bit_valid,
    input  wire bit_value,
    input  wire destuff_error,
    input  wire [14:0] calculated_crc,
    output wire stuff_enable,
    output wire hard_sync_enable,
    output wire resync_enable,
    output reg  crc_clear,
    output reg  crc_bit_valid,
    output reg  crc_bit,
    output reg  frame_valid,
    output reg  [28:0] frame_id,
    output reg  frame_ide,
    output reg  frame_rtr,
    output reg  [3:0] frame_dlc,
    output reg  [63:0] frame_data,
    output reg  crc_ok,
    output reg  stuff_error,
    output reg  form_error,
    output reg  frame_error,
    output reg  error_valid,
    output reg  [7:0] error_code,
    output wire [4:0] debug_state
);
    localparam [4:0] IDLE=0, SOF=1, BASE_ID=2, RTR_SRR=3, IDE=4,
                     EXT_ID=5, EXT_RTR=6, R1=7, R0=8, DLC=9,
                     DATA=10, CRC=11, CRC_DELIM=12, ACK_SLOT=13,
                     ACK_DELIM=14, EOF_FIELD=15, INTERMISSION=16,
                     RECOVER=17;
    localparam [7:0] ERR_STUFF=8'h01, ERR_CRC=8'h02, ERR_FORM=8'h03,
                     ERR_ABORT=8'h05;

    reg [4:0] state;
    reg [5:0] bit_count;
    reg [3:0] byte_count;
    reg [14:0] received_crc;
    reg [3:0] idle_count;
    wire [3:0] data_length = (frame_dlc > 4'd8) ? 4'd8 : frame_dlc;

    assign debug_state = state;
    assign hard_sync_enable = (state == IDLE);
    assign resync_enable = (state != IDLE && state != RECOVER);
    assign stuff_enable = (state == SOF || state == BASE_ID ||
                           state == RTR_SRR || state == IDE ||
                           state == EXT_ID || state == EXT_RTR ||
                           state == R1 || state == R0 ||
                           state == DLC || state == DATA || state == CRC);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            bit_count     <= 0;
            byte_count    <= 0;
            received_crc  <= 0;
            idle_count    <= 0;
            crc_clear     <= 0;
            crc_bit_valid <= 0;
            crc_bit       <= 0;
            frame_valid   <= 0;
            frame_id      <= 0;
            frame_ide     <= 0;
            frame_rtr     <= 0;
            frame_dlc     <= 0;
            frame_data    <= 0;
            crc_ok        <= 0;
            stuff_error   <= 0;
            form_error    <= 0;
            frame_error   <= 0;
            error_valid   <= 0;
            error_code    <= 0;
        end else begin
            crc_clear     <= 0;
            crc_bit_valid <= 0;
            frame_valid   <= 0;
            crc_ok        <= 0;
            stuff_error   <= 0;
            form_error    <= 0;
            frame_error   <= 0;
            error_valid   <= 0;

            if (state == IDLE && start_frame) begin
                state        <= SOF;
                frame_id     <= 0;
                frame_ide    <= 0;
                frame_rtr    <= 0;
                frame_dlc    <= 0;
                frame_data   <= 0;
                received_crc <= 0;
                bit_count    <= 0;
                byte_count   <= 0;
                crc_clear     <= 1'b1;
            end else if (destuff_error && state != IDLE && state != RECOVER) begin
                state       <= RECOVER;
                idle_count  <= 0;
                error_valid <= 1;
                error_code  <= ERR_STUFF;
                stuff_error <= 1;
                frame_error <= 1;
            end else if (bit_valid) begin
                case (state)
                    IDLE: begin
                        // Ignore idle bus samples until a new SOF hard sync.
                    end
                    SOF: begin
                        if (!bit_value) begin
                            crc_bit_valid <= 1;
                            crc_bit       <= 0;
                            state         <= BASE_ID;
                            bit_count     <= 0;
                        end else begin
                            state       <= RECOVER;
                            idle_count  <= 0;
                            error_valid <= 1;
                            error_code  <= ERR_ABORT;
                            frame_error <= 1;
                        end
                    end
                    BASE_ID: begin
                        crc_bit_valid <= 1;
                        crc_bit       <= bit_value;
                        frame_id      <= {frame_id[27:0], bit_value};
                        if (bit_count == 10) begin
                            bit_count <= 0;
                            state     <= RTR_SRR;
                        end else bit_count <= bit_count + 1'b1;
                    end
                    RTR_SRR: begin
                        crc_bit_valid <= 1;
                        crc_bit       <= bit_value;
                        frame_rtr     <= bit_value;
                        state         <= IDE;
                    end
                    IDE: begin
                        crc_bit_valid <= 1;
                        crc_bit       <= bit_value;
                        if (bit_value) begin
                            if (!frame_rtr) begin
                                // Extended frames require recessive SRR.
                                state       <= RECOVER;
                                idle_count  <= 0;
                                error_valid <= 1;
                                error_code  <= ERR_FORM;
                                form_error  <= 1;
                                frame_error <= 1;
                            end else begin
                                frame_ide <= 1;
                                frame_rtr <= 0; // previous bit was SRR, not RTR
                                bit_count <= 0;
                                state     <= EXT_ID;
                            end
                        end else state <= R0;
                    end
                    EXT_ID: begin
                        crc_bit_valid <= 1;
                        crc_bit       <= bit_value;
                        frame_id      <= {frame_id[27:0], bit_value};
                        if (bit_count == 17) begin
                            bit_count <= 0;
                            state     <= EXT_RTR;
                        end else bit_count <= bit_count + 1'b1;
                    end
                    EXT_RTR: begin
                        crc_bit_valid <= 1;
                        crc_bit       <= bit_value;
                        frame_rtr     <= bit_value;
                        state         <= R1;
                    end
                    R1: begin
                        crc_bit_valid <= 1;
                        crc_bit       <= bit_value;
                        if (bit_value) begin
                            state       <= RECOVER;
                            idle_count  <= 0;
                            error_valid <= 1;
                            error_code  <= ERR_FORM;
                            form_error  <= 1;
                            frame_error <= 1;
                        end else state <= R0;
                    end
                    R0: begin
                        crc_bit_valid <= 1;
                        crc_bit       <= bit_value;
                        if (bit_value) begin
                            state       <= RECOVER;
                            idle_count  <= 0;
                            error_valid <= 1;
                            error_code  <= ERR_FORM;
                            form_error  <= 1;
                            frame_error <= 1;
                        end else begin
                            state     <= DLC;
                            bit_count <= 0;
                        end
                    end
                    DLC: begin
                        crc_bit_valid <= 1;
                        crc_bit       <= bit_value;
                        frame_dlc     <= {frame_dlc[2:0], bit_value};
                        if (bit_count == 3) begin
                            bit_count <= 0;
                            if (frame_rtr || {frame_dlc[2:0], bit_value} == 0) begin
                                state <= CRC;
                            end else begin
                                state      <= DATA;
                                byte_count <= 0;
                            end
                        end else bit_count <= bit_count + 1'b1;
                    end
                    DATA: begin
                        crc_bit_valid <= 1;
                        crc_bit       <= bit_value;
                        frame_data[byte_count*8 + (7-bit_count[2:0])] <= bit_value;
                        if (bit_count == 7) begin
                            bit_count <= 0;
                            if (byte_count == data_length - 1'b1)
                                state <= CRC;
                            else byte_count <= byte_count + 1'b1;
                        end else bit_count <= bit_count + 1'b1;
                    end
                    CRC: begin
                        received_crc <= {received_crc[13:0], bit_value};
                        if (bit_count == 14) begin
                            bit_count <= 0;
                            if (CHECK_CRC && {received_crc[13:0], bit_value} != calculated_crc) begin
                                state       <= RECOVER;
                                idle_count  <= 0;
                                error_valid <= 1;
                                error_code  <= ERR_CRC;
                                frame_error <= 1;
                            end else state <= CRC_DELIM;
                        end else bit_count <= bit_count + 1'b1;
                    end
                    CRC_DELIM: begin
                        if (bit_value) state <= ACK_SLOT;
                        else begin
                            state       <= RECOVER;
                            idle_count  <= 0;
                            error_valid <= 1;
                            error_code  <= ERR_FORM;
                            form_error  <= 1;
                            frame_error <= 1;
                        end
                    end
                    ACK_SLOT: state <= ACK_DELIM; // either bus value is valid for a passive monitor
                    ACK_DELIM: begin
                        if (bit_value) begin
                            state     <= EOF_FIELD;
                            bit_count <= 0;
                        end else begin
                            state       <= RECOVER;
                            idle_count  <= 0;
                            error_valid <= 1;
                            error_code  <= ERR_FORM;
                            form_error  <= 1;
                            frame_error <= 1;
                        end
                    end
                    EOF_FIELD: begin
                        if (!bit_value) begin
                            state       <= RECOVER;
                            idle_count  <= 0;
                            error_valid <= 1;
                            error_code  <= ERR_FORM;
                            form_error  <= 1;
                            frame_error <= 1;
                        end else if (bit_count == 6) begin
                            state       <= INTERMISSION;
                            bit_count   <= 0;
                            frame_valid <= 1;
                            crc_ok      <= 1;
                        end else bit_count <= bit_count + 1'b1;
                    end
                    INTERMISSION: begin
                        if (!bit_value) begin
                            state       <= RECOVER;
                            idle_count  <= 0;
                            error_valid <= 1;
                            error_code  <= ERR_FORM;
                            form_error  <= 1;
                            frame_error <= 1;
                        end else if (bit_count == 2) begin
                            state     <= IDLE;
                            bit_count <= 0;
                        end else bit_count <= bit_count + 1'b1;
                    end
                    RECOVER: begin
                        if (bit_value) begin
                            if (idle_count == 10) begin
                                idle_count <= 0;
                                state      <= IDLE;
                            end else idle_count <= idle_count + 1'b1;
                        end else idle_count <= 0;
                    end
                    default: begin
                        state       <= RECOVER;
                        idle_count  <= 0;
                        error_valid <= 1;
                        error_code  <= ERR_ABORT;
                        frame_error <= 1;
                    end
                endcase
            end
        end
    end
endmodule
