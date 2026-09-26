`timescale 1ns/1ps
module can_bit_timing #(
    parameter integer CLK_FREQ_HZ = 50000000,
    parameter integer CAN_BITRATE = 500000,
    parameter integer TQ_PER_BIT = 10,
    parameter integer SYNC_SEG = 1,
    parameter integer PROP_SEG = 5,
    parameter integer PHASE_SEG1 = 2,
    parameter integer PHASE_SEG2 = 2,
    parameter integer SJW = 1
) (
    input  wire clk,
    input  wire rst_n,
    input  wire rx_sync,
    input  wire edge_detect,
    input  wire hard_sync_enable,
    input  wire resync_enable,
    output reg  sample_tick,
    output reg  bit_value,
    output reg  bit_boundary,
    output reg  sync_event,
    output reg  hard_sync_event
);
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
            if (clog2 < 1)
                clog2 = 1;
        end
    endfunction

    localparam integer CLOCKS_PER_BIT = CLK_FREQ_HZ / CAN_BITRATE;
    localparam integer CLOCKS_PER_TQ = CLOCKS_PER_BIT / TQ_PER_BIT;
    localparam integer SAMPLE_CLOCK = (SYNC_SEG + PROP_SEG + PHASE_SEG1) * CLOCKS_PER_TQ;
    localparam integer SJW_CLOCKS = SJW * CLOCKS_PER_TQ;
    localparam integer COUNTER_WIDTH = clog2(CLOCKS_PER_BIT);

    reg [COUNTER_WIDTH-1:0] phase_clock;
    reg running;
    reg resync_used;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_clock     <= {COUNTER_WIDTH{1'b0}};
            running         <= 1'b0;
            resync_used     <= 1'b0;
            sample_tick     <= 1'b0;
            bit_value       <= 1'b1;
            bit_boundary    <= 1'b0;
            sync_event      <= 1'b0;
            hard_sync_event <= 1'b0;
        end else begin
            sample_tick     <= 1'b0;
            bit_boundary    <= 1'b0;
            sync_event      <= 1'b0;
            hard_sync_event <= 1'b0;

            if (edge_detect && (hard_sync_enable || !running)) begin
                phase_clock     <= {COUNTER_WIDTH{1'b0}};
                running         <= 1'b1;
                resync_used     <= 1'b0;
                sync_event      <= 1'b1;
                hard_sync_event <= 1'b1;
                bit_boundary    <= 1'b1;
            end else if (running) begin
                if (phase_clock == SAMPLE_CLOCK - 1) begin
                    sample_tick <= 1'b1;
                    bit_value   <= rx_sync;
                end

                if (edge_detect && resync_enable && !resync_used) begin
                    sync_event  <= 1'b1;
                    resync_used <= 1'b1;
                    if (phase_clock < CLOCKS_PER_BIT / 2) begin
                        // An edge after the nominal boundary lengthens this bit.
                        if (phase_clock <= SJW_CLOCKS)
                            phase_clock <= {COUNTER_WIDTH{1'b0}};
                        else
                            phase_clock <= phase_clock - SJW_CLOCKS;
                    end else begin
                        // An edge before the boundary shortens the prior bit.
                        if (phase_clock >= CLOCKS_PER_BIT - SJW_CLOCKS) begin
                            phase_clock  <= {COUNTER_WIDTH{1'b0}};
                            bit_boundary <= 1'b1;
                            resync_used  <= 1'b0;
                        end else begin
                            phase_clock <= phase_clock + SJW_CLOCKS;
                        end
                    end
                end else if (phase_clock == CLOCKS_PER_BIT - 1) begin
                    phase_clock  <= {COUNTER_WIDTH{1'b0}};
                    bit_boundary <= 1'b1;
                    resync_used  <= 1'b0;
                end else begin
                    phase_clock <= phase_clock + 1'b1;
                end
            end
        end
    end
endmodule
