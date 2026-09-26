`timescale 1ns/1ps
module can_rx_sync (
    input  wire clk,
    input  wire rst_n,
    input  wire can_rx,
    output wire rx_sync,
    output reg  rx_prev,
    output wire edge_detect
);
    (* ASYNC_REG = "TRUE" *) reg rx_meta;
    (* ASYNC_REG = "TRUE" *) reg rx_stage;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta  <= 1'b1;
            rx_stage <= 1'b1;
            rx_prev  <= 1'b1;
        end else begin
            rx_meta  <= can_rx;
            rx_stage <= rx_meta;
            rx_prev  <= rx_stage;
        end
    end

    assign rx_sync = rx_stage;
    assign edge_detect = rx_prev && !rx_stage;
endmodule
