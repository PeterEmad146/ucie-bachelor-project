`timescale 1ns / 1ps

module tb_lphy_valid_deframer();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    
    logic [7:0] valid_frame_in;
    
    logic lane_valid;
    logic credit_return;
    logic framing_err;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_valid_deframer dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    int error_count = 0;

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_valid_deframer");
        $display("==========================================================");

        // Reset
        rst_n = 0;
        valid_frame_in = 8'h00;
        @(negedge clk);
        rst_n = 1;
        
        // =====================================================================
        // TEST 1: Legal Frame - Idle (0000_0000)
        // =====================================================================
        valid_frame_in = 8'b0000_0000;
        @(negedge clk);
        
        if (lane_valid !== 0 || credit_return !== 0 || framing_err !== 0) begin
            $error("TEST 1 FAILED: Expected Idle (0,0). Got v=%b, c=%b, err=%b", lane_valid, credit_return, framing_err);
            error_count++;
        end

        // =====================================================================
        // TEST 2: Legal Frame - Valid + No Credit (0000_1111)
        // =====================================================================
        valid_frame_in = 8'b0000_1111;
        @(negedge clk);
        
        if (lane_valid !== 1 || credit_return !== 0 || framing_err !== 0) begin
            $error("TEST 2 FAILED: Expected Valid Only (1,0). Got v=%b, c=%b, err=%b", lane_valid, credit_return, framing_err);
            error_count++;
        end

        // =====================================================================
        // TEST 3: Legal Frame - No Valid + Credit (1111_0000)
        // =====================================================================
        valid_frame_in = 8'b1111_0000;
        @(negedge clk);
        
        if (lane_valid !== 0 || credit_return !== 1 || framing_err !== 0) begin
            $error("TEST 3 FAILED: Expected Credit Only (0,1). Got v=%b, c=%b, err=%b", lane_valid, credit_return, framing_err);
            error_count++;
        end

        // =====================================================================
        // TEST 4: Legal Frame - Valid + Credit (1111_1111)
        // =====================================================================
        valid_frame_in = 8'b1111_1111;
        @(negedge clk);
        
        if (lane_valid !== 1 || credit_return !== 1 || framing_err !== 0) begin
            $error("TEST 4 FAILED: Expected Valid + Credit (1,1). Got v=%b, c=%b, err=%b", lane_valid, credit_return, framing_err);
            error_count++;
        end

        // =====================================================================
        // TEST 5: Fault Injection - Single Bit Flip
        // =====================================================================
        // Take a legal "Valid Only" frame (0000_1111) and flip bit 3 to 0.
        valid_frame_in = 8'b0000_0111; 
        @(negedge clk);
        
        if (framing_err !== 1) begin
            $error("TEST 5 FAILED: Did not detect single bit-flip framing error.");
            error_count++;
        end
        // Verify the Firewall logic successfully squashed the outputs to 0
        if (lane_valid !== 0 || credit_return !== 0) begin
            $error("TEST 5 FAILED: Digital firewall failed to squash corrupted frame! Got v=%b, c=%b", lane_valid, credit_return);
            error_count++;
        end

        // =====================================================================
        // TEST 6: Error Recovery
        // =====================================================================
        // Immediately follow the error with a clean "Idle" frame
        valid_frame_in = 8'b0000_0000;
        @(negedge clk);
        
        if (framing_err !== 0) begin
            $error("TEST 6 FAILED: framing_err flag got stuck high and did not recover.");
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_valid_deframer passed all decoding and fault-injection tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule