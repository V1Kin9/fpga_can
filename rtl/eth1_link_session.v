`timescale 1ns/1ps

// Keep the session counter outside the application link-reset domain. Each
// observed link loss aborts the pipeline and assigns its next run a new ID.
// INITIAL_SESSION is only a bench seed: core reset/reconfiguration reuses it.
// A persistent boot counter or external boot identity is still needed to
// distinguish full device resets; this 32-bit counter also eventually wraps.
module eth1_link_session #(
    parameter [31:0] INITIAL_SESSION = 32'h20261003
) (
    input  wire        clk_50m,
    input  wire        core_rst_n,
    input  wire        phy_ready_125m,
    output wire        pipeline_rst_n,
    output reg  [31:0] session_id
);
    (* ASYNC_REG="TRUE" *) reg phy_ready_meta;
    (* ASYNC_REG="TRUE" *) reg phy_ready_sync;
    reg phy_ready_previous;

    always @(posedge clk_50m or negedge core_rst_n) begin
        if (!core_rst_n) begin
            phy_ready_meta <= 1'b0;
            phy_ready_sync <= 1'b0;
            phy_ready_previous <= 1'b0;
            session_id <= INITIAL_SESSION;
        end else begin
            phy_ready_meta <= phy_ready_125m;
            phy_ready_sync <= phy_ready_meta;
            phy_ready_previous <= phy_ready_sync;
            if (phy_ready_previous && !phy_ready_sync)
                session_id <= session_id + 32'd1;
        end
    end

    // Session advances during reset, before the next active pipeline clock.
    // The pipeline synchronizes reset release separately in both clock domains.
    assign pipeline_rst_n = core_rst_n && phy_ready_sync;
endmodule
