`timescale 1ns / 1ps

module tb_lphy_pattern_gen();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic [7:0]  lane_id;
    logic        select_valtrain;
    logic [15:0] pattern_out;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_pattern_gen dut (.*);

    // -------------------------------------------------------------------------
    // Helper Variables
    // -------------------------------------------------------------------------
    int error_count = 0;

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_pattern_gen");
        $display("==========================================================");

        // =====================================================================
        // TEST 1: VALTRAIN Pattern
        // =====================================================================
        lane_id = 8'hAA; // Put garbage on the lane_id to ensure it gets ignored
        select_valtrain = 1'b1;
        #1; // Allow combinatorial logic to resolve
        
        if (pattern_out !== 16'h0F0F) begin
            $error("TEST 1 FAILED: VALTRAIN expected 16'h0F0F, got %h", pattern_out);
            error_count++;
        end

        // =====================================================================
        // TEST 2: Lane ID Pattern (Lane 0)
        // =====================================================================
        lane_id = 8'h00;
        select_valtrain = 1'b0;
        #1;
        
        // Expected: bits [15:12] = 1010 (A), bits [11:4] = 00, bits [3:0] = 1010 (A)
        // Result: 16'hA00A
        if (pattern_out !== 16'hA00A) begin
            $error("TEST 2 FAILED: Lane 0 expected 16'hA00A, got %h", pattern_out);
            error_count++;
        end

        // =====================================================================
        // TEST 3: Lane ID Pattern (Lane 63 - Max Advanced Package Lane)
        // =====================================================================
        lane_id = 8'd63; // 63 is 8'h3F
        select_valtrain = 1'b0;
        #1;
        
        // Expected: A, 3F, A -> 16'hA3FA
        if (pattern_out !== 16'hA3FA) begin
            $error("TEST 3 FAILED: Lane 63 expected 16'hA3FA, got %h", pattern_out);
            error_count++;
        end

        // =====================================================================
        // TEST 4: Lane ID Pattern (Lane 255 - Max 8-bit limit)
        // =====================================================================
        lane_id = 8'hFF;
        select_valtrain = 1'b0;
        #1;
        
        // Expected: A, FF, A -> 16'hAFFA
        if (pattern_out !== 16'hAFFA) begin
            $error("TEST 4 FAILED: Lane 255 expected 16'hAFFA, got %h", pattern_out);
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_pattern_gen passed all framing and muxing tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule