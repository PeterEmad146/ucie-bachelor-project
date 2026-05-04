`timescale 1ns / 1ps

module tb_lphy_valid_repair();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    // Logical
    logic [7:0] tvld_l, trdvld_l;
    logic [7:0] rvld_l, rrdvld_l;
    
    // Physical
    logic [7:0] tvld_p, trdvld_p;
    logic [7:0] rvld_p, rrdvld_p;
    
    // Control
    logic [1:0] tx_repair_addr;
    logic [1:0] rx_repair_addr;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_valid_repair dut (.*);

    // Loopback: physical TX → physical RX (module-scope continuous assignment)
    assign rvld_p   = tvld_p;
    assign rrdvld_p = trdvld_p;

    int error_count = 0;

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_valid_repair");
        $display("==========================================================");

        // Standard Frame: Valid + No Credit
        tvld_l   = 8'b0000_1111; 
        trdvld_l = 8'b0000_0000;

        // =====================================================================
        // TEST 1: No Repair (Default 1:1)
        // =====================================================================
        tx_repair_addr = 2'h3;
        rx_repair_addr = 2'h3;
        #1;
        
        if (tvld_p !== 8'b0000_1111 || trdvld_p !== 8'h00) begin
            $error("TEST 1 FAILED: TX Normal mapping is broken.");
            error_count++;
        end
        if (rvld_l !== 8'b0000_1111 || rrdvld_l !== 8'h00) begin
            $error("TEST 1 FAILED: RX Normal mapping is broken.");
            error_count++;
        end

        // =====================================================================
        // TEST 2: Valid Bump Failed (Reroute to Redundant)
        // =====================================================================
        tx_repair_addr = 2'h0;
        rx_repair_addr = 2'h0;
        #1;
        
        // TX physical outputs should show primary dead, redundant active
        if (tvld_p !== 8'h00 || trdvld_p !== 8'b0000_1111) begin
            $error("TEST 2 FAILED: TX failed to map Valid frame to redundant pin.");
            error_count++;
        end
        
        // RX logical outputs should show flawless recovery
        if (rvld_l !== 8'b0000_1111 || rrdvld_l !== 8'h00) begin
            $error("TEST 2 FAILED: RX failed to recover Valid frame from redundant pin.");
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_valid_repair passed all parallel byte routing tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end
endmodule