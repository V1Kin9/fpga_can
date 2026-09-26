`timescale 1ns/1ps
module tb_can_udp_pipeline_v2;
    reg clk=0, rst_n=0, cdc_protocol_error=0;
    always #10 clk=~clk;
    wire bus, can_tx, packet_valid, tx_valid, tx_last, frame_drop_event;
    wire [15:0] packet_length, queue_level;
    wire [31:0] packet_sequence;
    wire [7:0] tx_data;
    integer pos=0, announced_count=0, frames=0, errors=0, statuses=0;
    reg [7:0] rec[0:31];
    integer i;
    can_frame_encoder gen(clk,bus);
    can_udp_pipeline_top #(
        .QUEUE_DEPTH(8),.MAX_FRAMES_PER_PACKET(2),.FLUSH_CYCLES(20),
        .FCAN_PROTOCOL_VERSION(2),.STATUS_INTERVAL_CYCLES(50000)
    ) dut (
        .clk_50m(clk),.rst_n(rst_n),.can_rx(bus),.can_tx(can_tx),
        .session_id(32'hAABBCCDD),.cdc_protocol_error(cdc_protocol_error),
        .mac_underrun_count(16'd7),
        .packet_valid(packet_valid),.packet_ready(1'b1),
        .packet_length(packet_length),.packet_sequence(packet_sequence),
        .tx_valid(tx_valid),.tx_ready(1'b1),.tx_data(tx_data),.tx_last(tx_last),
        .queue_level(queue_level),.frame_drop_event(frame_drop_event)
    );
    always @(posedge clk) if (rst_n) begin
        if(!can_tx || frame_drop_event) $fatal(1,"CAN passive/drop invariant");
        if(packet_valid) announced_count=(packet_length-20)/32;
        if(tx_valid) begin
            if(pos<20) begin
                case(pos)
                    4: if(tx_data!==2) $fatal(1,"v2 version");
                    5: if(tx_data!==20) $fatal(1,"v2 header");
                    6: if(tx_data!==32) $fatal(1,"v2 record length");
                    7: if(tx_data!==announced_count) $fatal(1,"v2 count");
                    12: if(tx_data!==8'hAA) $fatal(1,"session");
                    13: if(tx_data!==8'hBB) $fatal(1,"session");
                    14: if(tx_data!==8'hCC) $fatal(1,"session");
                    15: if(tx_data!==8'hDD) $fatal(1,"session");
                    default: begin end
                endcase
            end else begin
                rec[(pos-20)%32]=tx_data;
                if((pos-20)%32==31) begin
                    case(rec[0])
                        0: begin
                            if(rec[1]!==4 || rec[2]!==8 || rec[6]!==8'h01 ||
                               rec[7]!==8'h23 || rec[16]!==8'h11 || rec[23]!==8'h88)
                                $fatal(1,"CAN_FRAME integrated payload mismatch");
                            frames=frames+1;
                        end
                        1: begin
                            if(rec[1]!==2) $fatal(1,"CAN_ERROR code mismatch");
                            errors=errors+1;
                        end
                        2: begin
                            if({rec[16],rec[17]}!==16'd1 ||
                               {rec[18],rec[19]}!==16'd1 ||
                               {rec[26],rec[27]}!==16'd1 ||
                               {rec[28],rec[29]}!==16'd7)
                                $fatal(1,"DEVICE_STATUS counters mismatch rx=%h%h crc=%h%h cdc=%h%h mac=%h%h",
                                       rec[16],rec[17],rec[18],rec[19],rec[26],rec[27],rec[28],rec[29]);
                            statuses=statuses+1;
                        end
                        default: $fatal(1,"unknown integrated record type %0d",rec[0]);
                    endcase
                end
            end
            pos=pos+1;
            if(tx_last) begin
                if(pos!=20+32*announced_count) $fatal(1,"FCAN packet length");
                pos=0;
            end
        end
    end
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        repeat(1200) @(negedge clk);
        gen.build_standard(11'h123,0,8,64'h8877665544332211,0,0,0);
        gen.transmit(0);
        gen.build_standard(11'h321,0,1,64'hA5,1,0,0);
        gen.transmit(0);
        @(negedge clk); cdc_protocol_error=1;
        @(negedge clk); cdc_protocol_error=0;
        wait(statuses>=1);
        if(frames!=1 || errors!=1 || statuses!=1)
            $fatal(1,"integrated v2 counts %0d/%0d/%0d",frames,errors,statuses);
        $display("[PASS] CAN parser to FCAN v2 frame/error/status with CDC/MAC diagnostic counts");
        $finish;
    end
    initial begin #5000000; $fatal(1,"integrated v2 timeout"); end
endmodule
