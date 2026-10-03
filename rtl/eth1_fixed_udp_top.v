`timescale 1ns/1ps

// ETH1 physical UDP probe. CAN pins are intentionally absent from this top.
module eth1_fixed_udp_top (
    input  wire       clk_50m,
    input  wire       rst_n,
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
    (* MARK_DEBUG="TRUE" *) wire [31:0] packet_count;
    (* MARK_DEBUG="TRUE" *) wire mac_underrun_error;
    (* MARK_DEBUG="TRUE" *) wire [7:0] gmii_txd;
    (* MARK_DEBUG="TRUE" *) wire gmii_tx_en;
    wire gmii_tx_er;

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

    eth1_fixed_udp_sender u_sender (
        .clk(clk_125m_i), .rst_n(net_rst_n),
        .phy_ready(phy_ready_125m),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en),
        .gmii_tx_er(gmii_tx_er),
        .mac_underrun_error(mac_underrun_error),
        .packet_count(packet_count)
    );
endmodule
