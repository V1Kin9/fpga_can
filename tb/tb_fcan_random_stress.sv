`timescale 1ns/1ps
module tb_fcan_random_stress;
    parameter integer DEFAULT_FRAMES = 10000;
    localparam integer QUEUE_DEPTH = 16;
    reg clk=0, rst_n=0;
    always #10 clk=~clk;
    reg in_valid=0, in_ide=0, in_rtr=0;
    reg [28:0] in_id=0;
    reg [3:0] in_dlc=0;
    reg [63:0] in_data=0, in_timestamp=0;
    wire in_ready, out_valid, out_ready, out_ide, out_rtr, out_crc_ok;
    wire [28:0] out_id;
    wire [3:0] out_dlc;
    wire [63:0] out_data, out_timestamp;
    wire [15:0] queue_level;
    wire packet_valid, packet_ready, tx_valid, tx_ready, tx_last;
    wire [15:0] packet_length;
    wire [31:0] packet_sequence;
    wire [7:0] tx_data;
    reg [163:0] expected[0:99999];
    integer target=DEFAULT_FRAMES, accepted=0, emitted=0, dropped=0;
    integer high_watermark=0, packets=0, pos=0, announced_count=0;
    reg [31:0] producer_rng=32'h1BADB002, backpressure_rng=32'hCAFE1234;
    reg [31:0] initial_seed=0;
    reg packet_gate=0, byte_gate=0;
    integer attempt=0, j, sim_ticks=0;
    reg [63:0] random_data;
    function [31:0] step(input [31:0] x);
        reg [31:0] v;
        begin v=x^(x<<13); v=v^(v>>17); step=v^(v<<5); end
    endfunction
    function [7:0] frame_byte(input [163:0] word, input integer n);
        reg [63:0] ts, data;
        reg [28:0] id;
        reg [3:0] dlc;
        reg ide,rtr,crc_ok;
        begin
            {ts,data,id,dlc,ide,rtr,crc_ok}=word;
            frame_byte=0;
            case(n)
                1: frame_byte={5'b0,crc_ok,rtr,ide};
                2: frame_byte={4'b0,dlc};
                4: frame_byte={3'b0,id[28:24]};
                5: frame_byte=id[23:16];
                6: frame_byte=id[15:8];
                7: frame_byte=id[7:0];
                8: frame_byte=ts[63:56];
                9: frame_byte=ts[55:48];
                10: frame_byte=ts[47:40];
                11: frame_byte=ts[39:32];
                12: frame_byte=ts[31:24];
                13: frame_byte=ts[23:16];
                14: frame_byte=ts[15:8];
                15: frame_byte=ts[7:0];
                16: frame_byte=data[7:0];
                17: frame_byte=data[15:8];
                18: frame_byte=data[23:16];
                19: frame_byte=data[31:24];
                20: frame_byte=data[39:32];
                21: frame_byte=data[47:40];
                22: frame_byte=data[55:48];
                23: frame_byte=data[63:56];
                default: frame_byte=0;
            endcase
        end
    endfunction
    can_frame_queue #(.DEPTH(QUEUE_DEPTH)) queue (
        .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_ready(in_ready),
        .in_id(in_id),.in_ide(in_ide),.in_rtr(in_rtr),.in_dlc(in_dlc),
        .in_data(in_data),.in_timestamp(in_timestamp),.in_crc_ok(1'b1),
        .out_valid(out_valid),.out_ready(out_ready),.out_id(out_id),
        .out_ide(out_ide),.out_rtr(out_rtr),.out_dlc(out_dlc),
        .out_data(out_data),.out_timestamp(out_timestamp),.out_crc_ok(out_crc_ok),
        .level(queue_level)
    );
    can_udp_payload_packetizer #(
        .MAX_FRAMES(8),.FLUSH_CYCLES(7),.FCAN_PROTOCOL_VERSION(2)
    ) packetizer (
        .clk(clk),.rst_n(rst_n),.session_id(32'hAA55CC33),
        .frame_valid(out_valid),.frame_ready(out_ready),
        .frame_id(out_id),.frame_ide(out_ide),.frame_rtr(out_rtr),
        .frame_dlc(out_dlc),.frame_data(out_data),
        .frame_timestamp(out_timestamp),.frame_crc_ok(out_crc_ok),
        .error_valid(1'b0),.error_code(8'd0),.error_timestamp(64'd0),
        .status_valid(1'b0),.status_flags(8'd0),
        .status_queue_level(8'd0),.status_queue_high_watermark(8'd0),
        .status_uptime_ticks(64'd0),.status_counters(128'd0),
        .packet_valid(packet_valid),.packet_ready(packet_ready),
        .packet_length(packet_length),.packet_sequence(packet_sequence),
        .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.tx_last(tx_last)
    );
    assign packet_ready=packet_gate;
    assign tx_ready=byte_gate;
    always @(negedge clk) begin
        backpressure_rng=step(backpressure_rng);
        packet_gate=(backpressure_rng[3:0] != 0);
        byte_gate=(backpressure_rng[7:6] != 0);
    end
    always @(posedge clk) if (rst_n) begin
        sim_ticks=sim_ticks+1;
        if(queue_level>QUEUE_DEPTH) $fatal(1,"seed=%h queue overflow",initial_seed);
        if(queue_level>high_watermark) high_watermark=queue_level;
        if(in_valid) begin
            if(in_ready) begin
                if(accepted>=target) $fatal(1,"too many accepted");
                expected[accepted]={in_timestamp,in_data,in_id,in_dlc,in_ide,in_rtr,1'b1};
                accepted=accepted+1;
            end else dropped=dropped+1;
        end
        if(packet_valid && packet_ready) begin
            announced_count=(packet_length-20)/32;
            if(packet_length!=20+32*announced_count || announced_count<1 ||
               announced_count>8 || packet_sequence!==packets)
                $fatal(1,"packet header metadata seed=%h seq=%0d count=%0d",initial_seed,
                       packet_sequence,announced_count);
        end
        if(tx_valid && tx_ready) begin
            if(pos<20) begin
                case(pos)
                    0: if(tx_data!==8'h46) $fatal(1,"magic");
                    1: if(tx_data!==8'h43) $fatal(1,"magic");
                    2: if(tx_data!==8'h41) $fatal(1,"magic");
                    3: if(tx_data!==8'h4e) $fatal(1,"magic");
                    4: if(tx_data!==2) $fatal(1,"version");
                    5: if(tx_data!==20) $fatal(1,"header length");
                    6: if(tx_data!==32) $fatal(1,"record length");
                    7: if(tx_data!==announced_count) $fatal(1,"record count");
                    12: if(tx_data!==8'hAA) $fatal(1,"session");
                    13: if(tx_data!==8'h55) $fatal(1,"session");
                    14: if(tx_data!==8'hCC) $fatal(1,"session");
                    15: if(tx_data!==8'h33) $fatal(1,"session");
                    default: begin end
                endcase
            end else begin
                if(emitted>=accepted || tx_data!==frame_byte(expected[emitted],(pos-20)%32))
                    $fatal(1,"seed=%h frame=%0d byte=%0d session=AA55CC33 sequence=%0d got=%02x expected=%02x",
                           initial_seed,emitted,(pos-20)%32,packets,tx_data,
                           frame_byte(expected[emitted],(pos-20)%32));
                if((pos-20)%32==31) emitted=emitted+1;
            end
            pos=pos+1;
            if(tx_last) begin
                if(pos!=20+32*announced_count)
                    $fatal(1,"packet size mismatch seed=%h",initial_seed);
                pos=0;
                packets=packets+1;
            end
        end
    end
    initial begin
        if($value$plusargs("SEED=%h",producer_rng)) begin end
        if($value$plusargs("FRAMES=%d",target)) begin end
        if(producer_rng==0 || target<1 || target>100000)
            $fatal(1,"invalid SEED/FRAMES");
        initial_seed=producer_rng;
        $display("stress seed=%h frames=%0d",initial_seed,target);
        repeat(5) @(negedge clk); rst_n=1;
        while(accepted<target) begin
            @(negedge clk);
            producer_rng=step(producer_rng);
            in_valid=(producer_rng[8:6] != 0);
            in_ide=producer_rng[0];
            in_rtr=producer_rng[1];
            in_dlc=producer_rng[5:2];
            in_id=in_ide ? producer_rng[28:0] : {18'd0,producer_rng[10:0]};
            random_data={step(producer_rng),step(step(producer_rng))};
            for(j=0;j<8;j=j+1)
                if(in_rtr || j>=in_dlc) random_data[j*8 +:8]=0;
            in_data=random_data;
            in_timestamp=sim_ticks+1;
            if(in_valid) attempt=attempt+1;
            @(posedge clk);
            #1;
        end
        @(negedge clk); in_valid=0;
        wait(emitted==target);
        repeat(10) @(negedge clk);
        if(accepted!=emitted || attempt!=accepted+dropped || high_watermark<QUEUE_DEPTH-1)
            $fatal(1,"seed=%h attempt=%0d accepted=%0d emitted=%0d drop=%0d high=%0d",
                   initial_seed,attempt,accepted,emitted,dropped,high_watermark);
        $display("[PASS] FCAN random stress seed=%h accepted=%0d dropped=%0d high=%0d packets=%0d",
                 initial_seed,accepted,dropped,high_watermark,packets);
        $finish;
    end
    initial begin #2000000000; $fatal(1,"stress timeout seed=%h accepted=%0d emitted=%0d",
                                      initial_seed,accepted,emitted); end
endmodule

module tb_fcan_random_stress_extended;
    tb_fcan_random_stress #(.DEFAULT_FRAMES(100000)) run();
endmodule
