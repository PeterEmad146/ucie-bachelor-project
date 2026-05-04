`timescale 1ns / 1ps

module tb_lphy_ltssm_sbinit();

    // Small timeout for fast simulation
    localparam int TIMEOUT_CYCLES = 100;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    logic en_sbinit;
    logic package_type;

    logic [3:0] rx_pattern_detected;
    logic rx_msg_out_of_reset;
    logic rx_msg_done_req;
    logic rx_msg_done_resp;

    logic tx_send_pattern;
    logic tx_msg_out_of_reset;
    logic tx_msg_done_req;
    logic tx_msg_done_resp;
    logic [2:0] sb_repair_sel;

    logic exit_to_mbinit;
    logic exit_to_trainerror;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_ltssm_sbinit #(
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
    // Helper task: wait N negedge clk edges
    // -------------------------------------------------------------------------
    task wait_cycles(int n);
        repeat(n) @(negedge clk);
    endtask

    // =========================================================================
    // EXPECTED TIMING:
    //   - ST_SEND_PATTERN is entered on the cycle AFTER en_sbinit asserts (1 FF)
    //   - ST_WAIT_4_ITER lasts exactly 48 cycles (wait_cnt 0..47, transition on 47)
    //   - ST_OUT_OF_RESET entered on next cycle after transition
    //   - Registered state means outputs are visible 1 cycle after the transition
    // =========================================================================

    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_ltssm_sbinit");
        $display("==========================================================");

        // Reset
        rst_n = 0;
        en_sbinit = 0; package_type = 0; // Advanced Package
        rx_pattern_detected = 4'b0000;
        rx_msg_out_of_reset = 0; rx_msg_done_req = 0; rx_msg_done_resp = 0;

        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: Full Happy-Path Handshake (Normal Done_Resp flow)
        // Scenario: Remote PHY sends Done_Resp (not a crossover/deadlock)
        // =====================================================================
        $display("\n[TEST 1] Full handshake: Advanced Package, normal Done_Resp...");
        en_sbinit = 1'b1;

        // 1a — Wait one cycle for FSM to enter ST_SEND_PATTERN
        @(negedge clk);
        if (!tx_send_pattern) begin
            $error("TEST 1 FAILED: Did not assert tx_send_pattern in ST_SEND_PATTERN.");
            error_count++;
        end else $display("   [PASS] 1a: tx_send_pattern asserted.");

        // 1b — Remote PHY detected: pattern on DATASBRD/CKSB (bit 2 = index 2)
        // sb_repair_sel should resolve to 3'b010
        rx_pattern_detected = 4'b0100;

        // 1c — Wait 48 cycles (ST_WAIT_4_ITER: wait_cnt 0..47)
        //      + 1 cycle for the state register to update to ST_OUT_OF_RESET
        wait_cycles(49);

        if (!tx_msg_out_of_reset) begin
            $error("TEST 1 FAILED: Did not assert tx_msg_out_of_reset after 48-cycle hold.");
            error_count++;
        end else $display("   [PASS] 1c: tx_msg_out_of_reset asserted after correct 48-cycle wait.");

        if (sb_repair_sel !== 3'b010) begin
            $error("TEST 1 FAILED: sb_repair_sel=%0b, expected 3'b010 for DATASBRD/CKSB pattern.", sb_repair_sel);
            error_count++;
        end else $display("   [PASS] 1d: sb_repair_sel=010 correct.");

        // 1e — Remote PHY sends Out-of-Reset message
        rx_msg_out_of_reset = 1'b1;
        @(negedge clk);
        rx_msg_out_of_reset = 1'b0;
        @(negedge clk); // 1 cycle for state to register ST_DONE_REQ

        if (!tx_msg_done_req) begin
            $error("TEST 1 FAILED: Did not send Done_Req after receiving Out-of-Reset.");
            error_count++;
        end else $display("   [PASS] 1e: tx_msg_done_req asserted in ST_DONE_REQ.");

        // 1f — Remote PHY sends Done_Resp (normal non-crossover path)
        rx_msg_done_resp = 1'b1;
        @(negedge clk);
        rx_msg_done_resp = 1'b0;
        @(negedge clk); // 1 cycle for state to register ST_DONE

        if (!tx_msg_done_resp) begin
            $error("TEST 1 FAILED: Did not send tx_msg_done_resp in ST_DONE.");
            error_count++;
        end
        if (!exit_to_mbinit) begin
            $error("TEST 1 FAILED: exit_to_mbinit not asserted in ST_DONE.");
            error_count++;
        end
        if (error_count == 0) $display("   [PASS] 1f: tx_msg_done_resp asserted, exit_to_mbinit raised.");

        // 1g — Master LTSSM releases en_sbinit; FSM should return to IDLE
        en_sbinit = 1'b0;
        @(negedge clk);
        if (exit_to_mbinit !== 1'b0) begin
            $error("TEST 1 FAILED: exit_to_mbinit did not drop after en_sbinit released.");
            error_count++;
        end else $display("   [PASS] 1g: FSM cleanly returned to IDLE.");

        // =====================================================================
        // TEST 2: Crossover / Deadlock Resolution (Both sides send Done_Req)
        // =====================================================================
        $display("\n[TEST 2] Deadlock resolution: simultaneous Done_Req...");
        en_sbinit = 1'b1;
        rx_pattern_detected = 4'b0001; // DATASB/CKSB — repair_sel should be 3'b000

        @(negedge clk); // Enter ST_SEND_PATTERN
        wait_cycles(49); // 48-cycle wait + 1 transition cycle → ST_OUT_OF_RESET

        // Send Out-of-Reset
        rx_msg_out_of_reset = 1'b1;
        @(negedge clk);
        rx_msg_out_of_reset = 1'b0;
        @(negedge clk); // → ST_DONE_REQ

        // Simulate DEADLOCK: Remote also sends Done_Req (not Done_Resp)
        rx_msg_done_req = 1'b1;
        @(negedge clk);
        rx_msg_done_req = 1'b0;
        @(negedge clk); // → ST_DONE

        if (!tx_msg_done_resp) begin
            $error("TEST 2 FAILED: tx_msg_done_resp not sent after deadlock resolution.");
            error_count++;
        end
        if (!exit_to_mbinit) begin
            $error("TEST 2 FAILED: exit_to_mbinit not asserted after crossover resolution.");
            error_count++;
        end
        if (error_count == 0) $display("   [PASS] Test 2: Deadlock correctly resolved — tx_msg_done_resp sent, exit_to_mbinit asserted.");

        en_sbinit = 1'b0;
        @(negedge clk);

        // =====================================================================
        // TEST 3: Repair Routing — All 4 Pattern Permutations (Advanced Package)
        // =====================================================================
        $display("\n[TEST 3] sb_repair_sel routing for all Advanced Package patterns...");
        begin
            logic [3:0] patterns [3:0];
            logic [2:0] expected_sel [3:0];
            patterns[0] = 4'b0001; expected_sel[0] = 3'b000; // bit0: DATASB/CKSB
            patterns[1] = 4'b0010; expected_sel[1] = 3'b001; // bit1: DATASB/CKSBRD
            patterns[2] = 4'b0100; expected_sel[2] = 3'b010; // bit2: DATASBRD/CKSB
            patterns[3] = 4'b1000; expected_sel[3] = 3'b011; // bit3: DATASBRD/CKSBRD

            for (int p = 0; p < 4; p++) begin
                en_sbinit = 1'b1;
                rx_pattern_detected = patterns[p];
                package_type = 1'b0; // Advanced

                @(negedge clk); // Enter ST_SEND_PATTERN
                wait_cycles(50); // Past ST_WAIT_4_ITER into ST_OUT_OF_RESET

                if (sb_repair_sel !== expected_sel[p]) begin
                    $error("TEST 3 FAILED: Pattern %04b → sb_repair_sel=%03b, expected %03b.",
                           patterns[p], sb_repair_sel, expected_sel[p]);
                    error_count++;
                end

                // Fast exit
                rx_msg_out_of_reset = 1'b1; @(negedge clk); rx_msg_out_of_reset = 1'b0; @(negedge clk);
                rx_msg_done_resp = 1'b1; @(negedge clk); rx_msg_done_resp = 1'b0; @(negedge clk); @(negedge clk);
                en_sbinit = 1'b0; @(negedge clk);
                rx_pattern_detected = 4'b0000;
            end
            if (error_count == 0) $display("   [PASS] Test 3: All 4 repair routing paths correct.");
        end

        // =====================================================================
        // TEST 4: Standard Package — sb_repair_sel must remain 3'b000
        // =====================================================================
        $display("\n[TEST 4] Standard Package — sb_repair_sel locked to 3'b000...");
        package_type = 1'b1; // Standard
        en_sbinit = 1'b1;
        rx_pattern_detected = 4'b1000; // Would give 3'b011 in Advanced mode

        @(negedge clk);
        wait_cycles(50);

        if (sb_repair_sel !== 3'b000) begin
            $error("TEST 4 FAILED: sb_repair_sel=%03b for Standard Package, expected 3'b000.", sb_repair_sel);
            error_count++;
        end else $display("   [PASS] Test 4: sb_repair_sel correctly fixed at 000 for Standard Package.");

        // Fast exit
        rx_msg_out_of_reset = 1'b1; @(negedge clk); rx_msg_out_of_reset = 1'b0; @(negedge clk);
        rx_msg_done_resp = 1'b1; @(negedge clk); rx_msg_done_resp = 1'b0; @(negedge clk); @(negedge clk);
        en_sbinit = 1'b0; @(negedge clk);
        package_type = 1'b0;
        rx_pattern_detected = 4'b0000;

        // =====================================================================
        // TEST 5: Timeout → TRAINERROR (remote PHY never responds)
        // =====================================================================
        $display("\n[TEST 5] 8ms Timeout — remote PHY silent...");
        en_sbinit = 1'b1;
        rx_pattern_detected = 4'b0000; // Remote PHY never wakes up

        wait_cycles(TIMEOUT_CYCLES + 5);

        if (!exit_to_trainerror) begin
            $error("TEST 5 FAILED: Did not exit to TRAINERROR after timeout.");
            error_count++;
        end else $display("   [PASS] Test 5: TRAINERROR correctly asserted after timeout.");

        en_sbinit = 1'b0;
        @(negedge clk);

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("\n==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_ltssm_sbinit passed all 5 tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule