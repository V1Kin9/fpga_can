`timescale 1ns/1ps
module tb_can_rx_top;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0;
    wire bus;
    wire frame_valid,frame_ide,frame_rtr,crc_ok,stuff_error,form_error;
    wire frame_error,error_valid;
    wire [28:0] frame_id;
    wire [3:0] frame_dlc;
    wire [63:0] frame_data;
    wire [63:0] frame_timestamp, fifo_timestamp, fifo_data;
    wire [7:0] error_code;
    wire fifo_valid, fifo_ide, fifo_rtr, fifo_crc_ok, fifo_overflow;
    wire [28:0] fifo_id;
    wire [3:0] fifo_dlc;
    wire debug_sample_tick, debug_bit;
    wire [4:0] debug_state;
    can_frame_encoder gen(clk,bus);
    can_rx_top dut(
        .clk_50m(clk),.rst_n(rst_n),.can_rx(bus),
        .frame_valid(frame_valid),.frame_id(frame_id),.frame_ide(frame_ide),
        .frame_rtr(frame_rtr),.frame_dlc(frame_dlc),.frame_data(frame_data),
        .frame_timestamp(frame_timestamp),
        .crc_ok(crc_ok),.stuff_error(stuff_error),.form_error(form_error),
        .frame_error(frame_error),.error_valid(error_valid),.error_code(error_code),
        .fifo_ready(1'b1),.fifo_valid(fifo_valid),.fifo_id(fifo_id),
        .fifo_ide(fifo_ide),.fifo_rtr(fifo_rtr),.fifo_dlc(fifo_dlc),
        .fifo_data(fifo_data),.fifo_timestamp(fifo_timestamp),
        .fifo_crc_ok(fifo_crc_ok),.fifo_overflow(fifo_overflow),
        .debug_sample_tick(debug_sample_tick),.debug_bit(debug_bit),
        .debug_state(debug_state)
    );
    integer frames=0,errors=0,fifo_count=0;
    reg last_crc_ok=0;
    reg prior_frame_valid=0;
    reg [63:0] expected_sof_ts=0, last_frame_ts=0;
    reg [7:0] last_error=0;
    always @(posedge clk) begin
        if(dut.u_sync.edge_detect && dut.u_parser.hard_sync_enable)
            expected_sof_ts=dut.timestamp_counter;
        if(frame_valid) begin
            if(prior_frame_valid || frame_timestamp!==expected_sof_ts ||
               (frames>0 && frame_timestamp<=last_frame_ts))
                $fatal(1,"frame pulse/timestamp error got=%0d expected=%0d",
                       frame_timestamp,expected_sof_ts);
            frames=frames+1;
            last_crc_ok=crc_ok;
            last_frame_ts=frame_timestamp;
        end
        prior_frame_valid=frame_valid;
        if(fifo_valid && fifo_overflow)
            $fatal(1,"unexpected FIFO overflow");
        if(fifo_valid) begin
            if(fifo_id!==frame_id || fifo_ide!==frame_ide ||
               fifo_rtr!==frame_rtr || fifo_dlc!==frame_dlc ||
               fifo_data!==frame_data || fifo_timestamp!==frame_timestamp ||
               !fifo_crc_ok)
                $fatal(1,"FIFO payload differs from completed frame");
            fifo_count=fifo_count+1;
        end
        if(error_valid) begin
            errors=errors+1; last_error=error_code;
        end
    end
    task expect_frame(input integer expected_count,input reg [28:0] id,
                      input reg [3:0] dlc,input reg [63:0] data);
        begin
            if(frames!=expected_count || fifo_count!=expected_count || frame_id!==id ||
               frame_dlc!==dlc || frame_data!==data || !last_crc_ok)
                $fatal(1,"frame count=%0d id=%h dlc=%0d data=%h crc_ok=%b",
                       frames,frame_id,frame_dlc,frame_data,last_crc_ok);
        end
    endtask
    task expect_error(input integer expected_errors, input reg [7:0] code);
        begin
            if(frames!=4 || errors!=expected_errors || last_error!=code)
                $fatal(1,"error check frames=%0d errors=%0d code=%h, expected %0d/%h",
                       frames,errors,last_error,expected_errors,code);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        repeat(1200) @(negedge clk);
        gen.build_standard(11'h123,0,8,64'h8877665544332211,0,0,0);
        gen.transmit(0);
        repeat(5) @(negedge clk);
        expect_frame(1,29'h123,8,64'h8877665544332211);
        $display("[PASS] TC01 Standard Frame");

        gen.build_standard(11'h321,0,0,0,0,0,0);
        gen.transmit(0);
        repeat(5) @(negedge clk);
        expect_frame(2,29'h321,0,0);
        $display("[PASS] TC02 DLC0");

        gen.build_standard(11'h123,0,1,64'hA5,0,0,0);
        gen.transmit(0);
        repeat(5) @(negedge clk);
        expect_frame(3,29'h123,1,64'hA5);
        $display("[PASS] TC03 DLC1");

        gen.build_standard(11'h000,0,8,64'h0000ffff0000ffff,0,0,0);
        gen.transmit(0);
        repeat(5) @(negedge clk);
        expect_frame(4,29'h000,8,64'h0000ffff0000ffff);
        $display("[PASS] TC05 Stuffing");

        gen.build_standard(11'h000,0,8,64'h0000ffff0000ffff,0,1,0);
        gen.transmit(0);
        repeat(1200) @(negedge clk);
        expect_error(1,8'h01);
        $display("[PASS] TC06 Stuff Error");

        gen.build_standard(11'h123,0,1,64'hA5,1,0,0);
        gen.transmit(0);
        repeat(1200) @(negedge clk);
        expect_error(2,8'h02);
        $display("[PASS] TC07 CRC Error");

        gen.build_standard(11'h123,0,1,64'hA5,0,0,1);
        gen.transmit(0);
        repeat(1200) @(negedge clk);
        expect_error(3,8'h03);
        gen.build_standard(11'h123,0,1,64'hA5,0,0,2);
        gen.transmit(0);
        repeat(1200) @(negedge clk);
        expect_error(4,8'h03);
        gen.build_standard(11'h123,0,1,64'hA5,0,0,3);
        gen.transmit(0);
        repeat(1200) @(negedge clk);
        expect_error(5,8'h03);
        $display("[PASS] TC08 Form Error (CRC delimiter, ACK delimiter, EOF)");

        gen.build_standard(11'h123,0,9,64'h8877665544332211,0,0,0);
        gen.transmit(0);
        repeat(1200) @(negedge clk);
        expect_error(6,8'h04);
        $display("[PASS] DLC Error");

        gen.build_standard(11'h321,0,0,0,0,0,0);
        gen.transmit(0);
        repeat(5) @(negedge clk);
        if(frames!=5 || frame_id!=29'h321)
            $fatal(1,"recovery failed after injected errors");
        $display("[PASS] Error recovery");

        gen.build_extended(29'h18DAF110,0,8,64'h0807060504030201);
        gen.transmit(0);
        repeat(5) @(negedge clk);
        if(frames!=6 || frame_id!=29'h18DAF110 || !frame_ide ||
           frame_rtr || frame_dlc!=8 || frame_data!=64'h0807060504030201 ||
           !last_crc_ok)
            $fatal(1,"extended frame id=%h ide=%b rtr=%b data=%h",
                   frame_id,frame_ide,frame_rtr,frame_data);
        $display("[PASS] TC04 Extended Frame");

        gen.build_standard(11'h456,1,4,0,0,0,0);
        gen.transmit(0);
        repeat(5) @(negedge clk);
        if(frames!=7 || frame_id!=29'h456 || frame_ide || !frame_rtr ||
           frame_dlc!=4 || frame_data!=0 || !last_crc_ok)
            $fatal(1,"standard remote frame failed");
        gen.build_extended(29'h1ABCDE3,1,2,0);
        gen.transmit(0);
        repeat(5) @(negedge clk);
        if(frames!=8 || frame_id!=29'h1ABCDE3 || !frame_ide || !frame_rtr ||
           frame_dlc!=2 || frame_data!=0 || !last_crc_ok)
            $fatal(1,"extended remote frame failed");
        $display("[PASS] Standard and extended Remote Frames");
        if(fifo_count!=8 || last_frame_ts==0)
            $fatal(1,"timestamp/FIFO count mismatch");
        $display("[PASS] SOF timestamp and single-cycle frame/FIFO events");

        gen.build_standard(11'h101,0,0,0,0,0,0); gen.transmit(0);
        gen.build_standard(11'h102,0,1,64'h5a,0,0,0); gen.transmit(0);
        gen.build_standard(11'h103,0,0,0,0,0,0); gen.transmit(0);
        repeat(5) @(negedge clk);
        if(frames!=11 || fifo_count!=11 || frame_id!=29'h103)
            $fatal(1,"back-to-back frames=%0d fifo=%0d last=%h",
                   frames,fifo_count,frame_id);
        $display("[PASS] TC09 Back-to-back Frames");

        gen.build_standard(11'h234,0,8,64'h0123456789abcdef,0,0,0);
        gen.transmit(-1);
        repeat(5) @(negedge clk);
        if(frames!=12 || frame_id!=29'h234 || frame_data!=64'h0123456789abcdef)
            $fatal(1,"-0.5%% clock offset failed frames=%0d id=%h",frames,frame_id);
        gen.build_standard(11'h235,0,8,64'hfedcba9876543210,0,0,0);
        gen.transmit(1);
        repeat(5) @(negedge clk);
        if(frames!=13 || frame_id!=29'h235 || frame_data!=64'hfedcba9876543210)
            $fatal(1,"+0.5%% clock offset failed frames=%0d id=%h",frames,frame_id);
        $display("[PASS] TC10 Clock Offset -0.5%% / +0.5%%");
        $finish;
    end
endmodule
