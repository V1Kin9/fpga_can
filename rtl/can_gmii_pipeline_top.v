`timescale 1ns/1ps
module can_gmii_pipeline_top #(
    parameter integer QUEUE_DEPTH = 64,
    parameter integer MAX_FRAMES_PER_PACKET = 16,
    parameter integer FLUSH_CYCLES = 50000,
    // Ethernet/IP/UDP headers (42) + FCAN header (16) + 24 per CAN frame.
    parameter integer MAX_ETH_FRAME_BYTES =
        (512 > 58 + 24*MAX_FRAMES_PER_PACKET) ?
        512 : 58 + 24*MAX_FRAMES_PER_PACKET,
    parameter [47:0] SRC_MAC = 48'h020000000001,
    parameter [47:0] DST_MAC = 48'h020000000002,
    parameter [31:0] SRC_IP  = 32'hC0A83202,
    parameter [31:0] DST_IP  = 32'hC0A83201,
    parameter [15:0] SRC_PORT = 16'd5000,
    parameter [15:0] DST_PORT = 16'd5000
) (
    input  wire clk_50m,
    input  wire gmii_clk_125m,
    input  wire rst_n,
    input  wire can_rx,
    output wire can_tx,

    output wire gmii_tx_en,
    output wire gmii_tx_er,
    output wire [7:0] gmii_txd,

    output wire [15:0] queue_level,
    output wire can_frame_drop_event,
    output wire cdc_protocol_error,
    output wire mac_underrun_error
);
    wire app_rst_n;
    wire net_rst_n;

    reset_sync u_app_reset_sync (
        .clk(clk_50m),
        .arst_n(rst_n),
        .srst_n(app_rst_n)
    );

    reset_sync u_net_reset_sync (
        .clk(gmii_clk_125m),
        .arst_n(rst_n),
        .srst_n(net_rst_n)
    );

    wire app_frame_valid;
    wire app_frame_ready;
    wire [15:0] app_frame_length;
    wire app_tx_valid;
    wire app_tx_ready;
    wire [7:0] app_tx_data;
    wire app_tx_last;

    can_udp_ipv4_eth_pipeline_top #(
        .QUEUE_DEPTH(QUEUE_DEPTH),
        .MAX_FRAMES_PER_PACKET(MAX_FRAMES_PER_PACKET),
        .FLUSH_CYCLES(FLUSH_CYCLES),
        .SRC_MAC(SRC_MAC),
        .DST_MAC(DST_MAC),
        .SRC_IP(SRC_IP),
        .DST_IP(DST_IP),
        .SRC_PORT(SRC_PORT),
        .DST_PORT(DST_PORT)
    ) u_app_pipeline (
        .clk_50m(clk_50m),
        .rst_n(app_rst_n),
        .can_rx(can_rx),
        .can_tx(can_tx),
        .eth_frame_valid(app_frame_valid),
        .eth_frame_ready(app_frame_ready),
        .eth_frame_length(app_frame_length),
        .eth_tx_valid(app_tx_valid),
        .eth_tx_ready(app_tx_ready),
        .eth_tx_data(app_tx_data),
        .eth_tx_last(app_tx_last),
        .queue_level(queue_level),
        .frame_drop_event(can_frame_drop_event)
    );

    wire net_frame_valid;
    wire net_frame_ready;
    wire [15:0] net_frame_length;
    wire net_tx_valid;
    wire net_tx_ready;
    wire [7:0] net_tx_data;
    wire net_tx_last;

    eth_frame_cdc_buffer #(
        .MAX_FRAME_BYTES(MAX_ETH_FRAME_BYTES)
    ) u_frame_cdc (
        .app_clk(clk_50m),
        .app_rst_n(app_rst_n),
        .app_frame_valid(app_frame_valid),
        .app_frame_ready(app_frame_ready),
        .app_frame_length(app_frame_length),
        .app_tx_valid(app_tx_valid),
        .app_tx_ready(app_tx_ready),
        .app_tx_data(app_tx_data),
        .app_tx_last(app_tx_last),
        .app_protocol_error(cdc_protocol_error),

        .net_clk(gmii_clk_125m),
        .net_rst_n(net_rst_n),
        .net_frame_valid(net_frame_valid),
        .net_frame_ready(net_frame_ready),
        .net_frame_length(net_frame_length),
        .net_tx_valid(net_tx_valid),
        .net_tx_ready(net_tx_ready),
        .net_tx_data(net_tx_data),
        .net_tx_last(net_tx_last)
    );

    ethernet_mac_tx u_mac_tx (
        .clk(gmii_clk_125m),
        .rst_n(net_rst_n),
        .frame_valid(net_frame_valid),
        .frame_ready(net_frame_ready),
        .frame_length(net_frame_length),
        .frame_data_valid(net_tx_valid),
        .frame_data_ready(net_tx_ready),
        .frame_data(net_tx_data),
        .frame_data_last(net_tx_last),
        .gmii_tx_en(gmii_tx_en),
        .gmii_tx_er(gmii_tx_er),
        .gmii_txd(gmii_txd),
        .underrun_error(mac_underrun_error)
    );
endmodule
