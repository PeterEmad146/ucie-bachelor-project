`timescale 1ns / 1ps

module tb_lphy_ltssm_active();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk, rst_n, en_active;
    logic [3:0] lp_state_req;
    logic lp_linkerror, internal_retrain_req, internal_error_req;
    logic [3:0] pl_state_sts;
    
    logic rx_req_l1, rx_rsp_l1, rx_req_l2, rx_rsp_l2;
    logic rx_req_linkreset, rx_rsp_linkreset, rx_req_disable, rx_rsp_disable;
    logic rx_req_retrain, rx_rsp_retrain, rx_req_linkerror;
    
    logic tx_req_l1, tx_rsp_l1, tx_req_l2, tx_rsp_l2;
    logic tx_req_linkreset, tx_rsp_linkreset, tx_req_disable, tx_rsp_disable;
    logic tx_req_retrain, tx_rsp_retrain, tx_req_linkerror;
    
    logic scrambling_en, exit_to_l1, exit_to_l2, exit_to_linkreset;
    logic exit_to_disable, exit_to_retrain, exit_to_trainerror;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_ltssm_active dut (.*);

    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    int error_count = 0;

    task automatic pulse_done(ref logic flag);
        @(negedge clk); flag = 1'b1;
        @(negedge clk); flag = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_ltssm_active");
        $display("==========================================================");

        rst_n = 0; en_active = 0; lp_state_req = 4'h0;
        lp_linkerror = 0; internal_retrain_req = 0; internal_error_req = 0;
        rx_req_l1 = 0; rx_rsp_l1 = 0; rx_req_l2 = 0; rx_rsp_l2 = 0;
        rx_req_linkreset = 0; rx_rsp_linkreset = 0; rx_req_disable = 0; rx_rsp_disable = 0;
        rx_req_retrain = 0; rx_rsp_retrain = 0; rx_req_linkerror = 0;
        
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: Steady State
        // =====================================================================
        en_active = 1'b1;
        @(negedge clk); // Allow state machine to register ACTIVE
        
        if (pl_state_sts !== 4'b0001 || !scrambling_en) begin 
            $error("TEST 1 FAILED: Did not assert ACTIVE status or enable scrambling."); 
            error_count++; 
        end else $display("   [PASS] Test 1: Steady State established.");

        // =====================================================================
        // TEST 2: Local Initiation Handshake (Adapter requests Retrain)
        // =====================================================================
        $display("\nTEST 2: Local Handshake (Retrain)...");
        @(negedge clk);
        lp_state_req = 4'b1011; // Retrain
        
        #1; // Check combinational output IMMEDIATELY before state advances
        if (!tx_req_retrain) begin $error("TEST 2 FAILED: Did not send TX_REQ."); error_count++; end
        
        @(negedge clk); // State registers WAIT_RSP, tx_req drops
        lp_state_req = 4'b0000;
        
        // At this point, we are waiting. Ensure we didn't exit early.
        if (exit_to_retrain) begin $error("TEST 2 FAILED: Exited prematurely without waiting for response."); error_count++; end
        
        pulse_done(rx_rsp_retrain); // Remote PHY grants request
        
        if (!exit_to_retrain) begin $error("TEST 2 FAILED: Did not exit to Retrain after receiving response."); error_count++; end
        else $display("   [PASS] Test 2: Local Handshake completed.");
        
        en_active = 1'b0; // Master LTSSM moves on
        @(negedge clk); @(negedge clk); // Wait to return to IDLE

        // =====================================================================
        // TEST 3: Remote Initiation Handshake (Remote requests L1)
        // =====================================================================
        $display("\nTEST 3: Remote Handshake (L1 Power Management)...");
        en_active = 1'b1;
        @(negedge clk); // Enter ACTIVE
        
        // Assert Remote Request
        rx_req_l1 = 1'b1;
        
        #1; // Check combinational handshake and exit flag immediately
        if (!tx_rsp_l1 || !exit_to_l1) begin 
            $error("TEST 3 FAILED: Did not immediately send TX_RSP and exit upon receiving remote RX_REQ."); 
            error_count++; 
        end else $display("   [PASS] Test 3: Remote Handshake handled instantly.");
        
        @(negedge clk); // State transitions to EXITING, tx_rsp drops
        rx_req_l1 = 1'b0;
        
        en_active = 1'b0;
        @(negedge clk); @(negedge clk); // Wait to return to IDLE

        // =====================================================================
        // TEST 4: Fatal Error Override
        // =====================================================================
        $display("\nTEST 4: Fatal Error Override...");
        en_active = 1'b1;
        @(negedge clk); // Enter ACTIVE
        
        // We are steady. Adapter requests L2 sleep.
        @(negedge clk);
        lp_state_req = 4'b1000; // L2
        
        // We are now waiting for the L2 response...
        @(negedge clk);
        lp_state_req = 4'b0000;
        
        // Suddenly, an internal framing error occurs!
        internal_error_req = 1'b1;
        @(negedge clk);
        internal_error_req = 1'b0;
        
        if (!tx_req_linkerror || !exit_to_trainerror) begin 
            $error("TEST 4 FAILED: Did not abort handshake to handle the Fatal Error!"); 
            error_count++; 
        end else $display("   [PASS] Test 4: Fatal error correctly overrode pending handshake.");
        
        en_active = 1'b0;
        @(negedge clk); @(negedge clk); // Wait to return to IDLE

        // =====================================================================
        // TEST 5: Collision Priority (Remote request over Local request)
        // =====================================================================
        $display("\nTEST 5: Remote vs Local Priority Collision...");
        en_active = 1'b1;
        @(negedge clk); // Enter ACTIVE
        
        // Adapter requests Disable, but remotely we receive a LinkReset at the EXACT same time!
        @(negedge clk);
        lp_state_req = 4'b1100; // Local: Disable
        rx_req_linkreset = 1'b1; // Remote: LinkReset
        
        @(negedge clk); // State registers EXITING based on Remote Priority
        lp_state_req = 4'b0000;
        rx_req_linkreset = 1'b0;
        
        if (!exit_to_linkreset) begin 
            $error("TEST 5 FAILED: Did not prioritize Remote LinkReset over Local Disable."); 
            error_count++; 
        end else if (exit_to_disable) begin
            $error("TEST 5 FAILED: Priority Inversion - Asserted exit_to_disable instead of linkreset!"); 
            error_count++; 
        end else $display("   [PASS] Test 5: Prioritized remote request correctly.");
        
        en_active = 1'b0;
        @(negedge clk); @(negedge clk);

        $display("\n==========================================================");
        if (error_count == 0) $display("SUCCESS: lphy_ltssm_active passed all handshake and error override tests.");
        else $display("FAILED: %0d errors detected.", error_count);
        $display("==========================================================");
        $finish;
    end
endmodule