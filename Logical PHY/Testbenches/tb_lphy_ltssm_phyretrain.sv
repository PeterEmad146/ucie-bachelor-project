`timescale 1ns / 1ps

module tb_lphy_ltssm_phyretrain();

    localparam int TIMEOUT_CYCLES = 100;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk, rst_n, en_phyretrain;
    
    logic local_retrain_trigger;
    logic [2:0] local_retrain_enc;
    
    logic pl_stallreq, lp_stallack;
    
    logic rx_retrain_init_req, rx_retrain_init_resp;
    logic rx_retrain_start_req, rx_retrain_start_resp;
    logic [2:0] rx_retrain_enc;
    
    logic tx_retrain_init_req, tx_retrain_init_resp;
    logic tx_retrain_start_req, tx_retrain_start_resp;
    logic [2:0] tx_retrain_enc;
    
    logic rdi_to_retrain, phy_in_retrain;
    logic exit_to_txselfcal, exit_to_speedidle;
    logic exit_to_repair, exit_to_trainerror;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_ltssm_phyretrain #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) dut (.*);

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
        $display("Starting Verification: lphy_ltssm_phyretrain");
        $display("==========================================================");

        rst_n = 0; en_phyretrain = 0; local_retrain_trigger = 0;
        local_retrain_enc = 3'b001; lp_stallack = 0;
        rx_retrain_init_req = 0; rx_retrain_init_resp = 0;
        rx_retrain_start_req = 0; rx_retrain_start_resp = 0; rx_retrain_enc = 3'b001;
        
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: The "Simultaneous Crossover" Deadlock Fix
        // =====================================================================
        $display("TEST 1: Simultaneous Retrain Crossover Resolution...");
        en_phyretrain = 1'b1;
        local_retrain_trigger = 1'b1;
        local_retrain_enc = 3'b100; // We want REPAIR
        
        // Ensure pl_stallreq asserts
        @(negedge clk); // Wait for the clock edge so state becomes ST_LOC_STALL
        if (!pl_stallreq) begin $error("TEST 1 FAILED: Did not assert pl_stallreq."); error_count++; end
        
        @(negedge clk);
        lp_stallack = 1'b1; // Adapter acks the stall
        
        @(negedge clk);
        // State is now ST_LOC_INIT_REQ. It sends tx_req combinatorially.
        #1;
        if (!tx_retrain_init_req) begin $error("TEST 1 FAILED: Did not send tx_retrain_init_req."); error_count++; end
        local_retrain_trigger = 1'b0;
        
        // SIMULATE CROSSOVER: While we are waiting for Init.Resp, the remote PHY sends an Init.Req!
        @(negedge clk); // State is ST_LOC_WAIT_RESP
        rx_retrain_init_req = 1'b1; 
        
        #1;
        // The PHY should immediately resolve the crossover by firing an Init.Resp combinatorially
        if (!tx_retrain_init_resp) begin $error("TEST 1 FAILED: Did not send Init.Resp to resolve crossover!"); error_count++; end
        
        @(negedge clk); // State becomes ST_LOC_START_REQ
        rx_retrain_init_req = 1'b0;
        
        #1;
        // We are now in ST_LOC_START_REQ. It sends start req combinatorially.
        if (!tx_retrain_start_req) begin $error("TEST 1 FAILED: Did not send tx_retrain_start_req."); error_count++; end
        
        // Remote PHY acknowledges our Start
        pulse_done(rx_retrain_start_resp);
        
        #1; // We are in ST_DONE
        // Verify RDI Stall remained high the entire time
        if (!pl_stallreq) begin $error("TEST 1 FAILED: pl_stallreq dropped prematurely before exiting!"); error_count++; end
        
        // Check priority resolution (We wanted REPAIR(100), Remote sent default (001), resolved = 100)
        if (!exit_to_repair) begin $error("TEST 1 FAILED: Priority resolution failed. Expected exit to REPAIR."); error_count++; end
        else $display("   [PASS] Test 1: Crossover priority resolved successfully.");
        
        en_phyretrain = 1'b0;
        lp_stallack = 1'b0;
        @(negedge clk); @(negedge clk); // Wait to return to IDLE

        // =====================================================================
        // TEST 2: Remote Initiated Flow
        // =====================================================================
        $display("\nTEST 2: Remote Initiated Retrain Flow...");
        en_phyretrain = 1'b1;
        
        pulse_done(rx_retrain_init_req);
        // State is now ST_REM_STALL
        
        lp_stallack = 1'b1; // Adapter acks stall
        @(negedge clk); // State becomes ST_REM_INIT_RESP
        
        #1;
        if (!tx_retrain_init_resp) begin $error("TEST 2 FAILED: Did not send Init.Resp."); error_count++; end
        
        @(negedge clk); // State becomes ST_REM_WAIT_REQ
        
        // Remote wants SPEEDIDLE (010)
        rx_retrain_enc = 3'b010;
        @(negedge clk);
        rx_retrain_start_req = 1'b1; // Apply request
        
        @(negedge clk); // State becomes ST_REM_START_RESP
        #1; // Evaluate combinational outputs
        if (!tx_retrain_start_resp) begin $error("TEST 2 FAILED: Did not send Start.Resp."); error_count++; end
        if (tx_retrain_enc !== 3'b010) begin $error("TEST 2 FAILED: Start.Resp encoding did not match resolved (SPEEDIDLE)."); error_count++; end
        
        rx_retrain_start_req = 1'b0; // Clear request
        
        @(negedge clk); // State becomes ST_DONE
        if (!exit_to_speedidle) begin $error("TEST 2 FAILED: Did not exit to SPEEDIDLE."); error_count++; end
        else $display("   [PASS] Test 2: Remote initiated flow completed successfully.");
        
        en_phyretrain = 1'b0;
        lp_stallack = 1'b0;
        @(negedge clk); @(negedge clk);

        $display("==========================================================");
        if (error_count == 0) $display("SUCCESS: lphy_ltssm_phyretrain passed all StallReq and Crossover tests.");
        else $display("FAILED: %0d errors detected.", error_count);
        $display("==========================================================");
        $finish;
    end
endmodule