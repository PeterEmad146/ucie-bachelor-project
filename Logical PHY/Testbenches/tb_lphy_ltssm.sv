`timescale 1ns / 1ps

module tb_lphy_ltssm();

    // =========================================================================
    // 1. SIGNAL DECLARATIONS (Matching Top Module)
    // =========================================================================
    logic clk, rst_n;
    
    // RDI
    logic start_link_training;
    logic [3:0] lp_state_req;
    logic lp_linkerror, lp_stallack;
    wire [3:0] pl_state_sts;
    wire pl_inband_pres, pl_stallreq, rdi_to_retrain, phy_in_retrain;
    
    // Global Hardware
    logic power_stable, sb_clk_stable, mb_clk_stable, mb_clk_slow, soc_reset_n, package_type;
    
    // Sideband RX
    logic [3:0] rx_pattern_detected;
    logic rx_msg_out_of_reset, rx_msg_done_req, rx_msg_done_resp;
    logic rx_req_active, rx_rsp_active;
    logic rx_req_l1, rx_rsp_l1, rx_req_l2, rx_rsp_l2;
    logic rx_req_linkreset, rx_rsp_linkreset, rx_req_disable, rx_rsp_disable;
    logic rx_req_retrain, rx_rsp_retrain, rx_req_linkerror;
    logic rx_trainerror_req, rx_trainerror_resp;
    logic rx_retrain_init_req, rx_retrain_init_resp;
    logic rx_retrain_start_req, rx_retrain_start_resp;
    logic [2:0] rx_retrain_enc;
    
    // Sideband TX (DUT outputs — must be wire for assign-driven signals)
    wire tx_send_pattern, tx_msg_out_of_reset, tx_msg_done_req, tx_msg_done_resp;
    wire [2:0] sb_repair_sel;
    wire tx_req_active, tx_rsp_active, tx_req_l1, tx_rsp_l1, tx_req_l2, tx_rsp_l2;
    wire tx_req_linkreset, tx_rsp_linkreset, tx_req_disable, tx_rsp_disable;
    wire tx_req_retrain, tx_rsp_retrain, tx_req_linkerror;
    wire tx_trainerror_req, tx_trainerror_resp;
    wire tx_retrain_init_req, tx_retrain_init_resp;
    wire tx_retrain_start_req, tx_retrain_start_resp;
    wire [2:0] tx_retrain_enc;
    
    // Internal Repair/Cal
    logic param_done, cal_done, repairclk_done, repairval_done;
    logic reversal_done, repairmb_done, valvref_done, datavref_done;
    logic speedidle_done, txselfcal_done, rxclkcal_done, valtraincenter_done;
    logic valtrainvref_done, datatraincenter1_done, datatrainvref_done;
    logic rxdeskew_done, datatraincenter2_done, linkspeed_done;
    logic linkspeed_error, needs_repair, needs_speed_degrade, repair_done;
    logic cal_error, is_unrepairable, internal_retrain_req, internal_error_req;
    logic [2:0] local_retrain_enc;
    
    // Datapath Controls (DUT outputs — must be wire)
    wire phy_reset_active, lfsr_reset, clear_start_training, tx_training_en;
    wire scrambler_en, descrambler_en, repair_en;
    wire en_param, en_cal, en_repairclk, en_repairval, en_reversal, en_repairmb;
    wire en_valvref, en_datavref, en_speedidle, en_txselfcal, en_rxclkcal;
    wire en_valtraincenter, en_valtrainvref, en_datatraincenter1, en_datatrainvref;
    wire en_rxdeskew, en_datatraincenter2, en_linkspeed, en_repair_state;

    // =========================================================================
    // 2. DUT INSTANTIATION (with simulation-friendly timeouts)
    // =========================================================================
    lphy_ltssm #(
        .RESET_TIMER_CYCLES(10),
        .SBINIT_TIMEOUT(500),
        .MBINIT_TIMEOUT(500),
        .MBTRAIN_TIMEOUT(500),
        .LINKINIT_TIMEOUT(500),
        .PHYRETRAIN_TIMEOUT(500),
        .TRAINERROR_TIMEOUT(100)
    ) dut (.*);

    // =========================================================================
    // 3. CLOCK & WATCHDOG
    // =========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    // Safety watchdog
    initial begin
        #100_000_000;
        $display("FATAL: Simulation Timeout! State machine got stuck.");
        $finish;
    end

    int error_count = 0;

    // =========================================================================
    // HELPER TASKS
    // =========================================================================

    // Pulse a flag for 1 clock cycle at negedge
    task automatic pulse_done(ref logic flag);
        @(negedge clk); flag = 1'b1;
        @(negedge clk); flag = 1'b0;
    endtask

    // Wait for a signal with timeout guard (macro works with both wire and logic)
    `define WAIT_SIG(SIG, TIMEOUT) \
        begin \
            int __cnt = 0; \
            while (!(SIG) && __cnt < (TIMEOUT)) begin \
                @(negedge clk); \
                __cnt++; \
            end \
            if (!(SIG)) begin \
                $error("TIMEOUT waiting for %s after %0d cycles.", `"SIG`", (TIMEOUT)); \
                error_count++; \
            end \
        end

    // Run the full SBINIT handshake
    task automatic run_sbinit_handshake();
        `WAIT_SIG(tx_send_pattern, 500)
        @(negedge clk);
        rx_pattern_detected = 4'b0001;

        `WAIT_SIG(tx_msg_out_of_reset, 500)
        pulse_done(rx_msg_out_of_reset);

        `WAIT_SIG(tx_msg_done_req, 500)
        pulse_done(rx_msg_done_resp);
    endtask

    // Run the full MBINIT calibration sequence
    task automatic run_mbinit_sequence();
        `WAIT_SIG(en_param, 100) pulse_done(param_done);
        `WAIT_SIG(en_cal, 100) pulse_done(cal_done);
        `WAIT_SIG(en_repairclk, 100) pulse_done(repairclk_done);
        `WAIT_SIG(en_repairval, 100) pulse_done(repairval_done);
        `WAIT_SIG(en_reversal, 100) pulse_done(reversal_done);
        `WAIT_SIG(en_repairmb, 100) pulse_done(repairmb_done);
    endtask

    // Run the full MBTRAIN sequence (Advanced Package)
    task automatic run_mbtrain_sequence();
        `WAIT_SIG(en_valvref, 100) pulse_done(valvref_done);
        `WAIT_SIG(en_datavref, 100) pulse_done(datavref_done);
        `WAIT_SIG(en_speedidle, 100) pulse_done(speedidle_done);
        `WAIT_SIG(en_txselfcal, 100) pulse_done(txselfcal_done);
        `WAIT_SIG(en_rxclkcal, 100) pulse_done(rxclkcal_done);
        `WAIT_SIG(en_valtraincenter, 100) pulse_done(valtraincenter_done);
        `WAIT_SIG(en_valtrainvref, 100) pulse_done(valtrainvref_done);
        `WAIT_SIG(en_datatraincenter1, 100) pulse_done(datatraincenter1_done);
        `WAIT_SIG(en_datatrainvref, 100) pulse_done(datatrainvref_done);
        `WAIT_SIG(en_rxdeskew, 100) pulse_done(rxdeskew_done);
        `WAIT_SIG(en_datatraincenter2, 100) pulse_done(datatraincenter2_done);
        `WAIT_SIG(en_linkspeed, 100) pulse_done(linkspeed_done);
    endtask

    // Run the full LINKINIT handshake and enter ACTIVE
    task automatic run_linkinit_to_active();
        // Wait for LINKINIT to enter ST_WAIT_ADAPTER
        repeat(3) @(negedge clk);
        
        lp_state_req = 4'b0001; // Adapter requests ACTIVE

        `WAIT_SIG(tx_req_active, 100)
        pulse_done(rx_req_active); // Remote PHY requests active
        pulse_done(rx_rsp_active); // Remote PHY acknowledges
        
        // Wait for LTSSM to enter ACTIVE
        repeat(5) @(negedge clk);
        lp_state_req = 4'b0000; // Clear adapter request
    endtask

    // =========================================================================
    // 4. THE FULL LTSSM LIFECYCLE TEST
    // =========================================================================
    initial begin
        $display("==========================================================");
        $display("STARTING FULL LTSSM SYSTEM VERIFICATION");
        $display("==========================================================");

        // --- A. INITIALIZATION ---
        rst_n = 0;
        start_link_training = 0; lp_state_req = 4'h0; lp_linkerror = 0; lp_stallack = 0;
        power_stable = 0; sb_clk_stable = 0; mb_clk_stable = 0; mb_clk_slow = 0; soc_reset_n = 0;
        package_type = 0; // Advanced Package
        local_retrain_enc = 3'b001; // Default: TXSELFCAL
        
        // Zero out all RX sideband and internal done flags
        rx_pattern_detected = 0; rx_msg_out_of_reset = 0; rx_msg_done_req = 0; rx_msg_done_resp = 0;
        rx_req_active=0; rx_rsp_active=0; rx_req_l1=0; rx_rsp_l1=0; rx_req_l2=0; rx_rsp_l2=0;
        rx_req_linkreset=0; rx_rsp_linkreset=0; rx_req_disable=0; rx_rsp_disable=0;
        rx_req_retrain=0; rx_rsp_retrain=0; rx_req_linkerror=0; rx_trainerror_req=0; rx_trainerror_resp=0;
        rx_retrain_init_req=0; rx_retrain_init_resp=0; rx_retrain_start_req=0; rx_retrain_start_resp=0; rx_retrain_enc=0;
        
        param_done=0; cal_done=0; repairclk_done=0; repairval_done=0; reversal_done=0; repairmb_done=0;
        valvref_done=0; datavref_done=0; speedidle_done=0; txselfcal_done=0; rxclkcal_done=0;
        valtraincenter_done=0; valtrainvref_done=0; datatraincenter1_done=0; datatrainvref_done=0;
        rxdeskew_done=0; datatraincenter2_done=0; linkspeed_done=0; linkspeed_error=0; needs_repair=0;
        needs_speed_degrade=0; repair_done=0; cal_error=0; is_unrepairable=0;
        internal_retrain_req=0; internal_error_req=0;

        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =================================================================
        // PHASE 1: RESET → SBINIT (Boot Physical Clocks)
        // =================================================================
        $display("\n[PHASE 1] Booting Physical Clocks...");
        power_stable = 1; sb_clk_stable = 1; mb_clk_stable = 1; mb_clk_slow = 1; soc_reset_n = 1;
        @(negedge clk);
        start_link_training = 1;
        
        // =================================================================
        // PHASE 2: SBINIT Handshake
        // =================================================================
        $display("[PHASE 2] Negotiating SBINIT Handshake...");
        run_sbinit_handshake();

        // =================================================================
        // PHASE 3: MBINIT Calibration
        // =================================================================
        $display("[PHASE 3] Executing MBINIT Calibrations...");
        run_mbinit_sequence();

        // =================================================================
        // PHASE 4: MBTRAIN Link Training
        // =================================================================
        $display("[PHASE 4] Executing MBTRAIN Sequence...");
        run_mbtrain_sequence();

        // =================================================================
        // PHASE 5: LINKINIT → ACTIVE
        // =================================================================
        $display("[PHASE 5] LINKINIT Adapter Handshake...");
        run_linkinit_to_active();

        // =================================================================
        // PHASE 6: Verify ACTIVE State Datapath
        // =================================================================
        $display("[PHASE 6] Verifying ACTIVE State Datapath...");
        
        if (pl_state_sts !== 4'b0001) begin $error("PHASE 6 FAILED: pl_state_sts != ACTIVE (0001)."); error_count++; end
        if (!scrambler_en) begin $error("PHASE 6 FAILED: Scrambler not enabled in ACTIVE."); error_count++; end
        if (!descrambler_en) begin $error("PHASE 6 FAILED: Descrambler not enabled in ACTIVE."); error_count++; end
        if (!repair_en) begin $error("PHASE 6 FAILED: Repair map not locked in."); error_count++; end
        if (tx_training_en) begin $error("PHASE 6 FAILED: tx_training_en still on in ACTIVE!"); error_count++; end
        if (!pl_inband_pres) begin $error("PHASE 6 FAILED: pl_inband_pres not asserted."); error_count++; end
        
        if (error_count == 0) $display("   --> ACTIVE State Datapath Verified!");

        // =================================================================
        // PHASE 7: ACTIVE → L1 → L1 Wake-Up → re-train → ACTIVE
        // =================================================================
        $display("\n[PHASE 7] L1 Power Management Cycle...");
        
        // 7a. Enter L1
        @(negedge clk);
        lp_state_req = 4'b0100; // Adapter requests L1
        // ACTIVE fires tx_req_l1 combinationally for 1 cycle — don't poll, just wait
        @(negedge clk); // ACTIVE module sees request and fires tx_req_l1
        @(negedge clk); // State advances to ST_WAIT_RSP
        pulse_done(rx_rsp_l1); // Remote PHY agrees to sleep
        
        repeat(5) @(negedge clk);
        lp_state_req = 4'b0000;
        
        if (pl_state_sts !== 4'b0100) begin $error("PHASE 7a FAILED: pl_state_sts != L1 (0100)."); error_count++; end
        if (scrambler_en) begin $error("PHASE 7a FAILED: Scrambler still on in L1."); error_count++; end
        
        $display("   --> Entered L1 successfully.");

        // 7b. Wake up from L1 (Local Adapter initiates)
        @(negedge clk);
        lp_state_req = 4'b0001; // Adapter wants to wake up
        // PM module fires tx_req_active combinationally for 1 cycle
        @(negedge clk); // PM sees lp_state_req and fires tx_req_active
        @(negedge clk); // State advances to ST_WAKE_REQ
        pulse_done(rx_rsp_active); // Remote acknowledges wake
        
        // L1 wakes up to MBTRAIN (SPEEDIDLE substate)
        repeat(5) @(negedge clk);
        lp_state_req = 4'b0000;
        
        $display("   --> L1 Wake-Up: Re-entering MBTRAIN...");
        
        // Run MBTRAIN again (from SPEEDIDLE onward for re-training)
        run_mbtrain_sequence();
        
        // Run LINKINIT again
        $display("   --> Re-training: LINKINIT...");
        run_linkinit_to_active();
        
        if (pl_state_sts !== 4'b0001) begin $error("PHASE 7b FAILED: Did not return to ACTIVE after L1 wake."); error_count++; end
        else $display("   --> L1 Round-Trip Complete!");
        
        // =================================================================
        // PHASE 8: ACTIVE → PHYRETRAIN → MBTRAIN → ACTIVE
        // =================================================================
        $display("\n[PHASE 8] PHY Retrain Flow...");
        
        // Adapter requests retrain
        @(negedge clk);
        lp_state_req = 4'b1011; // Retrain
        // ACTIVE fires tx_req_retrain combinationally for 1 cycle
        @(negedge clk); // ACTIVE sees request
        @(negedge clk); // State advances to ST_WAIT_RSP
        pulse_done(rx_rsp_retrain); // Remote agrees
        
        repeat(3) @(negedge clk);
        lp_state_req = 4'b0000;
        
        // Now in PHYRETRAIN state. Give it a moment to enter.
        repeat(3) @(negedge clk);
        
        // Adapter acknowledges stall
        @(negedge clk);
        lp_stallack = 1'b1;
        local_retrain_enc = 3'b001; // TXSELFCAL
        internal_retrain_req = 1'b1; // Trigger retrain
        
        // Wait for Init.Req
        `WAIT_SIG(tx_retrain_init_req, 100)
        internal_retrain_req = 1'b0;
        
        // Remote responds
        pulse_done(rx_retrain_init_resp);
        
        // Wait for Start.Req
        `WAIT_SIG(tx_retrain_start_req, 100)
        
        // Remote sends Start.Resp
        @(negedge clk);
        rx_retrain_enc = 3'b001; // TXSELFCAL
        pulse_done(rx_retrain_start_resp);
        
        lp_stallack = 1'b0;
        
        // PHYRETRAIN exits to MBTRAIN
        repeat(5) @(negedge clk);
        
        $display("   --> PHYRETRAIN exited to MBTRAIN. Re-training...");
        
        // Run MBTRAIN again
        run_mbtrain_sequence();
        
        // Run LINKINIT again
        run_linkinit_to_active();
        
        if (pl_state_sts !== 4'b0001) begin $error("PHASE 8 FAILED: Did not return to ACTIVE after PHYRETRAIN."); error_count++; end
        else $display("   --> PHYRETRAIN Round-Trip Complete!");

        // =================================================================
        // PHASE 9: ACTIVE → TRAINERROR → RESET Recovery
        // =================================================================
        $display("\n[PHASE 9] TrainError Recovery Flow...");
        
        // Internal error triggers TRAINERROR
        @(negedge clk);
        internal_error_req = 1'b1;
        
        repeat(3) @(negedge clk);
        internal_error_req = 1'b0;
        
        // TRAINERROR sub-module fires tx_trainerror_req for 1 cycle
        repeat(5) @(negedge clk); // Give TRAINERROR time to send its request
        
        // Remote PHY responds
        pulse_done(rx_trainerror_resp);
        
        // Wait for exit to RESET
        `WAIT_SIG(phy_reset_active, 100)
        
        $display("   --> TRAINERROR recovered to RESET. Restarting link...");
        
        // Full re-training from RESET
        rx_pattern_detected = 4'b0000; // Clear stale pattern
        
        // Run full boot sequence again
        run_sbinit_handshake();
        run_mbinit_sequence();
        run_mbtrain_sequence();
        run_linkinit_to_active();
        
        if (pl_state_sts !== 4'b0001) begin $error("PHASE 9 FAILED: Did not return to ACTIVE after TRAINERROR recovery."); error_count++; end
        else $display("   --> TRAINERROR Full Recovery Complete!");

        // =================================================================
        // PHASE 10: ACTIVE → LINKRESET → RESET
        // =================================================================
        $display("\n[PHASE 10] LinkReset Flow...");
        
        @(negedge clk);
        lp_state_req = 4'b1001; // Adapter requests LinkReset
        // ACTIVE fires tx_req_linkreset combinationally for 1 cycle
        @(negedge clk); // ACTIVE sees request
        @(negedge clk); // State advances to ST_WAIT_RSP
        pulse_done(rx_rsp_linkreset); // Remote agrees
        
        repeat(5) @(negedge clk);
        
        if (pl_state_sts !== 4'b1001) begin $error("PHASE 10 FAILED: pl_state_sts != LINKRESET (1001)."); error_count++; end
        
        // Adapter requests transition out of LINKRESET
        @(negedge clk);
        lp_state_req = 4'b0001; // Go back to RESET → re-train
        
        // Wait for LTSSM to go back to RESET
        `WAIT_SIG(phy_reset_active, 100)
        lp_state_req = 4'b0000;
        
        $display("   --> LINKRESET → RESET successful. Restarting link...");
        
        // Full re-training
        rx_pattern_detected = 4'b0000;
        run_sbinit_handshake();
        run_mbinit_sequence();
        run_mbtrain_sequence();
        run_linkinit_to_active();
        
        if (pl_state_sts !== 4'b0001) begin $error("PHASE 10 FAILED: Did not return to ACTIVE after LINKRESET."); error_count++; end
        else $display("   --> LINKRESET Full Recovery Complete!");

        // =================================================================
        // PHASE 11: ACTIVE → DISABLED → RESET
        // =================================================================
        $display("\n[PHASE 11] Disabled Flow...");
        
        @(negedge clk);
        lp_state_req = 4'b1100; // Adapter requests Disable
        // ACTIVE fires tx_req_disable combinationally for 1 cycle
        @(negedge clk); // ACTIVE sees request
        @(negedge clk); // State advances to ST_WAIT_RSP
        pulse_done(rx_rsp_disable); // Remote agrees
        
        repeat(5) @(negedge clk);
        
        if (pl_state_sts !== 4'b1100) begin $error("PHASE 11 FAILED: pl_state_sts != DISABLED (1100)."); error_count++; end
        
        // Adapter requests re-enable
        @(negedge clk);
        lp_state_req = 4'b0001;
        
        `WAIT_SIG(phy_reset_active, 100)
        lp_state_req = 4'b0000;
        
        $display("   --> DISABLED → RESET successful.");

        // =================================================================
        // CONCLUSION
        // =================================================================
        $display("\n==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: UCIe LTSSM Top Module completed FULL lifecycle!");
            $display("Verified: RESET -> SBINIT -> MBINIT -> MBTRAIN -> LINKINIT -> ACTIVE");
            $display("          -> L1 Wake -> PHYRETRAIN -> TRAINERROR -> LINKRESET -> DISABLED");
        end else begin
            $display("FAILED: %0d errors detected in Golden Flow.", error_count);
        end
        $display("==========================================================");
        $finish;
    end
endmodule