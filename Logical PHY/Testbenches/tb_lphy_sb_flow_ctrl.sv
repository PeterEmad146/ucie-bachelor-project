`timescale 1ns / 1ps

module tb_lphy_sb_flow_ctrl();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    logic rdi_in_reset;
    
    logic req_valid;
    logic is_reg_req;
    logic is_reg_cpl;
    logic is_msg;
    
    logic tx_allowed;
    logic local_crd_ret;
    logic remote_crd_ret;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_sb_flow_ctrl #(
        .LOCAL_CREDITS_INIT(32)
    ) dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    int error_count = 0;

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_sb_flow_ctrl");
        $display("==========================================================");

        // Reset and Initialization
        rst_n = 0;
        rdi_in_reset = 0;
        req_valid = 0;
        is_reg_req = 0; is_reg_cpl = 0; is_msg = 0;
        local_crd_ret = 0; remote_crd_ret = 0;
        
        @(negedge clk);
        rst_n = 1;
        rdi_in_reset = 1; // RDI starts in reset
        @(negedge clk);
        rdi_in_reset = 0; // RDI exits reset, counters should be 32 and 4.
        @(negedge clk);

        // =====================================================================
        // TEST 1: Exhaust Remote Credits (Send 4 Register Requests)
        // =====================================================================
        req_valid  = 1;
        is_reg_req = 1;
        
        for (int i = 0; i < 4; i++) begin
            #1; // FIX: Allow combinational logic to update!
            if (!tx_allowed) begin
                $error("TEST 1 FAILED: tx_allowed dropped prematurely at iter %0d", i);
                error_count++;
            end
            @(negedge clk);
        end
        
        #1;
        // After 4 requests, remote credits = 0. Next request should be blocked.
        if (tx_allowed) begin
            $error("TEST 1 FAILED: tx_allowed should be 0 when remote credits are exhausted.");
            error_count++;
        end

        // =====================================================================
        // TEST 2: Completion Deadlock Avoidance
        // =====================================================================
        // Even though remote credits are 0, a Completion MUST be allowed.
        is_reg_req = 0;
        is_reg_cpl = 1;
        #1; // Allow combinational logic to resolve
        
        if (!tx_allowed) begin
            $error("TEST 2 FAILED: Completions MUST bypass flow control (Deadlock risk!).");
            error_count++;
        end
        @(negedge clk);
        is_reg_cpl = 0;

        // =====================================================================
        // TEST 3: Exhaust Local Credits (Send Messages)
        // =====================================================================
        // We used 4 local credits in Test 1. We have 28 left. 
        is_msg = 1;
        for (int i = 0; i < 28; i++) begin
            #1; // FIX: Allow combinational logic to update!
            if (!tx_allowed) begin
                $error("TEST 3 FAILED: tx_allowed dropped prematurely at iter %0d", i);
                error_count++;
            end
            @(negedge clk);
        end
        
        #1;
        // Local credits are now 0. Next message should block.
        if (tx_allowed) begin
            $error("TEST 3 FAILED: tx_allowed should be 0 when local credits are exhausted.");
            error_count++;
        end

        // =====================================================================
        // TEST 4: Credit Return & Simultaneous Exchange
        // =====================================================================
        req_valid = 0;
        is_msg = 0;
        
        // Return 1 Local and 1 Remote Credit
        local_crd_ret = 1;
        remote_crd_ret = 1;
        @(negedge clk);
        local_crd_ret = 0;
        remote_crd_ret = 0;
        
        // Test Simultaneous Consume and Return (Counter should stay at 1)
        req_valid = 1;
        is_reg_req = 1; // Requires both
        local_crd_ret = 1;
        remote_crd_ret = 1;
        #1;
        
        if (!tx_allowed) begin
            $error("TEST 4 FAILED: Credit return did not properly unlock tx_allowed.");
            error_count++;
        end
        
        @(negedge clk); // Consume 1, Return 1
        local_crd_ret = 0;
        remote_crd_ret = 0;
        #1;
        
        // Because they happened simultaneously, counters should still be 1.
        if (!tx_allowed) begin
            $error("TEST 4 FAILED: Simultaneous consume/return failed to hold counter steady.");
            error_count++;
        end
        
        req_valid = 0;
        @(negedge clk);

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_sb_flow_ctrl passed all exhaustion and return tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule