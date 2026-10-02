`timescale 1ns/1ps

// Shared ETH1 clock, PHY management, and transmit pins for board test tops.
module eth1_board_support #(
    parameter integer PHY_POST_RESET_CYCLES = 2_000_000
) (
    input  wire       clk_50m,
    input  wire       rst_n,
    input  wire [7:0] gmii_txd,
    input  wire       gmii_tx_en,
    input  wire       gmii_tx_er,
    output wire       clk_50m_i,
    output wire       clk_125m_i,
    output wire       core_rst_n,
    output wire       net_rst_n,
    output wire       phy_ready_125m,
    output wire [15:0] phy_physr,
    output wire       phy_rstn,
    output wire       mdc,
    inout  wire       mdio,
    output wire       rgmii_txc,
    output wire       rgmii_tx_ctl,
    output wire [3:0] rgmii_txd
);
    wire clk_125m_unbuf;
    wire clkfb_unbuf;
    wire clkfb_buf;
    wire mmcm_locked;

    BUFG u_bufg_50m (.I(clk_50m), .O(clk_50m_i));
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"), .CLKIN1_PERIOD(20.0),
        .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(20.0),
        .CLKOUT0_DIVIDE_F(8.0), .REF_JITTER1(0.010)
    ) u_mmcm (
        .CLKIN1(clk_50m_i), .CLKFBIN(clkfb_buf),
        .RST(~rst_n), .PWRDWN(1'b0),
        .CLKFBOUT(clkfb_unbuf), .CLKOUT0(clk_125m_unbuf),
        .LOCKED(mmcm_locked)
    );
    BUFG u_bufg_feedback (.I(clkfb_unbuf), .O(clkfb_buf));
    BUFG u_bufg_125m (.I(clk_125m_unbuf), .O(clk_125m_i));

    reset_sync u_core_reset (
        .clk(clk_50m_i), .arst_n(rst_n & mmcm_locked), .srst_n(core_rst_n)
    );
    reset_sync u_net_reset (
        .clk(clk_125m_i), .arst_n(rst_n & mmcm_locked), .srst_n(net_rst_n)
    );

    wire mdio_out;
    wire mdio_oe;
    assign mdio = mdio_oe ? mdio_out : 1'bz;
    wire [31:0] found_mask;
    wire [4:0] found_addr;
    wire found_valid;
    wire [15:0] phy_id1;
    wire [15:0] phy_id2;
    wire [15:0] bmcr;
    wire [15:0] bmsr;
    wire link_up;
    wire autoneg_complete;
    wire [7:0] snapshot_count;
    wire snapshot_pulse;
    wire [6:0] mdio_bit_index_debug;
    wire [4:0] mdio_phy_addr_debug;
    wire [4:0] mdio_reg_addr_debug;
    wire mdio_start_debug;
    wire mdio_busy_debug;
    wire mdio_done_debug;
    wire mdio_ta_ok_debug;

    eth1_phy_probe_core #(.POST_RESET_CYCLES(PHY_POST_RESET_CYCLES)) u_phy (
        .clk_50m(clk_50m_i), .rst_n(core_rst_n), .mdio_in(mdio),
        .mdc(mdc), .mdio_out(mdio_out), .mdio_oe(mdio_oe),
        .phy_rstn(phy_rstn), .found_mask(found_mask),
        .found_addr(found_addr), .found_valid(found_valid),
        .phy_id1(phy_id1), .phy_id2(phy_id2),
        .bmcr(bmcr), .bmsr(bmsr), .physr(phy_physr),
        .link_up(link_up), .autoneg_complete(autoneg_complete),
        .snapshot_count(snapshot_count), .snapshot_pulse(snapshot_pulse),
        .mdio_bit_index_debug(mdio_bit_index_debug),
        .mdio_phy_addr_debug(mdio_phy_addr_debug),
        .mdio_reg_addr_debug(mdio_reg_addr_debug),
        .mdio_start_debug(mdio_start_debug),
        .mdio_busy_debug(mdio_busy_debug), .mdio_done_debug(mdio_done_debug),
        .mdio_ta_ok_debug(mdio_ta_ok_debug)
    );

    reg phy_ready_50m;
    always @(posedge clk_50m_i or negedge core_rst_n) begin
        if (!core_rst_n)
            phy_ready_50m <= 1'b0;
        else
            phy_ready_50m <= found_valid && (found_addr == 5'd1) &&
                             (phy_id1 == 16'h001c) && link_up &&
                             autoneg_complete && phy_physr[11] && phy_physr[10] &&
                             (phy_physr[15:14] == 2'b10);
    end
    (* ASYNC_REG="TRUE" *) reg phy_ready_meta;
    (* ASYNC_REG="TRUE" *) reg phy_ready_sync;
    always @(posedge clk_125m_i or negedge net_rst_n) begin
        if (!net_rst_n) begin
            phy_ready_meta <= 1'b0;
            phy_ready_sync <= 1'b0;
        end else begin
            phy_ready_meta <= phy_ready_50m;
            phy_ready_sync <= phy_ready_meta;
        end
    end
    assign phy_ready_125m = phy_ready_sync;

    gmii_to_rgmii_tx u_rgmii_tx (
        .clk_125m(clk_125m_i), .rst_n(net_rst_n),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en),
        .gmii_tx_er(gmii_tx_er), .rgmii_txc(rgmii_txc),
        .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txd(rgmii_txd)
    );
endmodule
