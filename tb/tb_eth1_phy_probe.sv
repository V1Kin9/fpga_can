`timescale 1ns/1ps

module tb_eth1_phy_probe;
    reg clk_50m = 1'b0;
    always #10 clk_50m = ~clk_50m;
    reg rst_n = 1'b0;
    wire mdc;
    wire mdio_out;
    wire mdio_oe;
    tri1 mdio_line;
    reg slave_oe = 1'b0;
    reg slave_out = 1'b1;
    reg respond_enabled = 1'b1;
    reg [4:0] response_addr = 5'd1;
    reg link_mode = 1'b1;
    assign mdio_line = mdio_oe ? mdio_out : 1'bz;
    assign mdio_line = slave_oe ? slave_out : 1'bz;

    wire phy_rstn;
    wire [31:0] found_mask;
    wire [4:0] found_addr;
    wire found_valid;
    wire [15:0] phy_id1, phy_id2, bmcr, bmsr, physr;
    wire link_up, autoneg_complete;
    wire [7:0] snapshot_count;
    wire snapshot_pulse;

    eth1_phy_probe_core #(
        .RESET_HOLD_CYCLES(20), .POST_RESET_CYCLES(10),
        .POLL_CYCLES(100), .MDC_HALF_CYCLES(2)
    ) dut (
        .clk_50m(clk_50m), .rst_n(rst_n), .mdio_in(mdio_line),
        .mdc(mdc), .mdio_out(mdio_out), .mdio_oe(mdio_oe),
        .phy_rstn(phy_rstn), .found_mask(found_mask),
        .found_addr(found_addr), .found_valid(found_valid),
        .phy_id1(phy_id1), .phy_id2(phy_id2),
        .bmcr(bmcr), .bmsr(bmsr), .physr(physr), .link_up(link_up),
        .autoneg_complete(autoneg_complete),
        .snapshot_count(snapshot_count), .snapshot_pulse(snapshot_pulse)
    );

    integer bit_index = 0;
    reg [4:0] cmd_phy = 5'd0;
    reg [4:0] cmd_reg = 5'd0;
    reg [15:0] response = 16'hffff;
    integer transaction_count = 0;
    integer bmsr_count = 0;

    always @(posedge mdio_oe) begin
        bit_index = 0;
        cmd_phy = 5'd0;
        cmd_reg = 5'd0;
        slave_oe = 1'b0;
    end

    // Independent Clause 22 PHY model: decode the command on MDC rising
    // edges, then drive turnaround/data before the next rising edges.
    always @(posedge mdc) begin
        if (bit_index < 32 && mdio_line !== 1'b1)
            $fatal(1, "MDIO preamble bit %0d", bit_index);
        if (bit_index == 32 && mdio_line !== 1'b0) $fatal(1, "bad ST[1]");
        if (bit_index == 33 && mdio_line !== 1'b1) $fatal(1, "bad ST[0]");
        if (bit_index == 34 && mdio_line !== 1'b1) $fatal(1, "bad read OP[1]");
        if (bit_index == 35 && mdio_line !== 1'b0) $fatal(1, "bad read OP[0]");
        if (bit_index >= 36 && bit_index <= 40)
            cmd_phy = {cmd_phy[3:0], mdio_line};
        if (bit_index >= 41 && bit_index <= 45)
            cmd_reg = {cmd_reg[3:0], mdio_line};
        if (bit_index == 45) begin
            transaction_count = transaction_count + 1;
            if (cmd_phy == response_addr && respond_enabled) begin
                case (cmd_reg)
                    5'd0: response = 16'h1140;
                    5'd1: begin
                        bmsr_count = bmsr_count + 1;
                        if (link_mode && bmsr_count == 1) response = 16'h7809;
                        else if (link_mode) response = 16'h782d;
                        else response = 16'h7809;
                    end
                    5'd2: response = 16'h001c;
                    5'd3: response = 16'hc915;
                    5'd17: response = link_mode ? 16'hac00 : 16'h0000;
                    default: response = 16'h0000;
                endcase
            end else response = 16'hffff;
        end
        if (bit_index >= 46 && mdio_oe)
            $fatal(1, "MAC did not release MDIO for turnaround/data");
        // The Realtek PHY is permitted to make data valid *after* this
        // rising edge. This model deliberately changes it after the edge.
        if (respond_enabled && cmd_phy == response_addr && bit_index == 47) begin
            #30; // 30/40 ns models 300/400 ns PHY-valid/high-time limit
            slave_oe = 1'b1;
            slave_out = 1'b0;
        end else if (respond_enabled && cmd_phy == response_addr &&
                     bit_index >= 48 && bit_index <= 63) begin
            #30;
            slave_oe = 1'b1;
            slave_out = response[63-bit_index];
        end
    end

    always @(negedge mdc) begin
        if (bit_index < 63) begin
            bit_index = bit_index + 1;
            if (bit_index == 46) slave_oe = 1'b0;
        end else slave_oe = 1'b0;
    end

    initial begin
        repeat (3) @(posedge clk_50m);
        rst_n = 1'b1;
        repeat (18) begin
            @(posedge clk_50m);
            if (phy_rstn !== 1'b0) $fatal(1, "PHY reset released early");
        end
        wait (snapshot_pulse);
        #1;
        if (phy_rstn !== 1'b1 || found_mask !== 32'h00000002 ||
            !found_valid || found_addr !== 5'd1 ||
            phy_id1 !== 16'h001c || phy_id2 !== 16'hc915 ||
            bmcr !== 16'h1140 || bmsr !== 16'h782d || physr !== 16'hac00 ||
            !link_up || !autoneg_complete || snapshot_count !== 8'd1)
            $fatal(1, "PHY scan/status mismatch mask=%h id=%h:%h bmcr=%h bmsr=%h", found_mask, phy_id1, phy_id2, bmcr, bmsr);
        if (transaction_count != 37 || bmsr_count != 2)
            $fatal(1, "Expected 32 address scans and five register reads");

        link_mode = 1'b0;
        wait (snapshot_count == 8'd2);
        #1;
        if (link_up || autoneg_complete || bmsr !== 16'h7809 || physr !== 16'h0000)
            $fatal(1, "Periodic BMSR poll did not observe link loss");

        @(negedge clk_50m);
        rst_n = 1'b0;
        respond_enabled = 1'b0;
        repeat (3) @(posedge clk_50m);
        if (phy_rstn || found_valid || found_mask !== 32'd0)
            $fatal(1, "Reset did not clear PHY state");
        @(negedge clk_50m);
        rst_n = 1'b1;
        wait (snapshot_pulse);
        #1;
        if (found_valid || found_mask !== 32'd0 || link_up || phy_id1 !== 16'hffff)
            $fatal(1, "Absent PHY was incorrectly detected");

        @(negedge clk_50m);
        rst_n = 1'b0;
        respond_enabled = 1'b1;
        response_addr = 5'd31;
        link_mode = 1'b1;
        repeat (3) @(posedge clk_50m);
        @(negedge clk_50m);
        rst_n = 1'b1;
        wait (snapshot_pulse);
        #1;
        if (!found_valid || found_addr !== 5'd31 || found_mask !== 32'h80000000 ||
            phy_id1 !== 16'h001c || physr !== 16'hac00)
            $fatal(1, "PHY at last MDIO address was not detected");
        $display("[PASS] tb_eth1_phy_probe");
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "PHY probe timeout");
    end
endmodule
