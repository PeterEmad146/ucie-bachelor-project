`timescale 1ns / 1ps

module tb_lphy_ltssm_reset();

    // Reduce the 4ms timer to 10 cycles for fast simulation
    localparam int TEST_CYCLES_4MS = 10;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    // Status
    logic power_stable;
    logic sb_clk_stable;
    logic mb_clk_stable;
    logic mb_clk_slow;

    // Control
    logic soc_reset_n;
    logic start_link_training;
    logic en_reset;             // NEW: drives from master LTSSM; 1 = ST_RESET is active

    // Outputs
    logic exit_to_sbinit;
    logic phy_reset_active;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_ltssm_reset #(
        .CLK_CYCLES_4MS(TEST_CYCLES_4MS)
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
    // Helper: wait N negedge clk edges cleanly
    // -------------------------------------------------------------------------
    task wait_cycles(int n);
        repeat(n) @(negedge clk);
    endtask

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_ltssm_reset");
        $display("==========================================================");

        // Cold Boot Reset
        rst_n = 0;
        power_stable = 0; sb_clk_stable = 0; mb_clk_stable = 0; mb_clk_slow = 0;
        soc_reset_n = 0; start_link_training = 0;
        en_reset = 1;   // Master LTSSM is in ST_RESET from the start

        @(negedge clk);
        rst_n = 1;

        // =====================================================================
        // TEST 1: Initial Quiescent State Check
        // =====================================================================
        // After rst_n de-asserts: PHY must be clamped, no exit triggered.
        // en_reset=1 with en_reset_q=0 means reset_reentry pulses once, clearing
        // the timer (which was already 0). No functional impact on cold boot. 
        if (phy_reset_active !== 1'b1 || exit_to_sbinit !== 1'b0) begin
            $error("TEST 1 FAILED: PHY is not clamped during cold boot!");
            error_count++;
        end else
            $display("   [PASS] Test 1: PHY correctly clamped after reset.");

        // =====================================================================
        // TEST 2: Power Glitch — Timer Must Reset
        // =====================================================================
        $display("TEST 2: Power Glitch Test...");
        soc_reset_n = 1'b1;
        power_stable = 1'b1; sb_clk_stable = 1'b1; mb_clk_stable = 1'b1;

        // Wait 5 cycles (halfway through the 10-cycle timer)
        wait_cycles(5);

        // Simulate a power droop — this must reset the timer
        power_stable = 1'b0;
        @(negedge clk);
        power_stable = 1'b1; // Power recovers → timer starts from 0 again

        // Wait 8 more cycles. Total elapsed = 5 + 1 + 8 = 14 cycles.
        // Without the glitch reset: timer would have reached 10 by now → FAIL.
        // With the glitch reset: timer restarted at 0 after glitch → NOT DONE yet.
        wait_cycles(8);
        mb_clk_slow = 1'b1;
        start_link_training = 1'b1;

        if (exit_to_sbinit === 1'b1) begin
            $error("TEST 2 FAILED: Timer did not reset upon power glitch!");
            error_count++;
        end else
            $display("   [PASS] Test 2: Timer correctly restarted after power glitch.");

        // =====================================================================
        // TEST 3: Clean Transition to SBINIT
        // =====================================================================
        $display("TEST 3: Clean Transition to SBINIT...");
        // The timer restarted after the glitch. It needs TEST_CYCLES_4MS (10) cycles
        // of stable clocks. We've already seen 8 stable cycles post-glitch; wait 4 more.
        wait_cycles(4);

        if (exit_to_sbinit !== 1'b1 || phy_reset_active !== 1'b0) begin
            $error("TEST 3 FAILED: Failed to transition to SBINIT after stable hold time.");
            error_count++;
        end else
            $display("   [PASS] Test 3: exit_to_sbinit asserted, PHY clamps released.");

        // =====================================================================
        // TEST 4: SoC Hard Reset Override
        // =====================================================================
        $display("TEST 4: SoC Hard Reset Override...");
        // While fully active (exit_to_sbinit=1), the SoC pulls reset pin low.
        // PHY must re-clamp immediately within one cycle.
        soc_reset_n = 1'b0;
        @(negedge clk);

        if (phy_reset_active !== 1'b1 || exit_to_sbinit !== 1'b0) begin
            $error("TEST 4 FAILED: SoC Reset did not instantly clamp the PHY!");
            error_count++;
        end else
            $display("   [PASS] Test 4: SoC hard reset immediately clamped PHY.");

        // =====================================================================
        // TEST 5: Re-entry Timer Clear (L2 Wakeup Scenario)
        // =====================================================================
        // This test validates the NEW en_reset rising-edge detection logic.
        // Scenario: PHY was in ACTIVE, drops to RESET (e.g. from L2 wakeup).
        // The timer was already done from a previous RESET traversal. Without
        // the fix, exit_to_sbinit would fire immediately. With the fix, en_reset
        // rising edge clears the timer, forcing a full re-count.
        $display("TEST 5: L2 Wakeup Re-entry Timer Enforcement...");

        // Release SoC reset and re-establish stable clocks
        soc_reset_n      = 1'b1;
        power_stable     = 1'b1;
        sb_clk_stable    = 1'b1;
        mb_clk_stable    = 1'b1;
        mb_clk_slow      = 1'b1;
        start_link_training = 1'b1;

        // Simulate the LTSSM leaving ST_RESET (en_reset goes low — entering SBINIT)
        en_reset = 1'b0;
        wait_cycles(2); // Simulate time in SBINIT/other states

        // Now simulate LTSSM returning to ST_RESET (rising edge of en_reset)
        // At this point timer_done=1 from before — old code would fire immediately.
        en_reset = 1'b1;
        @(negedge clk); // Rising edge detected — timer should be cleared NOW

        // Check: exit_to_sbinit must NOT fire this cycle (timer just cleared)
        if (exit_to_sbinit === 1'b1) begin
            $error("TEST 5 FAILED: exit_to_sbinit fired immediately on re-entry — timer was not cleared!");
            error_count++;
        end else
            $display("   [PASS] Test 5a: Timer correctly cleared on LTSSM re-entry to RESET.");

        // Wait the full timer count and verify it exits correctly this time
        wait_cycles(TEST_CYCLES_4MS + 2); // +2 for pipeline latency

        if (exit_to_sbinit !== 1'b1) begin
            $error("TEST 5 FAILED: exit_to_sbinit did not assert after re-counting the timer.");
            error_count++;
        end else
            $display("   [PASS] Test 5b: exit_to_sbinit correctly asserted after full re-count.");

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_ltssm_reset passed all 5 tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule