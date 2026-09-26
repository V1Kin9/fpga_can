`timescale 1ns/1ps
module tb_crc15;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, clear=0, bit_valid=0, bit_value=0;
    wire [14:0] crc;
    can_crc15 dut(clk,rst_n,clear,bit_valid,bit_value,crc);

    task send(input reg b);
        begin
            @(negedge clk); bit_valid=1; bit_value=b;
            @(negedge clk); bit_valid=0;
        end
    endtask
    task bits(input reg [31:0] v, input integer n);
        integer k;
        begin for(k=n-1;k>=0;k=k-1) send(v[k]); end
    endtask
    task restart_crc;
        begin
            @(negedge clk); clear=1;
            @(negedge clk); clear=0;
        end
    endtask

    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        restart_crc();
        send(0); bits(32'h123,11); send(0); send(0); send(0);
        bits(8,4);
        bits(8'h11,8); bits(8'h22,8); bits(8'h33,8); bits(8'h44,8);
        bits(8'h55,8); bits(8'h66,8); bits(8'h77,8); bits(8'h88,8);
        if(crc !== 15'h4237) $fatal(1,"CRC standard DLC8 = %h, expected 4237",crc);
        $display("[PASS] CRC15 standard 0x123 DLC8 = 0x4237");
        restart_crc();
        send(0); bits(32'h321,11); send(0); send(0); send(0); bits(0,4);
        if(crc !== 15'h5c6a) $fatal(1,"CRC standard DLC0 = %h, expected 5c6a",crc);
        $display("[PASS] CRC15 standard 0x321 DLC0 = 0x5c6a");
        $finish;
    end
endmodule
