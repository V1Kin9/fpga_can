`timescale 1ns/1ps

// ETH1-only PHY reset/MDIO diagnostic. No Ethernet frames are transmitted.
module eth1_phy_probe_core #(
    parameter integer RESET_HOLD_CYCLES = 1_000_000, // 20 ms at 50 MHz
    parameter integer POST_RESET_CYCLES = 1_000_000, // 20 ms startup margin
    parameter integer POLL_CYCLES = 5_000_000,
    parameter integer MDC_HALF_CYCLES = 20
) (
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire        mdio_in,
    output wire        mdc,
    output wire        mdio_out,
    output wire        mdio_oe,
    output reg         phy_rstn,
    output reg [31:0] found_mask,
    output reg [4:0]  found_addr,
    output reg         found_valid,
    output reg [15:0] phy_id1,
    output reg [15:0] phy_id2,
    output reg [15:0] bmcr,
    output reg [15:0] bmsr,
    output reg [15:0] physr,
    output reg         link_up,
    output reg         autoneg_complete,
    output reg [7:0]   snapshot_count,
    output reg          snapshot_pulse
);
    localparam [3:0] S_RESET = 4'd0, S_POST = 4'd1,
                     S_SCAN_START = 4'd2, S_SCAN_WAIT = 4'd3,
                     S_ID2_START = 4'd4, S_ID2_WAIT = 4'd5,
                     S_BMCR_START = 4'd6, S_BMCR_WAIT = 4'd7,
                     S_BMSR1_START = 4'd8, S_BMSR1_WAIT = 4'd9,
                     S_BMSR2_START = 4'd10, S_BMSR2_WAIT = 4'd11,
                     S_POLL = 4'd12,
                     S_PHYSR_START = 4'd13, S_PHYSR_WAIT = 4'd14;

    reg [3:0] state;
    reg [31:0] wait_count;
    reg [4:0] scan_addr;
    reg mdio_start;
    reg [4:0] mdio_phy_addr;
    reg [4:0] mdio_reg_addr;
    wire mdio_busy;
    wire mdio_done;
    wire mdio_ta_ok;
    wire [15:0] mdio_data;
    wire id_present = mdio_ta_ok && (mdio_data != 16'h0000) &&
                      (mdio_data != 16'hffff);

    mdio_clause22_reader #(.MDC_HALF_CYCLES(MDC_HALF_CYCLES)) u_reader (
        .clk(clk_50m), .rst_n(rst_n), .start(mdio_start),
        .phy_addr(mdio_phy_addr), .reg_addr(mdio_reg_addr),
        .mdio_in(mdio_in), .mdc(mdc), .mdio_out(mdio_out),
        .mdio_oe(mdio_oe), .busy(mdio_busy), .done(mdio_done),
        .ta_ok(mdio_ta_ok), .read_data(mdio_data)
    );

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_RESET;
            wait_count <= 32'd0;
            scan_addr <= 5'd0;
            mdio_start <= 1'b0;
            mdio_phy_addr <= 5'd0;
            mdio_reg_addr <= 5'd0;
            phy_rstn <= 1'b0;
            found_mask <= 32'd0;
            found_addr <= 5'd0;
            found_valid <= 1'b0;
            phy_id1 <= 16'hffff;
            phy_id2 <= 16'hffff;
            bmcr <= 16'hffff;
            bmsr <= 16'hffff;
            physr <= 16'hffff;
            link_up <= 1'b0;
            autoneg_complete <= 1'b0;
            snapshot_count <= 8'd0;
            snapshot_pulse <= 1'b0;
        end else begin
            mdio_start <= 1'b0;
            snapshot_pulse <= 1'b0;
            case (state)
                S_RESET: begin
                    if (wait_count == RESET_HOLD_CYCLES-1) begin
                        phy_rstn <= 1'b1;
                        wait_count <= 32'd0;
                        state <= S_POST;
                    end else wait_count <= wait_count + 32'd1;
                end
                S_POST: begin
                    if (wait_count == POST_RESET_CYCLES-1) begin
                        wait_count <= 32'd0;
                        scan_addr <= 5'd0;
                        state <= S_SCAN_START;
                    end else wait_count <= wait_count + 32'd1;
                end
                S_SCAN_START: if (!mdio_busy) begin
                    mdio_phy_addr <= scan_addr;
                    mdio_reg_addr <= 5'd2; // PHY identifier 1
                    mdio_start <= 1'b1;
                    state <= S_SCAN_WAIT;
                end
                S_SCAN_WAIT: if (mdio_done) begin
                    if (id_present) begin
                        found_mask[scan_addr] <= 1'b1;
                        if (!found_valid) begin
                            found_valid <= 1'b1;
                            found_addr <= scan_addr;
                            phy_id1 <= mdio_data;
                        end
                    end
                    if (scan_addr == 5'd31) begin
                        if (found_valid || id_present) state <= S_ID2_START;
                        else begin
                            snapshot_count <= snapshot_count + 8'd1;
                            snapshot_pulse <= 1'b1;
                            wait_count <= 32'd0;
                            state <= S_POLL;
                        end
                    end else begin
                        scan_addr <= scan_addr + 5'd1;
                        state <= S_SCAN_START;
                    end
                end
                S_ID2_START: if (!mdio_busy) begin
                    mdio_phy_addr <= found_addr;
                    mdio_reg_addr <= 5'd3; // PHY identifier 2
                    mdio_start <= 1'b1;
                    state <= S_ID2_WAIT;
                end
                S_ID2_WAIT: if (mdio_done) begin
                    phy_id2 <= mdio_ta_ok ? mdio_data : 16'hffff;
                    state <= S_BMCR_START;
                end
                S_BMCR_START: if (!mdio_busy) begin
                    mdio_phy_addr <= found_addr;
                    mdio_reg_addr <= 5'd0;
                    mdio_start <= 1'b1;
                    state <= S_BMCR_WAIT;
                end
                S_BMCR_WAIT: if (mdio_done) begin
                    bmcr <= mdio_ta_ok ? mdio_data : 16'hffff;
                    state <= S_BMSR1_START;
                end
                S_BMSR1_START: if (!mdio_busy) begin
                    mdio_phy_addr <= found_addr;
                    mdio_reg_addr <= 5'd1;
                    mdio_start <= 1'b1;
                    state <= S_BMSR1_WAIT;
                end
                // BMSR link status is latched low; discard this first read.
                S_BMSR1_WAIT: if (mdio_done) state <= S_BMSR2_START;
                S_BMSR2_START: if (!mdio_busy) begin
                    mdio_phy_addr <= found_addr;
                    mdio_reg_addr <= 5'd1;
                    mdio_start <= 1'b1;
                    state <= S_BMSR2_WAIT;
                end
                S_BMSR2_WAIT: if (mdio_done) begin
                    bmsr <= mdio_ta_ok ? mdio_data : 16'hffff;
                    autoneg_complete <= mdio_ta_ok && mdio_data[5];
                    state <= S_PHYSR_START;
                end
                S_PHYSR_START: if (!mdio_busy) begin
                    mdio_phy_addr <= found_addr;
                    mdio_reg_addr <= 5'd17; // RTL8211E PHY-specific status
                    mdio_start <= 1'b1;
                    state <= S_PHYSR_WAIT;
                end
                S_PHYSR_WAIT: if (mdio_done) begin
                    physr <= mdio_ta_ok ? mdio_data : 16'hffff;
                    link_up <= mdio_ta_ok && mdio_data[10];
                    snapshot_count <= snapshot_count + 8'd1;
                    snapshot_pulse <= 1'b1;
                    wait_count <= 32'd0;
                    state <= S_POLL;
                end
                S_POLL: begin
                    if (wait_count == POLL_CYCLES-1) begin
                        wait_count <= 32'd0;
                        if (found_valid) state <= S_BMSR1_START;
                        else begin
                            found_mask <= 32'd0;
                            scan_addr <= 5'd0;
                            state <= S_SCAN_START;
                        end
                    end else wait_count <= wait_count + 32'd1;
                end
                default: state <= S_RESET;
            endcase
        end
    end
endmodule
