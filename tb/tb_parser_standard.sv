`timescale 1ns/1ps
module tb_parser_standard;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, start_frame=0, bit_valid=0, bit_value=1;
    wire frame_valid, error_valid, stuff_enable, hard_sync_enable;
    wire [28:0] frame_id;
    wire [3:0] frame_dlc;
    wire [63:0] frame_data;
    can_frame_parser #(.CHECK_CRC(0)) dut(
        .clk(clk), .rst_n(rst_n), .start_frame(start_frame),
        .bit_valid(bit_valid), .bit_value(bit_value), .destuff_error(1'b0),
        .calculated_crc(15'b0), .frame_valid(frame_valid),
        .frame_id(frame_id), .frame_dlc(frame_dlc), .frame_data(frame_data),
        .error_valid(error_valid), .stuff_enable(stuff_enable),
        .hard_sync_enable(hard_sync_enable)
    );
    integer frame_count=0;
    always @(posedge clk) if (frame_valid) frame_count=frame_count+1;
    task send(input reg b);
        begin
            @(negedge clk);
            bit_valid=1; bit_value=b;
            @(negedge clk);
            bit_valid=0;
            if (error_valid) $fatal(1,"parser error");
        end
    endtask
    task bits(input reg [31:0] v,input integer n);
        integer k;
        begin for(k=n-1;k>=0;k=k-1) send(v[k]); end
    endtask
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        @(negedge clk); start_frame=1;
        @(negedge clk); start_frame=0;
        send(0); bits(32'h123,11); send(0); send(0); send(0);
        bits(8,4);
        bits(8'h11,8); bits(8'h22,8); bits(8'h33,8); bits(8'h44,8);
        bits(8'h55,8); bits(8'h66,8); bits(8'h77,8); bits(8'h88,8);
        bits(0,15); send(1); send(0); send(1);
        bits(7'h7f,7); bits(3'b111,3);
        repeat(3) @(negedge clk);
        if(frame_count!=1 || frame_id!=29'h123 || frame_dlc!=8 ||
           frame_data!=64'h8877665544332211)
            $fatal(1,"standard frame id=%h dlc=%d data=%h count=%d",
                   frame_id,frame_dlc,frame_data,frame_count);
        $display("[PASS] Stage 3 standard 8-byte parser");
        $finish;
    end
endmodule
