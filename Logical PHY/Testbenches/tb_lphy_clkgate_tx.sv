`timescale 1ns / 1ps

module tb_lphy_clkgate_tx();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    
    logic free_run_mode;
    logic valid_in;
    logic gated_clk;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_clkgate_tx dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz Test Clock
    end

    // -------------------------------------------------------------------------
    // Edge Counting Monitor
    // -------------------------------------------------------------------------
    int gated_edge_count = 0;
    always @(posedge gated_clk) begin
        gated_edge_count++;
    end

    int error_count = 0;

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_clkgate_tx");
        $display("==========================================================");

        // Reset Sequence
        rst_n = 0;
        free_run_mode = 0;
        valid_in = 0;
        
        @(negedge clk);
        rst_n = 1;
        
        // =====================================================================
        // TEST 1: Idle State (No Clock)
        // =====================================================================
        // Wait 5 clock cycles. The gated_clk should not fire.
        repeat(5) @(negedge clk);
        
        if (gated_edge_count !== 0) begin
            $error("TEST 1 FAILED: Gated clock fired %0d times while idle.", gated_edge_count);
            error_count++;
        end

        // =====================================================================
        // TEST 2: Active Data + 16 UI Postamble
        // =====================================================================
        gated_edge_count = 0; // Reset counter
        
        valid_in = 1'b1;
        // Hold valid for exactly 3 clock cycles
        repeat(3) @(negedge clk);
        valid_in = 1'b0;
        
        // Wait 5 more clock cycles to allow postamble to finish and idle to resume
        repeat(5) @(negedge clk);
        
        // EXPECTATION: 3 active cycles + 2 postamble cycles = 5 total pulses.
        if (gated_edge_count !== 5) begin
            $error("TEST 2 FAILED: Expected exactly 5 clock pulses, but got %0d.", gated_edge_count);
            error_count++;
        end

        // =====================================================================
        // TEST 3: Free Run Mode
        // =====================================================================
        gated_edge_count = 0;
        
        free_run_mode = 1'b1; // Override gating
        valid_in = 1'b0;      // No data
        
        repeat(4) @(negedge clk);
        free_run_mode = 1'b0; // Turn off override
        
        // Since we dropped free_run_mode, the clock should stop instantly 
        // (no postamble is generated for free-run dropping)
        // Wait a few cycles to ensure it stopped
        repeat(3) @(negedge clk);
        
        // EXPECTATION: Exactly 4 pulses.
        if (gated_edge_count !== 4) begin
            $error("TEST 3 FAILED: Free run mode expected 4 pulses, got %0d.", gated_edge_count);
            error_count++;
        end

        // =====================================================================
        // TEST 4: Postamble Interruption (Valid Returns Quickly)
        // =====================================================================
        gated_edge_count = 0;
        
        valid_in = 1'b1;
        @(negedge clk); // 1 active cycle
        
        valid_in = 1'b0;
        @(negedge clk); // 1 postamble cycle (counter = 1)
        
        valid_in = 1'b1; // Valid returns BEFORE postamble finishes!
        @(negedge clk); // 1 active cycle (counter resets to 0)
        
        valid_in = 1'b0; 
        repeat(5) @(negedge clk); // Wait for the final 2 postamble cycles + idle
        
        // EXPECTATION: 
        // 1 (Active) + 1 (Interrupted Postamble) + 1 (Active) + 2 (Final Postamble) = 5 pulses.
        // Crucially, the clock should never have stopped during this gap.
        if (gated_edge_count !== 5) begin
            $error("TEST 4 FAILED: Interrupted postamble expected 5 pulses, got %0d.", gated_edge_count);
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_clkgate_tx passed all gating, postamble, and free-run tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule