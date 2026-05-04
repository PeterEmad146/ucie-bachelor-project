`timescale 1ns / 1ps

module tb_lphy_ltssm_mbinit();

    localparam int TIMEOUT_CYCLES = 100;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    logic en_mbinit;
    logic package_type;

    logic param_done, cal_done, repairclk_done;
    logic repairval_done, reversal_done, repairmb_done;
    logic substate_error;

    logic en_param, en_cal, en_repairclk;
    logic en_repairval, en_reversal, en_repairmb;
    logic exit_to_mbtrain, exit_to_trainerror;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_ltssm_mbinit #(
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    int error_count = 0;

    // -------------------------------------------------------------------------
    // Helper task: assert a done flag for exactly one clock cycle.
    // Waits one extra negedge AFTER de-asserting so the receiving state has
    // time to register the transition before the caller checks outputs.
    // -------------------------------------------------------------------------
    task automatic pulse_done(ref logic flag);
        @(negedge clk); flag = 1'b1;   // Present the done flag
        @(negedge clk); flag = 1'b0;   // State register updates HERE
    endtask

    // -------------------------------------------------------------------------
    // Helper MACRO: wait for an enable to go high (state was entered)
    // Converted from a task to a macro to avoid Vivado's multiple-driver 
    // error when passing continuously driven DUT outputs by reference.
    // -------------------------------------------------------------------------
    `define wait_for_enable(en, name) \
        begin \
            @(negedge clk); \
            if (!(en)) begin \
                $error("MBINIT: %s did not assert as expected.", name); \
                error_count++; \
            end \
        end

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_ltssm_mbinit");
        $display("==========================================================");

        // Reset
        rst_n = 0;
        en_mbinit = 0; package_type = 0;
        param_done = 0; cal_done = 0; repairclk_done = 0;
        repairval_done = 0; reversal_done = 0; repairmb_done = 0;
        substate_error = 0;

        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: Advanced Package - Full 7-Sub-State Flow
        // =====================================================================
        $display("\n[TEST 1] Advanced Package: Full PARAM?CAL?REPAIRCLK?REPAIRVAL?REVERSALMB?REPAIRMB?DONE...");
        package_type = 1'b0; // Advanced
        en_mbinit    = 1'b1;

        // FSM takes 1 cycle to register ST_PARAM
        `wait_for_enable(en_param, "en_param (ST_PARAM)");
        pulse_done(param_done);

        if (!en_cal) begin $error("TEST 1 FAILED: ST_CAL not entered after PARAM."); error_count++; end
        else $display("   [PASS] 1a: ST_PARAM ? ST_CAL correctly.");
        pulse_done(cal_done);

        if (!en_repairclk) begin $error("TEST 1 FAILED: Advanced Package skipped ST_REPAIRCLK."); error_count++; end
        else $display("   [PASS] 1b: ST_CAL ? ST_REPAIRCLK correctly (Advanced Package).");
        pulse_done(repairclk_done);

        if (!en_repairval) begin $error("TEST 1 FAILED: ST_REPAIRVAL not entered after REPAIRCLK."); error_count++; end
        else $display("   [PASS] 1c: ST_REPAIRCLK ? ST_REPAIRVAL correctly.");
        pulse_done(repairval_done);

        if (!en_reversal) begin $error("TEST 1 FAILED: ST_REVERSALMB not entered after REPAIRVAL."); error_count++; end
        else $display("   [PASS] 1d: ST_REPAIRVAL ? ST_REVERSALMB correctly.");
        pulse_done(reversal_done);

        if (!en_repairmb) begin $error("TEST 1 FAILED: ST_REPAIRMB not entered after REVERSALMB."); error_count++; end
        else $display("   [PASS] 1e: ST_REVERSALMB ? ST_REPAIRMB correctly.");
        pulse_done(repairmb_done);

        // After repairmb_done pulse, state = ST_DONE
        if (!exit_to_mbtrain) begin $error("TEST 1 FAILED: exit_to_mbtrain not asserted in ST_DONE."); error_count++; end
        else $display("   [PASS] 1f: exit_to_mbtrain asserted in ST_DONE.");

        en_mbinit = 1'b0;
        @(negedge clk); // State returns to IDLE
        if (exit_to_mbtrain !== 1'b0) begin $error("TEST 1 FAILED: exit_to_mbtrain did not clear after en_mbinit dropped."); error_count++; end
        else $display("   [PASS] 1g: FSM returned cleanly to IDLE.");

        // =====================================================================
        // TEST 2: Standard Package - REPAIRCLK and REPAIRVAL must be bypassed
        // =====================================================================
        $display("\n[TEST 2] Standard Package: REPAIRCLK + REPAIRVAL bypassed...");
        package_type = 1'b1; // Standard
        en_mbinit    = 1'b1;

        // FSM takes 1 cycle to enter ST_PARAM
        `wait_for_enable(en_param, "en_param (ST_PARAM)");
        pulse_done(param_done);

        if (!en_cal) begin $error("TEST 2 FAILED: ST_CAL not entered."); error_count++; end
        pulse_done(cal_done);

        // For Standard Package, next state must be ST_REVERSALMB - NOT REPAIRCLK
        if (en_repairclk || en_repairval) begin
            $error("TEST 2 FAILED: Standard Package wrongly entered REPAIRCLK/REPAIRVAL states.");
            error_count++;
        end
        if (!en_reversal) begin
            $error("TEST 2 FAILED: Standard Package did not bypass to ST_REVERSALMB.");
            error_count++;
        end else $display("   [PASS] Test 2: ST_CAL ? ST_REVERSALMB correctly (Standard Package bypass).");
        pulse_done(reversal_done);

        if (!en_repairmb) begin $error("TEST 2 FAILED: ST_REPAIRMB not entered."); error_count++; end
        pulse_done(repairmb_done);
        if (!exit_to_mbtrain) begin $error("TEST 2 FAILED: exit_to_mbtrain not asserted."); error_count++; end
        else $display("   [PASS] Test 2: Full Standard Package flow completed.");

        en_mbinit = 1'b0;
        @(negedge clk);
        package_type = 1'b0;

        // =====================================================================
        // TEST 3: Global Timeout - Stall in ST_CAL, wait for TRAINERROR
        // =====================================================================
        $display("\n[TEST 3] Global 8ms Timeout - stall in ST_CAL...");
        en_mbinit = 1'b1;

        `wait_for_enable(en_param, "en_param");
        pulse_done(param_done); // Advance to ST_CAL
        
        // Now stall in ST_CAL - cal_done never asserts
        // Timeout accumulates from first non-IDLE cycle; at this point it has
        // already counted ~3 cycles in ST_PARAM. Add TIMEOUT_CYCLES more.
        repeat(TIMEOUT_CYCLES + 5) @(negedge clk);

        if (!exit_to_trainerror) begin
            $error("TEST 3 FAILED: Global timeout did not trigger TRAINERROR.");
            error_count++;
        end else $display("   [PASS] Test 3: TRAINERROR correctly asserted after timeout.");

        en_mbinit = 1'b0;
        @(negedge clk);

        // =====================================================================
        // TEST 4: Immediate Substate Error - fires from any non-terminal state
        // =====================================================================
        $display("\n[TEST 4] Immediate Substate Error (from ST_CAL)...");
        en_mbinit = 1'b1;

        `wait_for_enable(en_param, "en_param");
        pulse_done(param_done); // Advance to ST_CAL

        // Assert substate_error for one cycle - must cause immediate ST_ERROR
        @(negedge clk);
        substate_error = 1'b1;
        @(negedge clk);  // State registers ST_ERROR
        substate_error = 1'b0;

        if (!exit_to_trainerror) begin
            $error("TEST 4 FAILED: Substate error did not force exit to TRAINERROR.");
            error_count++;
        end else $display("   [PASS] Test 4: exit_to_trainerror asserted on substate_error.");

        en_mbinit = 1'b0;
        @(negedge clk);

        // =====================================================================
        // TEST 5: Mutual Exclusion - only one en_* asserted at a time
        // =====================================================================
        $display("\n[TEST 5] Mutual exclusion - only one enable asserted per sub-state...");
        en_mbinit = 1'b1;
        begin
            logic [5:0] all_en;
            int exclusive_errors = 0;

            // Walk through each sub-state and check that exactly one enable fires
            `wait_for_enable(en_param, "en_param");
            all_en = {en_repairmb, en_reversal, en_repairval, en_repairclk, en_cal, en_param};
            if ($countones(all_en) != 1) begin $error("TEST 5 FAILED: Multiple enables in ST_PARAM: %06b", all_en); error_count++; exclusive_errors++; end

            pulse_done(param_done);
            all_en = {en_repairmb, en_reversal, en_repairval, en_repairclk, en_cal, en_param};
            if ($countones(all_en) != 1) begin $error("TEST 5 FAILED: Multiple enables in ST_CAL: %06b", all_en); error_count++; exclusive_errors++; end

            pulse_done(cal_done); // Advanced Package ? REPAIRCLK
            all_en = {en_repairmb, en_reversal, en_repairval, en_repairclk, en_cal, en_param};
            if ($countones(all_en) != 1) begin $error("TEST 5 FAILED: Multiple enables in ST_REPAIRCLK: %06b", all_en); error_count++; exclusive_errors++; end

            pulse_done(repairclk_done);
            all_en = {en_repairmb, en_reversal, en_repairval, en_repairclk, en_cal, en_param};
            if ($countones(all_en) != 1) begin $error("TEST 5 FAILED: Multiple enables in ST_REPAIRVAL: %06b", all_en); error_count++; exclusive_errors++; end

            pulse_done(repairval_done);
            all_en = {en_repairmb, en_reversal, en_repairval, en_repairclk, en_cal, en_param};
            if ($countones(all_en) != 1) begin $error("TEST 5 FAILED: Multiple enables in ST_REVERSALMB: %06b", all_en); error_count++; exclusive_errors++; end

            pulse_done(reversal_done);
            all_en = {en_repairmb, en_reversal, en_repairval, en_repairclk, en_cal, en_param};
            if ($countones(all_en) != 1) begin $error("TEST 5 FAILED: Multiple enables in ST_REPAIRMB: %06b", all_en); error_count++; exclusive_errors++; end

            pulse_done(repairmb_done);

            if (exclusive_errors == 0) $display("   [PASS] Test 5: All sub-states are mutually exclusive.");
        end

        en_mbinit = 1'b0;
        @(negedge clk);

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("\n==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_ltssm_mbinit passed all 5 tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule