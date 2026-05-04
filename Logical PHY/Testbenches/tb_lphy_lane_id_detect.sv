`timescale 1ns / 1ps

module tb_lphy_lane_id_detect();

    // -------------------------------------------------------------------------
    // Parameters & Signals
    // -------------------------------------------------------------------------
    localparam int NUM_LANES = 16; // Test with Standard Package width for speed

    logic clk;
    logic rst_n;
    
    logic [7:0] rx_lane_data_in [NUM_LANES - 1:0];
    logic       rx_lane_valid;
    logic       en_lane_check;
    logic       is_reversed;
    
    logic [NUM_LANES - 1:0] lane_failed;
    logic                   check_done;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_lane_id_detect #(.NUM_LANES(NUM_LANES)) dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    int error_count = 0;
    
    logic [7:0] id;

    // Helper task to drive 1 cycle of standard patterns
    task drive_pattern_cycle(input logic is_rev, input logic is_b0, input logic inject_err = 0);
        for (int i = 0; i < NUM_LANES; i++) begin
            id = is_rev ? (NUM_LANES - 1 - i) : i;
            
            if (is_b0) rx_lane_data_in[i] = {id[3:0], 4'b1010};
            else       rx_lane_data_in[i] = {4'b1010, id[7:4]};
            
            // Inject error on Lane 5 if requested
            if (inject_err && i == 5) rx_lane_data_in[i] = 8'hFF;
        end
        @(negedge clk);
    endtask

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_lane_id_detect");
        $display("==========================================================");

        rst_n = 0; rx_lane_valid = 0; en_lane_check = 0; is_reversed = 0;
        for (int i = 0; i < NUM_LANES; i++) rx_lane_data_in[i] = 8'h00;
        
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: Normal Detection (All lanes pass)
        // =====================================================================
        $display("TEST 1: Normal ID Detection...");
        rx_lane_valid = 1;
        en_lane_check = 1;
        is_reversed = 0;
        
        // Feed 128 full 16-bit patterns (256 clock cycles)
        for (int c = 0; c < 128; c++) begin
            drive_pattern_cycle(.is_rev(0), .is_b0(1)); // Cycle 0 (Even)
            drive_pattern_cycle(.is_rev(0), .is_b0(0)); // Cycle 1 (Odd) - Evaluates here
        end
        
        if (!check_done) begin $error("TEST 1 FAILED: check_done did not assert."); error_count++; end
        if (lane_failed !== 16'h0000) begin $error("TEST 1 FAILED: False lane failures detected: %b", lane_failed); error_count++; end

        en_lane_check = 0;
        @(negedge clk);

        // =====================================================================
        // TEST 2: Single Lane Failure (Lane 5 is dead)
        // =====================================================================
        $display("TEST 2: Hard Failure on Lane 5...");
        en_lane_check = 1;
        is_reversed = 0;
        
        for (int c = 0; c < 128; c++) begin
            // inject_err=1 corrupts Lane 5 constantly
            drive_pattern_cycle(.is_rev(0), .is_b0(1), .inject_err(1)); 
            drive_pattern_cycle(.is_rev(0), .is_b0(0), .inject_err(1)); 
        end
        
        if (!check_done) begin $error("TEST 2 FAILED: check_done did not assert."); error_count++; end
        if (lane_failed !== 16'h0020) begin $error("TEST 2 FAILED: Expected only Lane 5 to fail. Got %b", lane_failed); error_count++; end

        en_lane_check = 0;
        @(negedge clk);

        // =====================================================================
        // TEST 3: Reversed Detection 
        // =====================================================================
        $display("TEST 3: Reversed Mapping Detection...");
        en_lane_check = 1;
        is_reversed = 1; // Tell DUT to look for reversed IDs
        
        for (int c = 0; c < 128; c++) begin
            // Send reversed patterns over the wire
            drive_pattern_cycle(.is_rev(1), .is_b0(1)); 
            drive_pattern_cycle(.is_rev(1), .is_b0(0)); 
        end
        
        if (lane_failed !== 16'h0000) begin $error("TEST 3 FAILED: Reversed detection failed: %b", lane_failed); error_count++; end

        en_lane_check = 0;
        @(negedge clk);

        // =====================================================================
        // TEST 4: Transient Noise Recovery
        // =====================================================================
        $display("TEST 4: Transient Noise Recovery...");
        en_lane_check = 1;
        is_reversed = 0;
        
        for (int c = 0; c < 128; c++) begin
            // Inject error on Lane 5 ONLY during the first 10 patterns
            if (c < 10) begin
                drive_pattern_cycle(.is_rev(0), .is_b0(1), .inject_err(1)); 
                drive_pattern_cycle(.is_rev(0), .is_b0(0), .inject_err(1));
            end else begin
                // Lane 5 recovers and sends clean data for the remaining 118 patterns
                drive_pattern_cycle(.is_rev(0), .is_b0(1), .inject_err(0)); 
                drive_pattern_cycle(.is_rev(0), .is_b0(0), .inject_err(0));
            end
        end
        
        // Because Lane 5 eventually had 16 consecutive hits after cycle 10, it should PASS!
        if (lane_failed !== 16'h0000) begin $error("TEST 4 FAILED: Did not recover from transient noise: %b", lane_failed); error_count++; end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_lane_id_detect passed all detection and recovery tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule