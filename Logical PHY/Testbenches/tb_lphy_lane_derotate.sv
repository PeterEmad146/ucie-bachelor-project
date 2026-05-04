`timescale 1ns / 1ps

module tb_lphy_lane_derotate();

    localparam int NUM_LANES = 16;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    
    logic [7:0] rx_lane_data_in [NUM_LANES-1:0];
    logic       rx_lane_valid;
    
    logic       en_reversal_check;
    logic       reversal_detected;
    logic       reversal_check_done;
    
    logic [7:0] rx_lane_data_out [NUM_LANES-1:0];
    
    logic [7:0] expected_val;
    logic [7:0] id;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_lane_derotate #(.NUM_LANES(NUM_LANES)) dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    int error_count = 0;

    // Helper task to drive 1 cycle of standard patterns
    task drive_pattern_cycle(input logic is_rev, input logic is_b0);
        for (int i = 0; i < NUM_LANES; i++) begin
            id = is_rev ? (NUM_LANES - 1 - i) : i;
            if (is_b0) rx_lane_data_in[i] = {id[3:0], 4'b1010};
            else       rx_lane_data_in[i] = {4'b1010, id[7:4]};
        end
        @(negedge clk);
    endtask

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_lane_derotate");
        $display("==========================================================");

        rst_n = 0; rx_lane_valid = 0; en_reversal_check = 0;
        for (int i = 0; i < NUM_LANES; i++) rx_lane_data_in[i] = 8'h00;
        
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: Normal Detection & Passthrough
        // =====================================================================
        $display("TEST 1: Normal Detection...");
        rx_lane_valid = 1;
        en_reversal_check = 1;
        
        // Feed 128 full 16-bit patterns (256 clock cycles)
        for (int c = 0; c < 128; c++) begin
            drive_pattern_cycle(.is_rev(0), .is_b0(1));
            drive_pattern_cycle(.is_rev(0), .is_b0(0)); 
        end
        
        if (!reversal_check_done) begin $error("TEST 1 FAILED: check_done did not assert."); error_count++; end
        if (reversal_detected) begin $error("TEST 1 FAILED: Falsely detected reversal."); error_count++; end

        en_reversal_check = 0; // Lock the decision
        
        // Push sequential data to verify 1:1 mapping
        for (int i = 0; i < NUM_LANES; i++) rx_lane_data_in[i] = i[7:0];
        @(negedge clk);
        @(negedge clk); // Pipeline delay
        
        for (int i = 0; i < NUM_LANES; i++) begin
            if (rx_lane_data_out[i] !== i[7:0]) begin
                $error("TEST 1 FAILED: 1:1 Datapath broken at lane %0d", i);
                error_count++;
            end
        end

        // =====================================================================
        // TEST 2: Reversed Detection & Derotation Swap
        // =====================================================================
        $display("TEST 2: Reversed Detection & Swapping...");
        // Reset the check state
        en_reversal_check = 1;
        
        // Feed 128 full reversed patterns
        for (int c = 0; c < 128; c++) begin
            drive_pattern_cycle(.is_rev(1), .is_b0(1));
            drive_pattern_cycle(.is_rev(1), .is_b0(0)); 
        end
        
        if (!reversal_check_done) begin $error("TEST 2 FAILED: check_done did not assert."); error_count++; end
        if (!reversal_detected) begin $error("TEST 2 FAILED: Failed to detect reversal."); error_count++; end

        en_reversal_check = 0; // Lock the decision
        
        // Push sequential data (0, 1, 2... 15) into the physical inputs
        for (int i = 0; i < NUM_LANES; i++) rx_lane_data_in[i] = i[7:0];
        @(negedge clk);
        @(negedge clk); // Pipeline delay
        
        // Because reversed_detected is 1, the datapath should flip the array!
        // rx_lane_data_out[0] should get rx_lane_data_in[15]
        for (int i = 0; i < NUM_LANES; i++) begin
            expected_val = (NUM_LANES - 1 - i);
            if (rx_lane_data_out[i] !== expected_val) begin
                $error("TEST 2 FAILED: Datapath did not derotate! Lane %0d got %h, expected %h", i, rx_lane_data_out[i], expected_val);
                error_count++;
            end
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_lane_derotate passed all voting and datapath routing tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule