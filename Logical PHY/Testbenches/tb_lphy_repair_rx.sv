`timescale 1ns / 1ps

module tb_lphy_repair_rx();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic [7:0] rx_physical_data [63:0]; 
    logic [7:0] rx_redundant_data [3:0];
    logic [63:0] lane_failed;
    
    logic [7:0] rx_logical_data [63:0];

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_repair_rx dut (.*);

    // -------------------------------------------------------------------------
    // Helper Variables
    // -------------------------------------------------------------------------
    int error_count = 0;

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_repair_rx");
        $display("==========================================================");

        // Reset inputs
        lane_failed = 64'h0;
        for (int i = 0; i < 64; i++) rx_physical_data[i] = 8'h00;
        for (int i = 0; i < 4; i++)  rx_redundant_data[i] = 8'h00;
        #1;

        // =====================================================================
        // TEST 1: No Failures (1:1 Mapping)
        // =====================================================================
        // Feed physical lane N with value N
        for (int i = 0; i < 64; i++) rx_physical_data[i] = i[7:0];
        lane_failed = 64'h0;
        #1;
        
        for (int i = 0; i < 64; i++) begin
            if (rx_logical_data[i] !== i[7:0]) begin
                $error("TEST 1 FAILED: 1:1 Mapping broke at logical lane %0d. Got %h", i, rx_logical_data[i]);
                error_count++;
            end
        end

        // =====================================================================
        // TEST 2: Single Failure in Lower Group (Lane 5 fails)
        // =====================================================================
        // The TX would have shifted logical 0 to TRD0, and logical 1-5 to physical 0-4.
        // We simulate that arrival state:
        for (int i = 0; i < 64; i++) rx_physical_data[i] = i[7:0]; // Baseline
        rx_redundant_data[0] = 8'd0; // Logical 0 arrives on Redundant 0
        rx_physical_data[0]  = 8'd1; // Logical 1 arrives on Physical 0
        rx_physical_data[1]  = 8'd2;
        rx_physical_data[2]  = 8'd3;
        rx_physical_data[3]  = 8'd4;
        rx_physical_data[4]  = 8'd5;
        rx_physical_data[5]  = 8'hFF; // Dead physical lane (Garbage)
        
        lane_failed = 64'h0;
        lane_failed[5] = 1'b1;
        #1;
        
        // The RX module should untangle this back to 0, 1, 2, 3, 4, 5...
        for (int i = 0; i < 10; i++) begin
            if (rx_logical_data[i] !== i[7:0]) begin
                $error("TEST 2 FAILED: Failed to un-shift Lane 5 failure at logical %0d. Got %h", i, rx_logical_data[i]);
                error_count++;
            end
        end

        // =====================================================================
        // TEST 3: Double Failure in Upper Group (Lanes 40 and 50 fail)
        // =====================================================================
        // Reset inputs
        for (int i = 0; i < 64; i++) rx_physical_data[i] = i[7:0];
        lane_failed = 64'h0;
        
        // TX Behavior simulation:
        // Logical 32 -> TRD 2
        // Logical 33-40 -> Phys 32-39
        // Phys 40 is DEAD
        // Logical 41-49 -> Phys 41-49 (1:1 mapping in the middle)
        // Phys 50 is DEAD
        // Logical 50-62 -> Phys 51-63
        // Logical 63 -> TRD 3
        
        rx_redundant_data[2] = 8'd32;
        for (int i = 33; i <= 40; i++) rx_physical_data[i-1] = i[7:0];
        rx_physical_data[40] = 8'hFF; // Dead
        
        // 41 to 49 are 1:1, so they remain their default values.
        
        rx_physical_data[50] = 8'hFF; // Dead
        for (int i = 50; i <= 62; i++) rx_physical_data[i+1] = i[7:0];
        rx_redundant_data[3] = 8'd63;
        
        lane_failed[40] = 1'b1;
        lane_failed[50] = 1'b1;
        #1;
        
        // The RX module should perfectly reconstruct the 32 to 63 sequence
        for (int i = 32; i < 64; i++) begin
            if (rx_logical_data[i] !== i[7:0]) begin
                $error("TEST 3 FAILED: Failed to un-shift Double Failure at logical %0d. Got %h", i, rx_logical_data[i]);
                error_count++;
            end
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_repair_rx passed all inverse mapping tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule