`timescale 1ns/1ps

// 1 Gb/s transmit-only GMII to RGMII. The PHY's TXDLY strap delays TXC;
// all five DDR outputs therefore use the same 125 MHz clock phase.
module gmii_to_rgmii_tx (
    input  wire       clk_125m,
    input  wire       rst_n,
    input  wire [7:0] gmii_txd,
    input  wire       gmii_tx_en,
    input  wire       gmii_tx_er,
    output wire       rgmii_txc,
    output wire       rgmii_tx_ctl,
    output wire [3:0] rgmii_txd
);
    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < 4; bit_index = bit_index + 1) begin : g_txd
            ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_oddr (
                .Q(rgmii_txd[bit_index]), .C(clk_125m), .CE(1'b1),
                .D1(gmii_txd[bit_index]), .D2(gmii_txd[bit_index + 4]),
                .R(~rst_n), .S(1'b0)
            );
        end
    endgenerate

    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_ctl (
        .Q(rgmii_tx_ctl), .C(clk_125m), .CE(1'b1),
        .D1(gmii_tx_en), .D2(gmii_tx_en ^ gmii_tx_er),
        .R(~rst_n), .S(1'b0)
    );

    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_txc (
        .Q(rgmii_txc), .C(clk_125m), .CE(1'b1),
        .D1(1'b1), .D2(1'b0), .R(~rst_n), .S(1'b0)
    );
endmodule
