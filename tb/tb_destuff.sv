`timescale 1ns/1ps
module tb_destuff;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0, clear = 0, sample_valid = 0;
    reg sample_bit = 1, stuff_enable = 0;
    wire data_valid, data_bit, stuff_error;
    can_destuff dut(clk, rst_n, clear, sample_valid, sample_bit,
                    stuff_enable, data_valid, data_bit, stuff_error);

    task reset_run;
        begin
            @(negedge clk);
            clear = 1;
            @(negedge clk);
            clear = 0;
        end
    endtask

    task send(input reg b, input reg en, input reg expected_valid,
              input reg expected_error);
        begin
            sample_bit = b;
            stuff_enable = en;
            sample_valid = 1;
            @(posedge clk);
            #1;
            if (data_valid !== expected_valid || stuff_error !== expected_error)
                $fatal(1, "destuff bit=%b enable=%b valid=%b error=%b", b, en,
                       data_valid, stuff_error);
            if (expected_valid && data_bit !== b)
                $fatal(1, "destuff data bit mismatch");
            @(negedge clk);
            sample_valid = 0;
        end
    endtask

    integer i;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        reset_run();
        for (i=0; i<5; i=i+1) send(0, 1, 1, 0);
        send(1, 1, 0, 0);
        send(1, 1, 1, 0);
        $display("[PASS] Destuff five dominant");

        reset_run();
        for (i=0; i<5; i=i+1) send(1, 1, 1, 0);
        send(0, 1, 0, 0);
        send(0, 1, 1, 0);
        $display("[PASS] Destuff five recessive");

        reset_run();
        for (i=0; i<5; i=i+1) send(0, 1, 1, 0);
        send(0, 1, 0, 1);
        $display("[PASS] Stuff error");

        reset_run();
        for (i=0; i<5; i=i+1) send(0, 1, 1, 0);
        send(1, 0, 0, 0); // pending stuff after final CRC bit
        send(1, 0, 1, 0); // CRC delimiter is unstuffed
        $display("[PASS] CRC stuffing boundary");
        $finish;
    end
endmodule
