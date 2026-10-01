`timescale 1ns/1ps
module tb_can_random_waveforms;
    parameter integer FRAME_TARGET = 128;
    reg clk=0, rst_n=0;
    always #10 clk=~clk;
    wire bus, frame_valid, frame_ide, frame_rtr, crc_ok, error_valid;
    wire [28:0] frame_id;
    wire [3:0] frame_dlc;
    wire [63:0] frame_data, frame_timestamp;
    reg [28:0] expected_id[0:FRAME_TARGET-1];
    reg expected_ide[0:FRAME_TARGET-1], expected_rtr[0:FRAME_TARGET-1];
    reg [3:0] expected_dlc[0:FRAME_TARGET-1];
    reg [63:0] expected_data[0:FRAME_TARGET-1];
    integer received=0, errors=0, i, j;
    reg [31:0] rng=32'h2765A91B, initial_seed=0;
    reg [28:0] id;
    reg ide,rtr;
    reg [3:0] dlc;
    reg [63:0] data;
    reg [63:0] previous_timestamp=0;
    reg [15:0] seen_dlc=0;
    reg [3:0] seen_kinds=0;
    function [31:0] step(input [31:0] x);
        reg [31:0] v;
        begin v=x^(x<<13); v=v^(v>>17); step=v^(v<<5); end
    endfunction
    can_frame_encoder gen(clk,bus);
    can_rx_top dut(
        .clk_50m(clk),.rst_n(rst_n),.can_rx(bus),
        .frame_valid(frame_valid),.frame_id(frame_id),.frame_ide(frame_ide),
        .frame_rtr(frame_rtr),.frame_dlc(frame_dlc),.frame_data(frame_data),
        .frame_timestamp(frame_timestamp),.crc_ok(crc_ok),
        .error_valid(error_valid),.fifo_ready(1'b1)
    );
    always @(posedge clk) if(rst_n) begin
        if(error_valid) errors=errors+1;
        if(frame_valid) begin
            if(received>=FRAME_TARGET || !crc_ok ||
               frame_id!==expected_id[received] ||
               frame_ide!==expected_ide[received] ||
               frame_rtr!==expected_rtr[received] ||
               frame_dlc!==expected_dlc[received] ||
               frame_data!==expected_data[received] ||
               frame_timestamp<=previous_timestamp)
                $fatal(1,"seed=%h frame=%0d id=%h/%h ide=%b/%b rtr=%b/%b dlc=%0d/%0d data=%h/%h",
                       initial_seed,received,frame_id,expected_id[received],
                       frame_ide,expected_ide[received],frame_rtr,expected_rtr[received],
                       frame_dlc,expected_dlc[received],frame_data,expected_data[received]);
            previous_timestamp=frame_timestamp;
            received=received+1;
        end
    end
    initial begin
        if($value$plusargs("SEED=%h",rng)) begin end
        if(rng==0) $fatal(1,"zero seed invalid");
        initial_seed=rng;
        repeat(5) @(negedge clk); rst_n=1;
        repeat(1200) @(negedge clk);
        for(i=0;i<FRAME_TARGET;i=i+1) begin
            rng=step(rng);
            ide=rng[0]; rtr=rng[1]; dlc=rng[5:2];
            seen_dlc[dlc]=1'b1;
            seen_kinds[{ide,rtr}]=1'b1;
            id=ide ? rng[28:0] : {18'd0,rng[10:0]};
            data={step(rng),step(step(rng))};
            for(j=0;j<8;j=j+1)
                if(rtr || j>=dlc) data[j*8 +:8]=0;
            expected_id[i]=id; expected_ide[i]=ide;
            expected_rtr[i]=rtr; expected_dlc[i]=dlc;
            expected_data[i]=data;
            if(ide)
                gen.build_extended(id,rtr,dlc,data);
            else
                gen.build_standard(id[10:0],rtr,dlc,data,0,0,0);
            gen.transmit(0);
            rng=step(rng);
            repeat(rng[7:4]) @(negedge clk);
        end
        repeat(1200) @(negedge clk);
        if(received!=FRAME_TARGET || errors!=0 ||
           seen_dlc!==16'hffff || seen_kinds!==4'hf)
            $fatal(1,"seed=%h sent=%0d received=%0d errors=%0d dlc=%h kinds=%h",
                   initial_seed,FRAME_TARGET,received,errors,seen_dlc,seen_kinds);
        $display("[PASS] randomized CAN waveforms seed=%h frames=%0d",initial_seed,received);
        $finish;
    end
    initial begin #100000000; $fatal(1,"random CAN waveform timeout seed=%h frame=%0d",
                                     initial_seed,received); end
endmodule
