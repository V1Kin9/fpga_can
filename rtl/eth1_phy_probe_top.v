`timescale 1ns/1ps

// Minimal ETH1 board diagnostic. It does not transmit Ethernet frames or
// drive CAN. The 125 MHz RGMII TX clock runs at zero TX_CTL (idle).
module eth1_phy_probe_top (
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
    wire clk_125m_unbuf;
    wire clk_125m_i;
    wire clkfb_unbuf;
    wire clkfb_buf;
    wire mmcm_locked;
    wire core_rst_n;
    wire net_rst_n;

    BUFG u_bufg_50m (.I(clk_50m), .O(clk_50m_i));
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(20.0),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(20.0),
        .CLKOUT0_DIVIDE_F(8.0),
        .REF_JITTER1(0.010)
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

    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_txc_oddr (
        .Q(rgmii_txc), .C(clk_125m_i), .CE(1'b1),
        .D1(1'b1), .D2(1'b0), .R(~net_rst_n), .S(1'b0)
    );
    assign rgmii_tx_ctl = 1'b0;
    assign rgmii_txd = 4'b0000;

    reg [7:0] clk125_count;
    always @(posedge clk_125m_i or negedge net_rst_n) begin
        if (!net_rst_n) clk125_count <= 8'd0;
        else clk125_count <= clk125_count + 8'd1;
    end
    (* ASYNC_REG="TRUE" *) reg clk125_meta;
    (* ASYNC_REG="TRUE", MARK_DEBUG="TRUE" *) reg debug_clk125_toggle;
    always @(posedge clk_50m_i or negedge core_rst_n) begin
        if (!core_rst_n) begin
            clk125_meta <= 1'b0;
            debug_clk125_toggle <= 1'b0;
        end else begin
            clk125_meta <= clk125_count[7];
            debug_clk125_toggle <= clk125_meta;
        end
    end

    wire mdio_out;
    wire mdio_oe;
    assign mdio = mdio_oe ? mdio_out : 1'bz;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_mdc = mdc;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_mdio_in = mdio;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_mdio_out = mdio_out;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_mdio_oe = mdio_oe;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire [6:0] debug_mdio_bit_index;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire [4:0] debug_mdio_phy_addr;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire [4:0] debug_mdio_reg_addr;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_mdio_start;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_mdio_busy;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_mdio_done;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_mdio_ta_ok;

    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_mmcm_locked = mmcm_locked;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_phy_rstn;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire [31:0] debug_found_mask;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire [4:0] debug_found_addr;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_found_valid;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire [15:0] debug_phy_id1;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire [15:0] debug_phy_id2;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire [15:0] debug_bmcr;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire [15:0] debug_bmsr;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire [15:0] debug_physr;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_link_up;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_autoneg_complete;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire [7:0] debug_snapshot_count;
    (* MARK_DEBUG="TRUE", KEEP="TRUE" *) wire debug_snapshot_pulse;

    assign phy_rstn = debug_phy_rstn;
    eth1_phy_probe_core u_probe (
        .clk_50m(clk_50m_i), .rst_n(core_rst_n),
        .mdio_in(mdio), .mdc(mdc), .mdio_out(mdio_out), .mdio_oe(mdio_oe),
        .phy_rstn(debug_phy_rstn),
        .found_mask(debug_found_mask), .found_addr(debug_found_addr),
        .found_valid(debug_found_valid),
        .phy_id1(debug_phy_id1), .phy_id2(debug_phy_id2),
        .bmcr(debug_bmcr), .bmsr(debug_bmsr), .physr(debug_physr),
        .link_up(debug_link_up),
        .autoneg_complete(debug_autoneg_complete),
        .snapshot_count(debug_snapshot_count),
        .snapshot_pulse(debug_snapshot_pulse),
        .mdio_bit_index_debug(debug_mdio_bit_index),
        .mdio_phy_addr_debug(debug_mdio_phy_addr),
        .mdio_reg_addr_debug(debug_mdio_reg_addr),
        .mdio_start_debug(debug_mdio_start),
        .mdio_busy_debug(debug_mdio_busy),
        .mdio_done_debug(debug_mdio_done),
        .mdio_ta_ok_debug(debug_mdio_ta_ok)
    );
endmodule
