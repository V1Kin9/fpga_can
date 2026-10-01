`timescale 1ns/1ps
module can_frame_encoder #(
    parameter integer CLOCKS_PER_BIT = 100
) (input wire clk, output reg bus = 1'b1);
    reg raw_bits [0:255];
    reg wire_bits [0:319];
    integer raw_count, wire_count, first_stuff;
    integer crc_delim_index, ack_delim_index, eof_index;
    reg [14:0] crc;

    task append(input reg b, input reg cover_crc);
        reg feedback;
        begin
            raw_bits[raw_count] = b;
            raw_count = raw_count + 1;
            if (cover_crc) begin
                feedback = crc[14] ^ b;
                crc = {crc[13:0], 1'b0} ^ (feedback ? 15'h4599 : 15'h0000);
            end
        end
    endtask
    task append_bits(input reg [31:0] value, input integer width);
        integer j;
        begin
            for (j=width-1; j>=0; j=j-1)
                append(value[j], 1);
        end
    endtask
    task finish_frame(input reg corrupt_crc, input reg corrupt_stuff,
                      input integer corrupt_form);
        integer i, j, run;
        reg last, b;
        begin
            for(i=14;i>=0;i=i-1)
                append(crc[i] ^ (corrupt_crc && i==14),0);
            run=0; last=1;
            for(i=0;i<raw_count;i=i+1) begin
                b=raw_bits[i];
                wire_bits[wire_count]=b; wire_count=wire_count+1;
                if(run==0 || b!=last) run=1;
                else run=run+1;
                last=b;
                if(run==5) begin
                    if(first_stuff<0) first_stuff=wire_count;
                    wire_bits[wire_count]=!b; wire_count=wire_count+1;
                    last=!b; run=1;
                end
            end
            if(corrupt_stuff && first_stuff>=0)
                wire_bits[first_stuff]=wire_bits[first_stuff-1];
            crc_delim_index=wire_count;
            wire_bits[wire_count]=1; wire_count=wire_count+1;
            wire_bits[wire_count]=0; wire_count=wire_count+1; // another node's ACK
            ack_delim_index=wire_count;
            wire_bits[wire_count]=1; wire_count=wire_count+1;
            eof_index=wire_count;
            for(j=0;j<7;j=j+1) begin
                wire_bits[wire_count]=1; wire_count=wire_count+1;
            end
            for(j=0;j<3;j=j+1) begin
                wire_bits[wire_count]=1; wire_count=wire_count+1;
            end
            if(corrupt_form==1) wire_bits[crc_delim_index]=0;
            if(corrupt_form==2) wire_bits[ack_delim_index]=0;
            if(corrupt_form==3) wire_bits[eof_index]=0;
        end
    endtask
    task build_standard(input reg [10:0] id, input reg rtr,
                        input reg [3:0] dlc, input reg [63:0] data,
                        input reg corrupt_crc, input reg corrupt_stuff,
                        input integer corrupt_form);
        integer i;
        begin
            raw_count=0; wire_count=0; crc=0; first_stuff=-1;
            append(0,1); append_bits(id,11); append(rtr,1);
            append(0,1); append(0,1); append_bits(dlc,4);
            if (!rtr)
                for(i=0;i<((dlc > 8) ? 8 : dlc);i=i+1)
                    append_bits((data >> (i*8)) & 8'hff,8);
            finish_frame(corrupt_crc,corrupt_stuff,corrupt_form);
        end
    endtask
    task build_extended(input reg [28:0] id, input reg rtr,
                        input reg [3:0] dlc, input reg [63:0] data);
        integer i;
        begin
            raw_count=0; wire_count=0; crc=0; first_stuff=-1;
            append(0,1); append_bits(id >> 18,11);
            append(1,1); // SRR
            append(1,1); // IDE
            append_bits(id & 18'h3ffff,18);
            append(rtr,1); append(0,1); append(0,1);
            append_bits(dlc,4);
            if (!rtr)
                for(i=0;i<((dlc > 8) ? 8 : dlc);i=i+1)
                    append_bits((data >> (i*8)) & 8'hff,8);
            finish_frame(0,0,0);
        end
    endtask
    task transmit(input integer timing_mode);
        integer i, clocks;
        begin
            for(i=0;i<wire_count;i=i+1) begin
                @(negedge clk);
                bus=wire_bits[i];
                clocks=CLOCKS_PER_BIT;
                if(timing_mode==-1 && (i%2)==0) clocks=CLOCKS_PER_BIT-1;
                if(timing_mode==1 && (i%2)==0) clocks=CLOCKS_PER_BIT+1;
                repeat(clocks-1) @(negedge clk);
            end
            @(negedge clk);
            bus=1;
        end
    endtask
endmodule
