`timescale 1ns / 1ps

module tb_lphy_valid_framer();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    
    logic lane_valid;
    logic credit_return;
    
    logic [7:0] valid_frame_out;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_valid_framer dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz Test Clock
    end

    int error_count = 0;

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_valid_framer");
        $display("==========================================================");

        // Reset Sequence
        rst_n = 0;
        lane_valid = 0;
        credit_return = 0;
        
        @(negedge clk);
        rst_n = 1;
        
        // =====================================================================
        // TEST 1: Reset Condition
        // =====================================================================
        // Directly after reset, output should be 0 before any valid clock edges
        if (valid_frame_out !== 8'b0000_0000) begin
            $error("TEST 1 FAILED: Reset did not clear the valid_frame_out.");
            error_count++;
        end

        // =====================================================================
        // TEST 2: No Data + No Credit (Idle)
        // =====================================================================
        lane_valid = 1'b0;
        credit_return = 1'b0;
        @(negedge clk); // Allow posedge to process
        
        if (valid_frame_out !== 8'b0000_0000) begin
            $error("TEST 2 FAILED: Expected 0000_0000, Got %b", valid_frame_out);
            error_count++;
        end

        // =====================================================================
        // TEST 3: Data Valid + No Credit
        // =====================================================================
        lane_valid = 1'b1;
        credit_return = 1'b0;
        @(negedge clk);
        
        if (valid_frame_out !== 8'b0000_1111) begin
            $error("TEST 3 FAILED: Expected 0000_1111, Got %b", valid_frame_out);
            error_count++;
        end

        // =====================================================================
        // TEST 4: Data Valid + 1 Credit
        // =====================================================================
        lane_valid = 1'b1;
        credit_return = 1'b1;
        @(negedge clk);
        
        if (valid_frame_out !== 8'b1111_1111) begin
            $error("TEST 4 FAILED: Expected 1111_1111, Got %b", valid_frame_out);
            error_count++;
        end

        // =====================================================================
        // TEST 5: No Data + 1 Credit
        // =====================================================================
        lane_valid = 1'b0;
        credit_return = 1'b1;
        @(negedge clk);
        
        if (valid_frame_out !== 8'b1111_0000) begin
            $error("TEST 5 FAILED: Expected 1111_0000, Got %b", valid_frame_out);
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_valid_framer passed all Table 17 framing constraints.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule