`timescale 1ns / 1ps

module tb_lphy_data_repair_ctrl();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic        clk;
    logic        rst_n;
    logic        package_type;
    logic [63:0] lane_failed;
    logic        check_done;

    logic [7:0]  trd_repair_addr [3:0];
    logic [1:0]  lane_map;
    logic        is_unrepairable;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_data_repair_ctrl dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    int error_count = 0;

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_data_repair_ctrl");
        $display("==========================================================");

        // Reset
        rst_n = 0;
        package_type = 0; // Default to Advanced
        lane_failed = 64'h0;
        check_done = 0;
        
        @(negedge clk);
        rst_n = 1;
        
        // =====================================================================
        // TEST 1: Advanced Package - Perfect Link
        // =====================================================================
        package_type = 1'b0; // Advanced
        lane_failed = 64'h0;
        
        check_done = 1; @(negedge clk); check_done = 0;
        
        if (lane_map !== 2'b11 || is_unrepairable !== 1'b0) begin
            $error("TEST 1 FAILED: Expected 11 (x64), no error.");
            error_count++;
        end

        // =====================================================================
        // TEST 2: Advanced Package - Repaired (1 Lower Fail, 2 Upper Fails)
        // =====================================================================
        lane_failed = 64'h0;
        lane_failed[5]  = 1'b1; // Lower 1
        lane_failed[40] = 1'b1; // Upper 1
        lane_failed[41] = 1'b1; // Upper 2
        
        check_done = 1; @(negedge clk); check_done = 0;
        
        if (lane_map !== 2'b11 || is_unrepairable !== 1'b0) begin
            $error("TEST 2 FAILED: Expected fully repaired x64 link.");
            error_count++;
        end
        if (trd_repair_addr[0] !== 8'd5 || trd_repair_addr[2] !== 8'd40 || trd_repair_addr[3] !== 8'd41) begin
            $error("TEST 2 FAILED: trd_repair_addr mismatch.");
            error_count++;
        end

        // =====================================================================
        // TEST 3: Advanced Package - Degrade to x32 (3 Lower Fails, 0 Upper Fails)
        // =====================================================================
        lane_failed = 64'h0;
        lane_failed[1] = 1'b1;
        lane_failed[2] = 1'b1;
        lane_failed[3] = 1'b1; // 3 lower fails exceeds redundancy
        
        check_done = 1; @(negedge clk); check_done = 0;
        
        if (is_unrepairable !== 1'b0) begin
            $error("TEST 3 FAILED: Should not be unrepairable, it can degrade to Upper x32.");
            error_count++;
        end
        if (lane_map !== 2'b10) begin
            $error("TEST 3 FAILED: Expected lane_map 10 (Upper x32). Got %b", lane_map);
            error_count++;
        end

        // =====================================================================
        // TEST 4: Advanced Package - Fatal (3 Lower Fails, 3 Upper Fails)
        // =====================================================================
        lane_failed[40] = 1'b1;
        lane_failed[41] = 1'b1;
        lane_failed[42] = 1'b1; 
        
        check_done = 1; @(negedge clk); check_done = 0;
        
        if (is_unrepairable !== 1'b1 || lane_map !== 2'b00) begin
            $error("TEST 4 FAILED: Expected Fatal (00, unrepairable).");
            error_count++;
        end

        // =====================================================================
        // TEST 5: Standard Package - Degrade to x8 (1 Lower Fail)
        // =====================================================================
        package_type = 1'b1; // Standard
        lane_failed = 64'h0;
        lane_failed[2] = 1'b1; // Lower 1
        
        check_done = 1; @(negedge clk); check_done = 0;
        
        if (is_unrepairable !== 1'b0 || lane_map !== 2'b10) begin
            $error("TEST 5 FAILED: Expected Standard to degrade to Upper x8 (lane_map=10).");
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_data_repair_ctrl passed all width degradation boundary tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule