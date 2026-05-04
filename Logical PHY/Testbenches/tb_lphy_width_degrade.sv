`timescale 1ns / 1ps

module tb_lphy_width_degrade();

    localparam int NUM_LANES = 64;
    localparam int HALF_LANES = 32;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic [1:0] lane_map;
    
    logic [7:0] tx_logical_data  [NUM_LANES-1:0];
    logic [7:0] tx_physical_data [NUM_LANES-1:0];
    
    logic [7:0] rx_physical_data [NUM_LANES-1:0];
    logic [7:0] rx_logical_data  [NUM_LANES-1:0];

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_width_degrade #(.NUM_LANES(NUM_LANES)) dut (.*);

    int error_count = 0;

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_width_degrade (x64)");
        $display("==========================================================");

        // Initialize unique data for all lanes
        for (int i = 0; i < NUM_LANES; i++) begin
            tx_logical_data[i] = i[7:0]; 
            rx_physical_data[i] = 8'(i + 100);
        end
        
        // =====================================================================
        // TEST 1: Full Width (lane_map = 2'b11)
        // =====================================================================
        lane_map = 2'b11;
        #1; // Allow comb logic to propagate
        
        for (int i = 0; i < NUM_LANES; i++) begin
            if (tx_physical_data[i] !== tx_logical_data[i]) begin
                $error("TEST 1 FAILED: TX Full mapping broken at lane %0d", i);
                error_count++;
            end
            if (rx_logical_data[i] !== rx_physical_data[i]) begin
                $error("TEST 1 FAILED: RX Full mapping broken at lane %0d", i);
                error_count++;
            end
        end

        // =====================================================================
        // TEST 2: Lower Half Degradation (lane_map = 2'b01)
        // =====================================================================
        lane_map = 2'b01;
        #1;
        
        // TX Lower Check
        for (int i = 0; i < HALF_LANES; i++) begin
            if (tx_physical_data[i] !== tx_logical_data[i]) begin
                $error("TEST 2 FAILED: TX Lower mapping broken at lane %0d", i);
                error_count++;
            end
            if (rx_logical_data[i] !== rx_physical_data[i]) begin
                $error("TEST 2 FAILED: RX Lower mapping broken at lane %0d", i);
                error_count++;
            end
        end
        // Verify Upper Half is safely parked at 0
        for (int i = HALF_LANES; i < NUM_LANES; i++) begin
            if (tx_physical_data[i] !== 8'h00) begin
                $error("TEST 2 FAILED: TX Upper lanes not parked during lower degradation. Lane %0d = %h", i, tx_physical_data[i]);
                error_count++;
            end
        end

        // =====================================================================
        // TEST 3: Upper Half Degradation (lane_map = 2'b10)
        // =====================================================================
        lane_map = 2'b10;
        #1;
        
        for (int i = 0; i < HALF_LANES; i++) begin
            // Logical 0 should be mapped to Physical 32
            if (tx_physical_data[i + HALF_LANES] !== tx_logical_data[i]) begin
                $error("TEST 3 FAILED: TX Upper mapping broken at Physical %0d", i + HALF_LANES);
                error_count++;
            end
            // Physical 32 should be mapped to Logical 0
            if (rx_logical_data[i] !== rx_physical_data[i + HALF_LANES]) begin
                $error("TEST 3 FAILED: RX Upper mapping broken at Logical %0d", i);
                error_count++;
            end
        end
        
        // Verify Lower Half is safely parked at 0
        for (int i = 0; i < HALF_LANES; i++) begin
            if (tx_physical_data[i] !== 8'h00) begin
                $error("TEST 3 FAILED: TX Lower lanes not parked during upper degradation. Lane %0d = %h", i, tx_physical_data[i]);
                error_count++;
            end
        end

        // =====================================================================
        // TEST 4: Fatal - All Lanes Parked (lane_map = 2'b00)
        // =====================================================================
        lane_map = 2'b00;
        #1;
        
        for (int i = 0; i < NUM_LANES; i++) begin
            if (tx_physical_data[i] !== 8'h00) begin
                $error("TEST 4 FAILED: TX lane %0d not parked in FAIL mode. Got %h", i, tx_physical_data[i]);
                error_count++;
            end
            if (rx_logical_data[i] !== 8'h00) begin
                $error("TEST 4 FAILED: RX lane %0d not zeroed in FAIL mode. Got %h", i, rx_logical_data[i]);
                error_count++;
            end
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_width_degrade passed all scaling and boundary tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end
endmodule