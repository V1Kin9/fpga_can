`timescale 1ns/1ps
module udp_ipv4_eth_frame_builder #(
    parameter [47:0] SRC_MAC = 48'h020000000001,
    parameter [47:0] DST_MAC = 48'h020000000002,
    parameter [31:0] SRC_IP  = 32'hC0A83202,
    parameter [31:0] DST_IP  = 32'hC0A83201,
    parameter [15:0] SRC_PORT = 16'd5000,
    parameter [15:0] DST_PORT = 16'd5000,
    parameter [7:0]  IP_TTL = 8'd64
) (
    input  wire clk,
    input  wire rst_n,

    input  wire packet_valid,
    output wire packet_ready,
    input  wire [15:0] packet_length,
    input  wire [31:0] packet_sequence,

    input  wire payload_valid,
    output wire payload_ready,
    input  wire [7:0] payload_data,
    input  wire payload_last,

    output wire frame_valid,
    input  wire frame_ready,
    output wire [15:0] frame_length,

    output wire tx_valid,
    input  wire tx_ready,
    output reg  [7:0] tx_data,
    output wire tx_last
);
    localparam integer ETH_HEADER_BYTES = 14;
    localparam integer IPV4_HEADER_BYTES = 20;
    localparam integer UDP_HEADER_BYTES = 8;
    localparam integer HEADER_BYTES = ETH_HEADER_BYTES + IPV4_HEADER_BYTES + UDP_HEADER_BYTES;

    localparam [2:0] ST_IDLE    = 3'd0,
                     ST_ETH     = 3'd1,
                     ST_IPV4    = 3'd2,
                     ST_UDP     = 3'd3,
                     ST_PAYLOAD = 3'd4;

    reg [2:0] state;
    reg [4:0] header_index;
    reg [15:0] payload_length_reg;
    reg [15:0] ip_total_length_reg;
    reg [15:0] udp_length_reg;
    reg [15:0] ip_ident_reg;
    reg [15:0] ip_checksum_reg;

    function [15:0] ipv4_header_checksum;
        input [15:0] total_length;
        input [15:0] identification;
        reg [31:0] sum;
        begin
            sum = 32'd0;
            sum = sum + 16'h4500;
            sum = sum + total_length;
            sum = sum + identification;
            sum = sum + 16'h4000; // Don't Fragment, fragment offset 0
            sum = sum + {IP_TTL, 8'h11}; // protocol 17 = UDP
            sum = sum + SRC_IP[31:16];
            sum = sum + SRC_IP[15:0];
            sum = sum + DST_IP[31:16];
            sum = sum + DST_IP[15:0];
            sum = (sum[15:0] + sum[31:16]);
            sum = (sum[15:0] + sum[31:16]);
            ipv4_header_checksum = ~sum[15:0];
        end
    endfunction

    wire [15:0] requested_ip_total_length =
        IPV4_HEADER_BYTES + UDP_HEADER_BYTES + packet_length;
    wire [15:0] requested_udp_length = UDP_HEADER_BYTES + packet_length;
    wire [15:0] requested_frame_length = HEADER_BYTES + packet_length;

    assign frame_valid = (state == ST_IDLE) && packet_valid;
    assign packet_ready = (state == ST_IDLE) && frame_ready;
    assign frame_length = (state == ST_IDLE) ?
                          requested_frame_length :
                          HEADER_BYTES + payload_length_reg;

    assign payload_ready = (state == ST_PAYLOAD) && tx_ready;
    assign tx_valid = (state == ST_ETH) || (state == ST_IPV4) ||
                      (state == ST_UDP) ||
                      ((state == ST_PAYLOAD) && payload_valid);
    assign tx_last = (state == ST_PAYLOAD) && payload_valid && payload_last;

    always @(*) begin
        tx_data = 8'h00;
        case (state)
            ST_ETH: begin
                case (header_index)
                    0:  tx_data = DST_MAC[47:40];
                    1:  tx_data = DST_MAC[39:32];
                    2:  tx_data = DST_MAC[31:24];
                    3:  tx_data = DST_MAC[23:16];
                    4:  tx_data = DST_MAC[15:8];
                    5:  tx_data = DST_MAC[7:0];
                    6:  tx_data = SRC_MAC[47:40];
                    7:  tx_data = SRC_MAC[39:32];
                    8:  tx_data = SRC_MAC[31:24];
                    9:  tx_data = SRC_MAC[23:16];
                    10: tx_data = SRC_MAC[15:8];
                    11: tx_data = SRC_MAC[7:0];
                    12: tx_data = 8'h08;
                    13: tx_data = 8'h00;
                    default: tx_data = 8'h00;
                endcase
            end

            ST_IPV4: begin
                case (header_index)
                    0:  tx_data = 8'h45; // IPv4, IHL=5
                    1:  tx_data = 8'h00; // DSCP/ECN
                    2:  tx_data = ip_total_length_reg[15:8];
                    3:  tx_data = ip_total_length_reg[7:0];
                    4:  tx_data = ip_ident_reg[15:8];
                    5:  tx_data = ip_ident_reg[7:0];
                    6:  tx_data = 8'h40; // Don't Fragment
                    7:  tx_data = 8'h00;
                    8:  tx_data = IP_TTL;
                    9:  tx_data = 8'h11; // UDP
                    10: tx_data = ip_checksum_reg[15:8];
                    11: tx_data = ip_checksum_reg[7:0];
                    12: tx_data = SRC_IP[31:24];
                    13: tx_data = SRC_IP[23:16];
                    14: tx_data = SRC_IP[15:8];
                    15: tx_data = SRC_IP[7:0];
                    16: tx_data = DST_IP[31:24];
                    17: tx_data = DST_IP[23:16];
                    18: tx_data = DST_IP[15:8];
                    19: tx_data = DST_IP[7:0];
                    default: tx_data = 8'h00;
                endcase
            end

            ST_UDP: begin
                case (header_index)
                    0: tx_data = SRC_PORT[15:8];
                    1: tx_data = SRC_PORT[7:0];
                    2: tx_data = DST_PORT[15:8];
                    3: tx_data = DST_PORT[7:0];
                    4: tx_data = udp_length_reg[15:8];
                    5: tx_data = udp_length_reg[7:0];
                    6: tx_data = 8'h00; // UDP checksum disabled for IPv4
                    7: tx_data = 8'h00;
                    default: tx_data = 8'h00;
                endcase
            end

            ST_PAYLOAD: tx_data = payload_data;
            default: tx_data = 8'h00;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= ST_IDLE;
            header_index        <= 5'd0;
            payload_length_reg  <= 16'd0;
            ip_total_length_reg <= 16'd0;
            udp_length_reg      <= 16'd0;
            ip_ident_reg        <= 16'd0;
            ip_checksum_reg     <= 16'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    header_index <= 5'd0;
                    if (packet_valid && frame_ready) begin
                        payload_length_reg  <= packet_length;
                        ip_total_length_reg <= requested_ip_total_length;
                        udp_length_reg      <= requested_udp_length;
                        ip_ident_reg        <= packet_sequence[15:0];
                        ip_checksum_reg     <= ipv4_header_checksum(
                                                   requested_ip_total_length,
                                                   packet_sequence[15:0]);
                        state <= ST_ETH;
                    end
                end

                ST_ETH: begin
                    if (tx_ready) begin
                        if (header_index == ETH_HEADER_BYTES - 1) begin
                            header_index <= 5'd0;
                            state <= ST_IPV4;
                        end else begin
                            header_index <= header_index + 1'b1;
                        end
                    end
                end

                ST_IPV4: begin
                    if (tx_ready) begin
                        if (header_index == IPV4_HEADER_BYTES - 1) begin
                            header_index <= 5'd0;
                            state <= ST_UDP;
                        end else begin
                            header_index <= header_index + 1'b1;
                        end
                    end
                end

                ST_UDP: begin
                    if (tx_ready) begin
                        if (header_index == UDP_HEADER_BYTES - 1) begin
                            header_index <= 5'd0;
                            state <= ST_PAYLOAD;
                        end else begin
                            header_index <= header_index + 1'b1;
                        end
                    end
                end

                ST_PAYLOAD: begin
                    if (payload_valid && tx_ready && payload_last)
                        state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                    header_index <= 5'd0;
                end
            endcase
        end
    end
endmodule
