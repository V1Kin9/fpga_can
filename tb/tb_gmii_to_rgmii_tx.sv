`timescale 1ns/1ps

module tb_gmii_to_rgmii_tx;
    reg clk = 1'b0;
    always #4 clk = ~clk;
    reg rst_n = 1'b0;
    reg [7:0] gmii_txd = 8'h00;
    reg gmii_tx_en = 1'b0;
    reg gmii_tx_er = 1'b0;
    wire rgmii_txc;
    wire rgmii_tx_ctl;
    wire [3:0] rgmii_txd;

    gmii_to_rgmii_tx dut (
        .clk_125m(clk), .rst_n(rst_n),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en),
        .gmii_tx_er(gmii_tx_er),
        .rgmii_txc(rgmii_txc), .rgmii_tx_ctl(rgmii_tx_ctl),
        .rgmii_txd(rgmii_txd)
    );

    task check_byte(input [7:0] value, input en, input er);
        begin
            gmii_txd = value;
            gmii_tx_en = en;
            gmii_tx_er = er;
            @(posedge clk); #1;
            if (rgmii_txc !== 1'b1 || rgmii_txd !== value[3:0] ||
                rgmii_tx_ctl !== en)
                $fatal(1, "RGMII rising edge mapping failed for %02x", value);
            @(negedge clk); #1;
            if (rgmii_txc !== 1'b0 || rgmii_txd !== value[7:4] ||
                rgmii_tx_ctl !== (en ^ er))
                $fatal(1, "RGMII falling edge mapping failed for %02x", value);
        end
    endtask

    initial begin
        // Vivado glbl holds GSR for the first 100 ns.
        #110;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        check_byte(8'ha5, 1'b1, 1'b0);
        check_byte(8'h3c, 1'b1, 1'b1);
        check_byte(8'h00, 1'b0, 1'b0);
        $display("[PASS] GMII to RGMII DDR data, control and clock mapping");
        $finish;
    end
endmodule
