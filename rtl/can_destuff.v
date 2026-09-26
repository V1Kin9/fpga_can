`timescale 1ns/1ps
module can_destuff (
    input  wire clk,
    input  wire rst_n,
    input  wire clear,
    input  wire sample_valid,
    input  wire sample_bit,
    input  wire stuff_enable,
    output reg  data_valid,
    output reg  data_bit,
    output reg  stuff_error
);
    reg last_bit;
    reg [2:0] run_length;
    reg expect_stuff;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_bit     <= 1'b1;
            run_length   <= 3'd0;
            expect_stuff <= 1'b0;
            data_valid   <= 1'b0;
            data_bit     <= 1'b1;
            stuff_error  <= 1'b0;
        end else begin
            data_valid  <= 1'b0;
            stuff_error <= 1'b0;
            if (clear) begin
                run_length   <= 3'd0;
                expect_stuff <= 1'b0;
            end else if (sample_valid) begin
                if (expect_stuff) begin
                    expect_stuff <= 1'b0;
                    if (sample_bit == last_bit) begin
                        stuff_error <= 1'b1;
                        run_length  <= 3'd0;
                    end else begin
                        // The inserted bit is the first bit of the new bus run.
                        last_bit   <= sample_bit;
                        run_length <= 3'd1;
                    end
                end else begin
                    data_valid <= 1'b1;
                    data_bit   <= sample_bit;
                    if (stuff_enable) begin
                        if (run_length == 0 || sample_bit != last_bit) begin
                            run_length <= 3'd1;
                            last_bit   <= sample_bit;
                        end else if (run_length == 3'd4) begin
                            run_length   <= 3'd5;
                            expect_stuff <= 1'b1;
                        end else begin
                            run_length <= run_length + 1'b1;
                        end
                    end else begin
                        run_length <= 3'd0;
                    end
                end
            end
        end
    end
endmodule
