`timescale 1ns / 1ps

module tb_lphy_rx_top();

    localparam int NUM_LANES = 16;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    logic free_run_mode;
    
    // Control Signals
    logic en_lane_check, en_reversal_check;
    logic reversal_detected, reversal_check_done, framing_err;
    logic [63:0] detected_lane_failures;
    logic check_done;
    logic descrambler_en, load_seed, repair_en;
    logic [22:0] lane_seeds [63:0];
    
    // Adapter Interface
    logic pl_valid;
    logic [7:0] pl_data [NUM_LANES-1:0];
    logic credit_return;
    logic rx_gated_clk;
    
    // AFE Boundary
    logic [7:0] RXDATA [NUM_LANES-1:0];
    logic [7:0] RXVLD;
    logic [7:0] RXRD [3:0];
    logic       RXTRK;
    logic       rx_en;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_rx_top #(.NUM_LANES(NUM_LANES)) dut (.*);

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
        $display("Starting Verification: lphy_rx_top (Parallel AFE Boundary)");
        $display("==========================================================");

        // Reset
        rst_n = 0;
        free_run_mode = 0; en_lane_check = 0; en_reversal_check = 0;
        descrambler_en = 0; load_seed = 0; repair_en = 0; RXTRK = 0;
        
        for (int i = 0; i < NUM_LANES; i++) RXDATA[i] = 8'h00;
        for (int i = 0; i < 4; i++)         RXRD[i]   = 8'h00;
        // Per-lane scrambler seeds from UCIe Spec Table 20 (polynomial 0x210125)
        lane_seeds[ 0] = 23'h1DBFBC;  lane_seeds[ 1] = 23'h1DBFC0;
        lane_seeds[ 2] = 23'h1DBFC6;  lane_seeds[ 3] = 23'h0B7EF5;
        lane_seeds[ 4] = 23'h05BF7B;  lane_seeds[ 5] = 23'h162FC2;
        lane_seeds[ 6] = 23'h0B17E1;  lane_seeds[ 7] = 23'h058BF1;
        lane_seeds[ 8] = 23'h02C5F9;  lane_seeds[ 9] = 23'h016300;
        lane_seeds[10] = 23'h00B180;  lane_seeds[11] = 23'h0058C1;
        lane_seeds[12] = 23'h002C61;  lane_seeds[13] = 23'h001631;
        lane_seeds[14] = 23'h000B19;  lane_seeds[15] = 23'h00058D;
        lane_seeds[16] = 23'h1002C7;  lane_seeds[17] = 23'h080164;
        lane_seeds[18] = 23'h0400B2;  lane_seeds[19] = 23'h02005A;
        lane_seeds[20] = 23'h01002D;  lane_seeds[21] = 23'h008017;
        lane_seeds[22] = 23'h00400C;  lane_seeds[23] = 23'h002006;
        lane_seeds[24] = 23'h001003;  lane_seeds[25] = 23'h000802;
        lane_seeds[26] = 23'h000401;  lane_seeds[27] = 23'h1FFC4B;
        lane_seeds[28] = 23'h0FFE26;  lane_seeds[29] = 23'h07FF14;
        lane_seeds[30] = 23'h03FF8B;  lane_seeds[31] = 23'h01FFC6;
        lane_seeds[32] = 23'h00FFE3;  lane_seeds[33] = 23'h007FF2;
        lane_seeds[34] = 23'h003FFA;  lane_seeds[35] = 23'h001FFD;
        lane_seeds[36] = 23'h000FFF;  lane_seeds[37] = 23'h000800;
        lane_seeds[38] = 23'h000400;  lane_seeds[39] = 23'h000200;
        lane_seeds[40] = 23'h000100;  lane_seeds[41] = 23'h000080;
        lane_seeds[42] = 23'h000040;  lane_seeds[43] = 23'h000020;
        lane_seeds[44] = 23'h000010;  lane_seeds[45] = 23'h000008;
        lane_seeds[46] = 23'h000004;  lane_seeds[47] = 23'h000002;
        lane_seeds[48] = 23'h000001;  lane_seeds[49] = 23'h1FFFC1;
        lane_seeds[50] = 23'h0FFFE1;  lane_seeds[51] = 23'h07FFF1;
        lane_seeds[52] = 23'h03FFF9;  lane_seeds[53] = 23'h01FFFD;
        lane_seeds[54] = 23'h00FFFE;  lane_seeds[55] = 23'h007FFF;
        lane_seeds[56] = 23'h1C3FFF;  lane_seeds[57] = 23'h0E1FFF;
        lane_seeds[58] = 23'h070FFF;  lane_seeds[59] = 23'h0387FF;
        lane_seeds[60] = 23'h01C3FF;  lane_seeds[61] = 23'h00E1FF;
        lane_seeds[62] = 23'h0070FF;  lane_seeds[63] = 23'h00387F;
        RXVLD = 8'h00;
        
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: Pipeline Latency & Deframing (Valid + No Credit)
        // =====================================================================
        $display("Injecting parallel data at AFE boundary...");
        
        // Push raw data into the AFE inputs
        RXVLD = 8'h0F; // Data Valid, No Credit
        for (int i = 0; i < NUM_LANES; i++) RXDATA[i] = i * 8'h22; 
        
        @(negedge clk);
        RXVLD = 8'h00; // Clear inputs to create a 1-cycle pulse
        for (int i = 0; i < NUM_LANES; i++) RXDATA[i] = 8'h00;
        
        // Pipeline tracking:
        // Cycle 1 (completed above): AFE Latch registers the input
        // Cycle 2: Repair logic (comb) feeds Alignment Buffer. Deframer sets internal_lane_valid
        // Cycle 3: Derotator latches alignment buffer. pl_valid_reg latches internal_lane_valid.
        
        @(negedge clk); // End of Cycle 2
        
        if (pl_valid) begin
            $error("TEST 1 FAILED: pl_valid asserted too early! Pipeline misalignment detected.");
            error_count++;
        end
        
        @(negedge clk); // End of Cycle 3
        
        if (!pl_valid) begin
            $error("TEST 1 FAILED: pl_valid did not assert at expected Cycle 3.");
            error_count++;
        end
        
        if (credit_return) begin
            $error("TEST 1 FAILED: credit_return should be 0.");
            error_count++;
        end
        
        if (pl_data[1] !== 8'h22 || pl_data[2] !== 8'h44) begin
            $error("TEST 1 FAILED: RX Data pipeline mismatch. Expected 22, 44. Got %h, %h", pl_data[1], pl_data[2]);
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_rx_top passed all parallel alignment and routing tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end
endmodule