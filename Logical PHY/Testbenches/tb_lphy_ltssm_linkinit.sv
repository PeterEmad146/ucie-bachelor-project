`timescale 1ns / 1ps

module tb_lphy_ltssm_linkinit();

    localparam int TIMEOUT_CYCLES = 100;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk, rst_n, en_linkinit;
    logic [3:0] lp_state_req;
    
    logic rx_req_active, rx_rsp_active;
    logic tx_req_active, tx_rsp_active;
    logic lfsr_reset, clear_start_training;
    logic exit_to_active, exit_to_trainerror;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_ltssm_linkinit #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) dut (.*);

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
        $display("Starting Verification: lphy_ltssm_linkinit");
        $display("==========================================================");

        rst_n = 0; en_linkinit = 0; lp_state_req = 4'b0000;
        rx_req_active = 0; rx_rsp_active = 0;
        
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: The "Early Request" Deadlock Scenario
        // =====================================================================
        $display("TEST 1: Simulating early remote request (Testing Deadlock Fix)...");
        
        en_linkinit = 1'b1;
        
        #1; // Wait 1ns for combinatorial logic to propagate
        if (!lfsr_reset) begin $error("TEST 1 FAILED: Did not pulse lfsr_reset upon entry."); error_count++; end
        
        @(negedge clk); // NOW let the clock tick to advance the state machine
        
        // We are now in ST_WAIT_ADAPTER.
        // The remote PHY finishes early and sends us a Req.Active!
        pulse_done(rx_req_active);
        
        // Ensure we haven't prematurely moved states or sent our request
        if (tx_req_active || tx_rsp_active) begin 
            $error("TEST 1 FAILED: Prematurely sent TX messages while waiting for Adapter."); 
            error_count++; 
        end
        
        // Now, the Adapter finally wakes up and asks to go to ACTIVE.
        @(negedge clk);
        lp_state_req = 4'b0001;
        
        // We enter ST_HANDSHAKE. It should immediately send Req AND Rsp (because it remembered the early rx_req).
        @(negedge clk);
        if (!tx_req_active || !tx_rsp_active) begin 
            $error("TEST 1 FAILED: Did not send both Req and Rsp! Early request was forgotten/deadlocked."); 
            error_count++; 
        end
        
        // Remote PHY acknowledges our request
        pulse_done(rx_rsp_active);
        
        // State machine should immediately move to DONE
        @(negedge clk);
        if (!exit_to_active || !clear_start_training) begin 
            $error("TEST 1 FAILED: Did not successfully transition to ACTIVE."); 
            error_count++; 
        end else $display("   [PASS] Test 1: Completed handshake with early request memory.");
        
        en_linkinit = 1'b0;
        lp_state_req = 4'b0000;
        @(negedge clk); @(negedge clk); // Wait for FSM to return to IDLE

        // =====================================================================
        // TEST 2: Timeout Condition
        // =====================================================================
        $display("TEST 2: Timeout Condition...");
        en_linkinit = 1'b1;
        
        // Wait in ST_WAIT_ADAPTER until timeout triggers
        repeat(TIMEOUT_CYCLES + 5) @(negedge clk);
        
        if (!exit_to_trainerror) begin 
            $error("TEST 2 FAILED: Did not exit to TRAINERROR after timeout."); 
            error_count++; 
        end else $display("   [PASS] Test 2: Timeout correctly triggered TRAINERROR.");
        
        en_linkinit = 1'b0;
        @(negedge clk); @(negedge clk);

        $display("==========================================================");
        if (error_count == 0) $display("SUCCESS: lphy_ltssm_linkinit passed all asynchronous handshake and timeout tests.");
        else $display("FAILED: %0d errors detected.", error_count);
        $display("==========================================================");
        $finish;
    end
endmodule