`timescale 1ns / 1ps

module tb_lphy_d2c_cal();

    localparam int NUM_LANES = 16; // Use 16 for faster simulation
    localparam int SETTLE_CYCLES = 4;
    localparam int TEST_CYCLES = 16;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    
    logic start_cal;
    logic [15:0] error_threshold;
    
    logic [7:0] rx_data [NUM_LANES-1:0];
    logic [7:0] expected_data [NUM_LANES-1:0];
    
    logic [5:0] pi_phase;
    logic cal_done;
    logic cal_error;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_d2c_cal #(
        .NUM_LANES(NUM_LANES),
        .SETTLE_CYCLES(SETTLE_CYCLES),
        .TEST_CYCLES(TEST_CYCLES)
    ) dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    int error_count = 0;
    logic inject_dead_channel = 0; // ADDED: Fault injection flag

    // -------------------------------------------------------------------------
    // AFE / Channel Simulation Model
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        for (int i = 0; i < NUM_LANES; i++) begin
            expected_data[i] <= 8'hAA; 
            
            // Fault Injection Override
            if (inject_dead_channel && i == 0) begin
                rx_data[i] <= 8'h00; // Dead channel outputs garbage/0
            end 
            // Normal Eye Simulation
            else if (pi_phase >= 20 && pi_phase <= 44) begin
                rx_data[i] <= 8'hAA; // Clean signal
            end else begin
                rx_data[i] <= ($urandom % 2 == 0) ? 8'hAA : 8'hFF; // Jitter
            end
        end
    end

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_d2c_cal");
        $display("==========================================================");

        rst_n = 0;
        start_cal = 0;
        error_threshold = 16'd0; // Zero tolerance for errors
        
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: Full Calibration Sweep
        // =====================================================================
        $display("Initiating PI Phase Sweep...");
        start_cal = 1'b1;
        
        // Wait for the state machine to complete the sweep
        wait(cal_done == 1'b1);
        @(negedge clk);
        
        start_cal = 1'b0; // De-assert start
        
        // Let's check the math.
        // Eye was set from 20 to 44.
        // Center = 20 + ((44 - 20) / 2) = 20 + 12 = 32.
        if (cal_error) begin
            $error("TEST 1 FAILED: Falsely reported cal_error (no eye found).");
            error_count++;
        end
        if (pi_phase !== 6'd32) begin
            $error("TEST 1 FAILED: Incorrect Center Phase calculated. Expected 32, Got %0d", pi_phase);
            error_count++;
        end

        // =====================================================================
        // TEST 2: No Eye Found (Error Condition)
        // =====================================================================
        $display("Running Bad Channel Test (No Eye)...");
        
        // Use our clean control flag instead of a simulator 'force'
        inject_dead_channel = 1'b1; 
        
        @(negedge clk);
        // Wait for state machine to return to IDLE after start_cal dropped
        repeat(3) @(negedge clk);
        
        start_cal = 1'b1;
        wait(cal_done == 1'b1);
        @(negedge clk);
        
        start_cal = 1'b0;
        
        if (!cal_error) begin
            $error("TEST 2 FAILED: Did not trigger cal_error on a dead channel.");
            error_count++;
        end
        
        // Release the fault
        inject_dead_channel = 1'b0;

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_d2c_cal passed all phase sweep and centering tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end
endmodule