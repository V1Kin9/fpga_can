`timescale 1ns/1ps

// Board-test top: passive CAN RX on D13 to FCAN v2 UDP on ETH1/J1.
// Uses fixed, bench-only L2/L3 addresses and a fixed session marker.
module eth1_can_udp_top #(
    parameter integer CAN_BITRATE = 500000
) (
    input  wire       clk_50m,
    input  wire       rst_n,
    input  wire       can_rx,
    output wire       can_tx,
    output wire       phy_rstn,
    output wire       mdc,
    inout  wire       mdio,
    output wire       rgmii_txc,
    output wire       rgmii_tx_ctl,
    output wire [3:0] rgmii_txd
);
    wire clk_50m_i;
    wire clk_125m_i;
    wire core_rst_n;
    wire net_rst_n;
    (* MARK_DEBUG="TRUE" *) wire phy_ready_125m;
    (* MARK_DEBUG="TRUE" *) wire [15:0] phy_physr;
    (* MARK_DEBUG="TRUE" *) wire [7:0] gmii_txd;
    (* MARK_DEBUG="TRUE" *) wire gmii_tx_en;
    wire gmii_tx_er;
    wire [15:0] queue_level;
    (* MARK_DEBUG="TRUE" *) wire can_frame_drop_event;
    (* MARK_DEBUG="TRUE" *) wire cdc_protocol_error;
    (* MARK_DEBUG="TRUE" *) wire mac_underrun_error;

    eth1_board_support u_board (
        .clk_50m(clk_50m), .rst_n(rst_n),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en),
        .gmii_tx_er(gmii_tx_er),
        .clk_50m_i(clk_50m_i), .clk_125m_i(clk_125m_i),
        .core_rst_n(core_rst_n), .net_rst_n(net_rst_n),
        .phy_ready_125m(phy_ready_125m), .phy_physr(phy_physr),
        .phy_rstn(phy_rstn), .mdc(mdc), .mdio(mdio),
        .rgmii_txc(rgmii_txc), .rgmii_tx_ctl(rgmii_tx_ctl),
        .rgmii_txd(rgmii_txd)
    );

    // A link loss clears in-flight packets. Application traffic starts only
    // after MDIO confirms a resolved 1 Gb/s full-duplex link.
    (* ASYNC_REG="TRUE" *) reg phy_ready_meta_50m;
    (* ASYNC_REG="TRUE" *) reg phy_ready_sync_50m;
    always @(posedge clk_50m_i or negedge core_rst_n) begin
        if (!core_rst_n) begin
            phy_ready_meta_50m <= 1'b0;
            phy_ready_sync_50m <= 1'b0;
        end else begin
            phy_ready_meta_50m <= phy_ready_125m;
            phy_ready_sync_50m <= phy_ready_meta_50m;
        end
    end

    can_gmii_pipeline_top #(
        .CAN_BITRATE(CAN_BITRATE),
        .SRC_MAC(48'h020000000001),
        .DST_MAC(48'h9483c42aeb74),
        .SRC_IP(32'hc0a808fa),
        .DST_IP(32'hc0a80801),
        .SRC_PORT(16'd5000), .DST_PORT(16'd5000)
    ) u_pipeline (
        .clk_50m(clk_50m_i), .gmii_clk_125m(clk_125m_i),
        .rst_n(core_rst_n && phy_ready_sync_50m),
        .can_rx(can_rx), .session_id(32'h20261003),
        .can_tx(can_tx),
        .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .gmii_txd(gmii_txd), .queue_level(queue_level),
        .can_frame_drop_event(can_frame_drop_event),
        .cdc_protocol_error(cdc_protocol_error),
        .mac_underrun_error(mac_underrun_error)
    );
endmodule
