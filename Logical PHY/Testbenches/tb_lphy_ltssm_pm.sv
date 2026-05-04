`timescale 1ns / 1ps

module tb_lphy_ltssm_pm();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk, rst_n;
    logic en_l1, en_l2;
    
    logic [3:0] lp_state_req;
    logic [3:0] pl_state_sts;
    
    logic rx_req_active, rx_rsp_active;
    logic tx_req_active, tx_rsp_active;
    
    logic exit_to_speedidle, exit_to_reset;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_ltssm_pm dut (.*);

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
        $display("Starting Verification: lphy_ltssm_pm");
        $display("==========================================================");

        rst_n = 0; en_l1 = 0; en_l2 = 0; lp_state_req = 4'h0;
        rx_req_active = 0; rx_rsp_active = 0;
        
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: L1 Sleep -> Local Adapter Wake-Up Handshake
        // =====================================================================
        $display("TEST 1: L1 Local Wake-Up...");
        en_l1 = 1'b1;
        @(negedge clk);
        
        if (pl_state_sts !== 4'b0100) begin $error("TEST 1 FAILED: Did not assert L1 status to Adapter."); error_count++; end
        
        // Local Adapter wants to wake up
        lp_state_req = 4'b0001; 
        #1;
        if (!tx_req_active) begin $error("TEST 1 FAILED: Did not send TX_REQ_ACTIVE."); error_count++; end
        
        @(negedge clk);
        lp_state_req = 4'b0000;
        
        // Wait for remote to reply
        if (exit_to_speedidle) begin $error("TEST 1 FAILED: Exited prematurely without handshake."); error_count++; end
        
        pulse_done(rx_rsp_active);
        
        #1;
        if (!exit_to_speedidle) begin $error("TEST 1 FAILED: Did not exit to SPEEDIDLE after handshake."); error_count++; end
        else $display("   [PASS] Test 1: L1 Local Wake-Up completed successfully.");
        
        en_l1 = 1'b0;
        @(negedge clk); @(negedge clk);

        // =====================================================================
        // TEST 2: L2 Sleep -> Remote PHY Wake-Up Handshake
        // =====================================================================
        $display("\nTEST 2: L2 Remote Wake-Up...");
        en_l2 = 1'b1;
        @(negedge clk);
        
        if (pl_state_sts !== 4'b1000) begin $error("TEST 2 FAILED: Did not assert L2 status to Adapter."); error_count++; end
        
        // Remote PHY sends a wake request!
        rx_req_active = 1'b1;
        #1;
        
        if (!tx_rsp_active) begin $error("TEST 2 FAILED: Did not immediately reply with TX_RSP_ACTIVE."); error_count++; end
        
        @(negedge clk);
        rx_req_active = 1'b0;
        
        #1;
        if (!exit_to_reset) begin $error("TEST 2 FAILED: L2 wake-up did not exit to RESET."); error_count++; end
        else $display("   [PASS] Test 2: L2 Remote Wake-Up completed successfully.");
        
        en_l2 = 1'b0;
        @(negedge clk); @(negedge clk);

        $display("==========================================================");
        if (error_count == 0) $display("SUCCESS: lphy_ltssm_pm passed all Power Management handshake tests.");
        else $display("FAILED: %0d errors detected.", error_count);
        $display("==========================================================");
        $finish;
    end
endmodule