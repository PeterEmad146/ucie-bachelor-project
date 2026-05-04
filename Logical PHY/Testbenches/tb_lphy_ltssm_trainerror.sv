`timescale 1ns / 1ps

module tb_lphy_ltssm_trainerror();

    localparam int TIMEOUT_CYCLES = 100;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk, rst_n, en_trainerror;
    
    logic rx_trainerror_req, rx_trainerror_resp;
    logic rdi_in_linkerror;
    
    logic tx_trainerror_req, tx_trainerror_resp;
    logic exit_to_reset;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_ltssm_trainerror #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) dut (.*);

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
        $display("Starting Verification: lphy_ltssm_trainerror");
        $display("==========================================================");

        rst_n = 0; en_trainerror = 0; 
        rx_trainerror_req = 0; rx_trainerror_resp = 0; rdi_in_linkerror = 0;
        
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: The "Early Request" Pulse Capture
        // =====================================================================
        $display("TEST 1: Remote Initiated Early Pulse...");
        
        pulse_done(rx_trainerror_req);
        
        en_trainerror = 1'b1;
        rdi_in_linkerror = 1'b1; 
        
        @(negedge clk); // Wait 1 cycle to enter ST_SEND_RESP
        #1; 
        if (!tx_trainerror_resp) begin $error("TEST 1 FAILED: Did not remember early pulse and send Resp."); error_count++; end
        if (tx_trainerror_req) begin $error("TEST 1 FAILED: Incorrectly sent Req instead of Resp."); error_count++; end
        
        @(negedge clk);
        #1;
        if (exit_to_reset) begin $error("TEST 1 FAILED: Exited prematurely while RDI was in LinkError."); error_count++; end
        
        @(negedge clk);
        rdi_in_linkerror = 1'b0; 
        
        @(negedge clk);
        @(negedge clk); // Add 1 extra cycle to transition ST_WAIT_RDI -> ST_DONE
        if (!exit_to_reset) begin $error("TEST 1 FAILED: Did not transition to RESET after RDI cleared."); error_count++; end
        else $display("   [PASS] Test 1: Handled early request and waited for RDI safely.");
        
        en_trainerror = 1'b0;
        @(negedge clk); @(negedge clk); // Wait to return to IDLE

        // =====================================================================
        // TEST 2: Local Initiated Error with 8ms Timeout
        // =====================================================================
        $display("TEST 2: Local Error + Timeout...");
        en_trainerror = 1'b1;
        rdi_in_linkerror = 1'b0; // Adapter is fine
        
        @(negedge clk); // Wait for state to enter ST_SEND_REQ
        
        #1;
        if (!tx_trainerror_req) begin $error("TEST 2 FAILED: Did not send TX_REQ."); error_count++; end
        
        // Do NOT send a response. Wait for timeout.
        repeat(TIMEOUT_CYCLES + 5) @(negedge clk);
        
        #1;
        if (!exit_to_reset) begin $error("TEST 2 FAILED: Did not exit to reset after timeout."); error_count++; end
        else $display("   [PASS] Test 2: Local Error timed out and recovered.");
        
        en_trainerror = 1'b0;
        @(negedge clk); @(negedge clk); // Wait to return to IDLE

        // =====================================================================
        // TEST 3: Simultaneous Crossover Resolution
        // =====================================================================
        $display("TEST 3: Simultaneous Crossover...");
        en_trainerror = 1'b1;
        
        // 1. Wait for state machine to move: IDLE -> ST_SEND_REQ
        @(negedge clk); 
        
        // 2. Wait for state machine to move: ST_SEND_REQ -> ST_WAIT_RESP
        @(negedge clk); 
        
        // Now we are safely in ST_WAIT_RESP. 
        // Remote PHY suddenly sends a Req instead of a Resp!
        rx_trainerror_req = 1'b1;
        
        // Wait 1ns for combinational logic to propagate
        #1; 
        if (!tx_trainerror_resp) begin $error("TEST 3 FAILED: Did not resolve crossover by sending Resp."); error_count++; end
        
        // FIXED: Wait for the clock to actually tick so the state machine registers the transition!
        @(negedge clk); 
        rx_trainerror_req = 1'b0; // Safely drop it after the state machine has seen it
        
        // 3. State machine is now moving: ST_WAIT_RDI -> ST_DONE
        @(negedge clk); 
        
        // Wait 1ns for combinational exit_to_reset flag to propagate
        #1; 
        if (!exit_to_reset) begin $error("TEST 3 FAILED: Did not instantly exit to reset after crossover resolution."); error_count++; end
        
        
        $display("==========================================================");
        if (error_count == 0) $display("SUCCESS: lphy_ltssm_trainerror passed all edge-case tests.");
        else $display("FAILED: %0d errors detected.", error_count);
        $display("==========================================================");
        $finish;
    end
endmodule