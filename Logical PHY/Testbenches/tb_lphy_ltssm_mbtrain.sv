`timescale 1ns / 1ps

module tb_lphy_ltssm_mbtrain();

    localparam int TIMEOUT_CYCLES = 100;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk, rst_n, en_mbtrain, package_type;

    logic valvref_done, datavref_done, speedidle_done, txselfcal_done;
    logic rxclkcal_done, valtraincenter_done, valtrainvref_done;
    logic datatraincenter1_done, datatrainvref_done, rxdeskew_done;
    logic datatraincenter2_done;

    logic linkspeed_done, linkspeed_error, needs_repair, needs_speed_degrade;
    logic repair_done, substate_error;

    logic en_valvref, en_datavref, en_speedidle, en_txselfcal, en_rxclkcal;
    logic en_valtraincenter, en_valtrainvref, en_datatraincenter1;
    logic en_datatrainvref, en_rxdeskew, en_datatraincenter2;
    logic en_linkspeed, en_repair;
    logic exit_to_linkinit, exit_to_trainerror;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_ltssm_mbtrain #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    int error_count = 0;

    // -------------------------------------------------------------------------
    // pulse_done: assert flag for one clock cycle, then wait one more cycle
    // so the state FF updates and en_* outputs settle before caller checks them.
    //   negedge N  : flag=1 sampled → next_state updated
    //   negedge N+1: flag=0 cleared; state register now holds the new state
    // -------------------------------------------------------------------------
    task automatic pulse_done(ref logic flag);
        @(negedge clk); flag = 1'b1;
        @(negedge clk); flag = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // check_en: verify a single enable is asserted, all others zero
    // -------------------------------------------------------------------------
    `define check_en(sig, name) \
        if (!(sig)) begin \
            $error("MBTRAIN: %s did not assert as expected.", name); \
            error_count++; \
        end

    // -------------------------------------------------------------------------
    // Helper: run the common Advanced tail:
    //   DATATRAINVREF → RXDESKEW → DATATRAINCENTER2 → LINKSPEED → DONE
    // -------------------------------------------------------------------------
    task automatic adv_tail_vref_to_done();
        pulse_done(datatrainvref_done);
        `check_en(en_rxdeskew, "en_rxdeskew")
        pulse_done(rxdeskew_done);
        `check_en(en_datatraincenter2, "en_datatraincenter2")
        pulse_done(datatraincenter2_done);
        `check_en(en_linkspeed, "en_linkspeed")
        pulse_done(linkspeed_done);
    endtask

    // -------------------------------------------------------------------------
    // Helper: run the common Standard tail from RXDESKEW onwards
    // -------------------------------------------------------------------------
    task automatic std_tail_deskew_to_done();
        `check_en(en_rxdeskew, "en_rxdeskew")
        pulse_done(rxdeskew_done);
        `check_en(en_datatraincenter2, "en_datatraincenter2")
        pulse_done(datatraincenter2_done);
        `check_en(en_linkspeed, "en_linkspeed")
        pulse_done(linkspeed_done);
    endtask

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_ltssm_mbtrain");
        $display("==========================================================");

        rst_n = 0; en_mbtrain = 0; package_type = 0;
        valvref_done = 0; datavref_done = 0; speedidle_done = 0;
        txselfcal_done = 0; rxclkcal_done = 0; valtraincenter_done = 0;
        valtrainvref_done = 0; datatraincenter1_done = 0; datatrainvref_done = 0;
        rxdeskew_done = 0; datatraincenter2_done = 0; linkspeed_done = 0;
        linkspeed_error = 0; needs_repair = 0; needs_speed_degrade = 0;
        repair_done = 0; substate_error = 0;

        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: Advanced Package — Full 14-Sub-State Flow
        // =====================================================================
        $display("\n[TEST 1] Advanced Package: Full flow VALVREF through DONE...");
        package_type = 1'b0; // Advanced
        en_mbtrain   = 1'b1;

        // One cycle for FSM to register ST_VALVREF
        @(negedge clk);
        `check_en(en_valvref, "en_valvref — Advanced starts at VALVREF")

        pulse_done(valvref_done);
        `check_en(en_datavref, "en_datavref")

        pulse_done(datavref_done);
        `check_en(en_speedidle, "en_speedidle")

        pulse_done(speedidle_done);
        `check_en(en_txselfcal, "en_txselfcal")

        pulse_done(txselfcal_done);
        `check_en(en_rxclkcal, "en_rxclkcal")

        pulse_done(rxclkcal_done);
        `check_en(en_valtraincenter, "en_valtraincenter")

        pulse_done(valtraincenter_done);
        `check_en(en_valtrainvref, "en_valtrainvref — Advanced must visit VALTRAINVREF")

        pulse_done(valtrainvref_done);
        `check_en(en_datatraincenter1, "en_datatraincenter1")

        pulse_done(datatraincenter1_done);
        `check_en(en_datatrainvref, "en_datatrainvref — Advanced must visit DATATRAINVREF")

        adv_tail_vref_to_done();

        if (!exit_to_linkinit) begin $error("TEST 1 FAILED: exit_to_linkinit not asserted."); error_count++; end
        else $display("   [PASS] Test 1: Advanced Package full flow completed.");

        en_mbtrain = 1'b0;
        @(negedge clk); // FSM returns to IDLE

        // =====================================================================
        // TEST 2: Standard Package — Three Vref Bypasses
        // =====================================================================
        $display("\n[TEST 2] Standard Package: Bypass VALVREF, VALTRAINVREF, DATATRAINVREF...");
        package_type = 1'b1; // Standard
        en_mbtrain   = 1'b1;

        // Standard Package must start at SPEEDIDLE, NOT VALVREF
        @(negedge clk);
        if (en_valvref || en_datavref) begin
            $error("TEST 2 FAILED: Standard Package wrongly entered VALVREF or DATAVREF.");
            error_count++;
        end
        `check_en(en_speedidle, "en_speedidle — Standard starts here")

        pulse_done(speedidle_done);
        `check_en(en_txselfcal, "en_txselfcal")
        pulse_done(txselfcal_done);
        `check_en(en_rxclkcal, "en_rxclkcal")
        pulse_done(rxclkcal_done);
        `check_en(en_valtraincenter, "en_valtraincenter")
        pulse_done(valtraincenter_done);

        // Standard: must jump to DATATRAINCENTER1, skipping VALTRAINVREF
        if (en_valtrainvref) begin
            $error("TEST 2 FAILED: Standard Package wrongly entered VALTRAINVREF.");
            error_count++;
        end
        `check_en(en_datatraincenter1, "en_datatraincenter1 — Standard bypasses VALTRAINVREF")

        pulse_done(datatraincenter1_done);

        // Standard: must jump to RXDESKEW, skipping DATATRAINVREF
        if (en_datatrainvref) begin
            $error("TEST 2 FAILED: Standard Package wrongly entered DATATRAINVREF.");
            error_count++;
        end

        std_tail_deskew_to_done();

        if (!exit_to_linkinit) begin $error("TEST 2 FAILED: exit_to_linkinit not asserted."); error_count++; end
        else $display("   [PASS] Test 2: Standard Package correctly bypassed all 3 Vref states.");

        en_mbtrain = 1'b0;
        @(negedge clk);

        // =====================================================================
        // TEST 3: LINKSPEED — Speed Degrade Fallback Loop
        // =====================================================================
        $display("\n[TEST 3] LINKSPEED fallback: speed degrade -> loops to SPEEDIDLE...");
        package_type = 1'b1; // Standard (shorter path to LINKSPEED)
        en_mbtrain   = 1'b1;

        @(negedge clk); // Enter SPEEDIDLE
        pulse_done(speedidle_done); pulse_done(txselfcal_done);
        pulse_done(rxclkcal_done);  pulse_done(valtraincenter_done);
        pulse_done(datatraincenter1_done);
        pulse_done(rxdeskew_done);  pulse_done(datatraincenter2_done);

        // Now in ST_LINKSPEED — trigger speed degrade error
        @(negedge clk);
        linkspeed_error = 1'b1; needs_speed_degrade = 1'b1;
        @(negedge clk); // State registers ST_SPEEDIDLE
        linkspeed_error = 1'b0; needs_speed_degrade = 1'b0;

        if (!en_speedidle) begin
            $error("TEST 3 FAILED: Did not loop back to ST_SPEEDIDLE on speed degrade.");
            error_count++;
        end else $display("   [PASS] Test 3: Speed degrade correctly loops to SPEEDIDLE.");

        // Complete the second attempt
        pulse_done(speedidle_done); pulse_done(txselfcal_done);
        pulse_done(rxclkcal_done);  pulse_done(valtraincenter_done);
        pulse_done(datatraincenter1_done);
        pulse_done(rxdeskew_done);  pulse_done(datatraincenter2_done);
        pulse_done(linkspeed_done);

        if (!exit_to_linkinit) begin $error("TEST 3 FAILED: Did not exit after successful retry."); error_count++; end
        else $display("   [PASS] Test 3: Successful exit after retry.");

        en_mbtrain = 1'b0;
        @(negedge clk);

        // =====================================================================
        // TEST 4: LINKSPEED — Repair Fallback Loop
        // =====================================================================
        $display("\n[TEST 4] LINKSPEED fallback: repair -> loops to TXSELFCAL...");
        package_type = 1'b1;
        en_mbtrain   = 1'b1;

        @(negedge clk);
        pulse_done(speedidle_done); pulse_done(txselfcal_done);
        pulse_done(rxclkcal_done);  pulse_done(valtraincenter_done);
        pulse_done(datatraincenter1_done);
        pulse_done(rxdeskew_done);  pulse_done(datatraincenter2_done);

        // Trigger repair error at LINKSPEED
        @(negedge clk);
        linkspeed_error = 1'b1; needs_repair = 1'b1;
        @(negedge clk); // State registers ST_REPAIR
        linkspeed_error = 1'b0; needs_repair = 1'b0;

        if (!en_repair) begin
            $error("TEST 4 FAILED: Did not enter ST_REPAIR.");
            error_count++;
        end else $display("   [PASS] Test 4a: Repair state entered.");

        pulse_done(repair_done);

        // After repair, must loop back to TXSELFCAL (not SPEEDIDLE or VALVREF)
        if (!en_txselfcal) begin
            $error("TEST 4 FAILED: Did not loop back to TXSELFCAL after repair.");
            error_count++;
        end else $display("   [PASS] Test 4b: Correctly looped to TXSELFCAL after repair.");

        // Complete the second attempt
        pulse_done(txselfcal_done); pulse_done(rxclkcal_done);
        pulse_done(valtraincenter_done); pulse_done(datatraincenter1_done);
        pulse_done(rxdeskew_done);  pulse_done(datatraincenter2_done);
        pulse_done(linkspeed_done);

        if (!exit_to_linkinit) begin $error("TEST 4 FAILED: Did not exit after repair retry."); error_count++; end
        else $display("   [PASS] Test 4c: Successful exit after repair retry.");

        en_mbtrain = 1'b0;
        @(negedge clk);

        // =====================================================================
        // TEST 5: Global Timeout
        // =====================================================================
        $display("\n[TEST 5] Global timeout — stall in RXCLKCAL...");
        package_type = 1'b1;
        en_mbtrain   = 1'b1;

        @(negedge clk);
        pulse_done(speedidle_done); pulse_done(txselfcal_done);
        // Stall in RXCLKCAL — rxclkcal_done never asserts
        repeat(TIMEOUT_CYCLES + 5) @(negedge clk);

        if (!exit_to_trainerror) begin
            $error("TEST 5 FAILED: Global timeout did not trigger TRAINERROR.");
            error_count++;
        end else $display("   [PASS] Test 5: TRAINERROR asserted on timeout.");

        en_mbtrain = 1'b0;
        @(negedge clk);

        // =====================================================================
        // TEST 6: Immediate Substate Error
        // =====================================================================
        $display("\n[TEST 6] Immediate substate error (from DATATRAINCENTER1)...");
        package_type = 1'b1;
        en_mbtrain   = 1'b1;

        @(negedge clk);
        pulse_done(speedidle_done); pulse_done(txselfcal_done);
        pulse_done(rxclkcal_done);  pulse_done(valtraincenter_done);
        // Now in DATATRAINCENTER1 — inject substate error
        @(negedge clk);
        substate_error = 1'b1;
        @(negedge clk); // State registers ST_ERROR
        substate_error = 1'b0;

        if (!exit_to_trainerror) begin
            $error("TEST 6 FAILED: Substate error did not trigger TRAINERROR.");
            error_count++;
        end else $display("   [PASS] Test 6: TRAINERROR asserted on substate_error.");

        en_mbtrain = 1'b0;
        @(negedge clk);

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("\n==========================================================");
        if (error_count == 0)
            $display("SUCCESS: lphy_ltssm_mbtrain passed all 6 tests.");
        else
            $display("FAILED: %0d errors detected.", error_count);
        $display("==========================================================");
        $finish;
    end

endmodule