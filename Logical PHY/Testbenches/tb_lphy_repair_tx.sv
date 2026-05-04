`timescale 1ns / 1ps

module tb_lphy_repair_tx();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic [7:0]  tx_logical_data [63:0];
    logic [63:0] lane_failed;

    logic [7:0]  tx_physical_data [63:0];
    logic [7:0]  tx_redundant_data [3:0];

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_repair_tx dut (.*);

    // -------------------------------------------------------------------------
    // Helper Variables
    // -------------------------------------------------------------------------
    int error_count = 0;

    // Initialize logical data so Lane N carries value N
    initial begin
        for (int i = 0; i < 64; i++) begin
            tx_logical_data[i] = i[7:0];
        end
    end

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_repair_tx");
        $display("==========================================================");

        // =====================================================================
        // TEST 1: No Failures (1:1 Mapping)
        // =====================================================================
        lane_failed = 64'h0;
        #1;
        
        for (int i = 0; i < 64; i++) begin
            if (tx_physical_data[i] !== i[7:0]) begin
                $error("TEST 1 FAILED: 1:1 Mapping broke at lane %0d", i);
                error_count++;
            end
        end
        if (tx_redundant_data[0] !== 0 || tx_redundant_data[1] !== 0 ||
            tx_redundant_data[2] !== 0 || tx_redundant_data[3] !== 0) begin
            $error("TEST 1 FAILED: Redundant pins not isolated during 0 failures.");
            error_count++;
        end

        // =====================================================================
        // TEST 2: Single Failure in Lower Group (Lane 5 fails)
        // =====================================================================
        lane_failed = 64'h0;
        lane_failed[5] = 1'b1;
        #1;
        
        // Expected Lower Shift:
        // Redundant 0 gets Logical 0
        // Physical 0-4 gets Logical 1-5
        // Physical 5 gets 0
        // Physical 6-31 gets Logical 6-31
        if (tx_redundant_data[0] !== 8'd0) begin $error("TEST 2 FAILED: TRD[0] mismatch."); error_count++; end
        if (tx_physical_data[0] !== 8'd1) begin $error("TEST 2 FAILED: Phys[0] mismatch."); error_count++; end
        if (tx_physical_data[4] !== 8'd5) begin $error("TEST 2 FAILED: Phys[4] mismatch."); error_count++; end
        if (tx_physical_data[5] !== 8'd0) begin $error("TEST 2 FAILED: Phys[5] not zeroed."); error_count++; end
        if (tx_physical_data[6] !== 8'd6) begin $error("TEST 2 FAILED: Phys[6] mismatch."); error_count++; end

        // =====================================================================
        // TEST 3: Double Failure in Lower Group (Lanes 10 and 20 fail)
        // =====================================================================
        lane_failed = 64'h0;
        lane_failed[10] = 1'b1;
        lane_failed[20] = 1'b1;
        #1;
        
        // Expected Lower Shift:
        // TRD[0] gets Logical 0. TRD[1] gets Logical 31.
        // Phys 0-9 gets Logical 1-10.
        // Phys 10 = 0. Phys 20 = 0.
        // Phys 11-19 gets Logical 11-19 (No shift in the middle).
        // Phys 21-31 gets Logical 20-30.
        
        if (tx_redundant_data[0] !== 8'd0) begin $error("TEST 3 FAILED: TRD[0] mismatch."); error_count++; end
        if (tx_redundant_data[1] !== 8'd31) begin $error("TEST 3 FAILED: TRD[1] mismatch."); error_count++; end
        
        if (tx_physical_data[9] !== 8'd10) begin $error("TEST 3 FAILED: Phys[9] mismatch."); error_count++; end
        if (tx_physical_data[10] !== 8'd0) begin $error("TEST 3 FAILED: Phys[10] not zeroed."); error_count++; end
        
        if (tx_physical_data[15] !== 8'd15) begin $error("TEST 3 FAILED: Middle 1:1 map broken at Phys[15]."); error_count++; end
        
        if (tx_physical_data[20] !== 8'd0) begin $error("TEST 3 FAILED: Phys[20] not zeroed."); error_count++; end
        if (tx_physical_data[21] !== 8'd20) begin $error("TEST 3 FAILED: Phys[21] mismatch."); error_count++; end
        if (tx_physical_data[31] !== 8'd30) begin $error("TEST 3 FAILED: Phys[31] mismatch."); error_count++; end

        // =====================================================================
        // TEST 4: Double Failure in Upper Group (Lanes 40 and 50 fail)
        // =====================================================================
        lane_failed = 64'h0;
        lane_failed[40] = 1'b1;
        lane_failed[50] = 1'b1;
        #1;
        
        // Expected Upper Shift:
        // TRD[2] gets Logical 32. TRD[3] gets Logical 63.
        if (tx_redundant_data[2] !== 8'd32) begin $error("TEST 4 FAILED: TRD[2] mismatch."); error_count++; end
        if (tx_redundant_data[3] !== 8'd63) begin $error("TEST 4 FAILED: TRD[3] mismatch."); error_count++; end
        
        if (tx_physical_data[39] !== 8'd40) begin $error("TEST 4 FAILED: Phys[39] mismatch."); error_count++; end
        if (tx_physical_data[40] !== 8'd0) begin $error("TEST 4 FAILED: Phys[40] not zeroed."); error_count++; end
        
        if (tx_physical_data[45] !== 8'd45) begin $error("TEST 4 FAILED: Middle 1:1 map broken at Phys[45]."); error_count++; end
        
        if (tx_physical_data[50] !== 8'd0) begin $error("TEST 4 FAILED: Phys[50] not zeroed."); error_count++; end
        if (tx_physical_data[51] !== 8'd50) begin $error("TEST 4 FAILED: Phys[51] mismatch."); error_count++; end
        if (tx_physical_data[63] !== 8'd62) begin $error("TEST 4 FAILED: Phys[63] mismatch."); error_count++; end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_repair_tx passed all bi-directional shift tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule