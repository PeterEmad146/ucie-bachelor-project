`timescale 1ns / 1ps

module tb_lphy_byte_lane_map();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    
    logic [1:0]   link_width;
    logic         lp_valid;
    logic         lp_irdy;
    logic         pl_trdy;
    logic [511:0] lp_data;
    
    logic         lane_valid;
    logic [7:0]   lane_data [63:0];

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_byte_lane_map dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    // -------------------------------------------------------------------------
    // Helper Tasks and Variables
    // -------------------------------------------------------------------------
    int error_count = 0;
    logic [511:0] test_pattern;
    
    // Generate a predictable test pattern where Byte N contains the value N
    initial begin
        for (int i = 0; i < 64; i++) begin
            test_pattern[i*8 +: 8] = i; 
        end
    end

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_byte_lane_map");
        $display("==========================================================");

        // Reset
        rst_n = 0;
        link_width = 2'b10;
        lp_valid = 0;
        lp_irdy = 0;
        lp_data = 0;
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: x64 Mode (1-cycle transfer)
        // =====================================================================
        $display("Running TEST 1: x64 Mode...");
        link_width = 2'b10;
        
        lp_valid = 1;
        lp_irdy = 1;
        lp_data = test_pattern;
        
        // Ensure PHY is ready
        if (!pl_trdy) begin $error("TEST 1 FAILED: pl_trdy should be 1."); error_count++; end
        
        @(negedge clk);
        lp_valid = 0; // Drop valid after transfer
        
        // Check output on the next cycle
        if (!lane_valid) begin $error("TEST 1 FAILED: lane_valid should be 1."); error_count++; end
        if (!pl_trdy) begin $error("TEST 1 FAILED: PHY should not be busy in x64 mode."); error_count++; end
        
        for (int i = 0; i < 64; i++) begin
            if (lane_data[i] !== i[7:0]) begin
                $error("TEST 1 FAILED: Data mismatch at lane %0d. Expected %0d, Got %0d", i, i, lane_data[i]);
                error_count++;
            end
        end
        @(negedge clk);

        // =====================================================================
        // TEST 2: x32 Mode (2-cycle transfer)
        // =====================================================================
        $display("Running TEST 2: x32 Mode...");
        link_width = 2'b01;
        
        lp_valid = 1;
        lp_irdy = 1;
        lp_data = test_pattern;
        
        @(negedge clk);
        lp_valid = 0; // Stop pushing new data
        
        // Cycle 1 Output: Should map Bytes 0-31
        if (!lane_valid) begin $error("TEST 2 FAILED: lane_valid should be 1 (Cycle 1)."); error_count++; end
        if (pl_trdy) begin $error("TEST 2 FAILED: PHY should be BUSY (pl_trdy=0) processing chunk 2."); error_count++; end
        
        for (int i = 0; i < 32; i++) begin
            if (lane_data[i] !== i[7:0]) begin
                $error("TEST 2 (Cycle 1) FAILED: Data mismatch at lane %0d.", i);
                error_count++;
            end
        end
        
        @(negedge clk);
        
        // Cycle 2 Output: Should map Bytes 32-63
        if (!lane_valid) begin $error("TEST 2 FAILED: lane_valid should be 1 (Cycle 2)."); error_count++; end
        if (!pl_trdy) begin $error("TEST 2 FAILED: PHY should be READY (pl_trdy=1) after finishing."); error_count++; end
        
        for (int i = 0; i < 32; i++) begin
            if (lane_data[i] !== (i+32)) begin
                $error("TEST 2 (Cycle 2) FAILED: Data mismatch at lane %0d.", i);
                error_count++;
            end
        end
        @(negedge clk);

        // =====================================================================
        // TEST 3: x16 Mode (4-cycle transfer)
        // =====================================================================
        $display("Running TEST 3: x16 Mode...");
        link_width = 2'b00;
        
        lp_valid = 1;
        lp_irdy = 1;
        lp_data = test_pattern;
        
        @(negedge clk); // Load Data
        lp_valid = 0; 
        
        for (int chunk = 0; chunk < 4; chunk++) begin
            if (!lane_valid) begin $error("TEST 3 FAILED: lane_valid dropped early at chunk %0d.", chunk); error_count++; end
            
            // Check trdy state (Busy for first 3 chunks, Ready on the last)
            if (chunk < 3 && pl_trdy) begin $error("TEST 3 FAILED: PHY should be BUSY at chunk %0d.", chunk); error_count++; end
            if (chunk == 3 && !pl_trdy) begin $error("TEST 3 FAILED: PHY should be READY at chunk 3.", chunk); error_count++; end
            
            // Verify the 16 mapped lanes
            for (int i = 0; i < 16; i++) begin
                if (lane_data[i] !== (i + (chunk*16))) begin
                    $error("TEST 3 (Chunk %0d) FAILED: Data mismatch at lane %0d.", chunk, i);
                    error_count++;
                end
            end
            @(negedge clk);
        end

        // =====================================================================
        // TEST 4: The lp_irdy Handshake Bug
        // =====================================================================
        $display("Running TEST 4: IRDY Wait-State handling...");
        link_width = 2'b10;
        
        // Adapter asserts valid but NOT ready (wait state)
        lp_valid = 1;
        lp_irdy = 0; 
        lp_data = 512'hFFFF; 
        
        @(negedge clk);
        
        // PHY should NOT have latched this data because irdy was low.
        if (lane_valid) begin
            $error("TEST 4 FAILED: PHY latched data without lp_irdy=1. Ensure you fixed line 28!");
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_byte_lane_map passed all demultiplexing bounds.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end
endmodule