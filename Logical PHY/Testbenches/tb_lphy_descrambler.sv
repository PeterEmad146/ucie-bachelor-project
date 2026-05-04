`timescale 1ns / 1ps

module tb_lphy_descrambler();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    logic enable; 
    logic load_seed; 
    logic [22:0] seed_in;
    logic [7:0] data_in;
    logic [7:0] data_out;
    
    logic [7:0] generated_key;
    
    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_descrambler dut (.*);
    

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
        $display("Starting Verification: lphy_descrambler");
        $display("==========================================================");

        // Reset
        rst_n = 0;
        enable = 0;
        load_seed = 0;
        seed_in = 23'h1DBFBC; // Lane 0 standard seed
        data_in = 8'h00;
        
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: Bypass Mode (Enable = 0)
        // =====================================================================
        data_in = 8'hA5;
        enable = 1'b0;
        #1; // Comb logic delay
        
        if (data_out !== 8'hA5) begin
            $error("TEST 1 FAILED: Descrambler altered data while enable=0. Got %h", data_out);
            error_count++;
        end

        // =====================================================================
        // TEST 2: Seed Loading & LFSR Step
        // =====================================================================
        load_seed = 1'b1;
        seed_in = 23'h112233;
        @(negedge clk);
        load_seed = 1'b0;
        
        // Turn on descrambler. The comb logic will immediately use the new seed 
        // to generate a key and XOR the data.
        enable = 1'b1;
        data_in = 8'h00; // XORing with 00 exposes the raw generated key
        #1; 
        
        // Let's capture the key that was generated from seed 23'h112233
        generated_key = data_out;
        
        if (generated_key === 8'h00) begin
            $error("TEST 2 FAILED: LFSR did not generate a valid key (output was 00).");
            error_count++;
        end
        
        // =====================================================================
        // TEST 3: State Progression
        // =====================================================================
        @(negedge clk); // Step the clock so the LFSR advances
        #1;
        
        if (data_out === generated_key) begin
            $error("TEST 3 FAILED: LFSR did not advance to the next state! Key remained %h", data_out);
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_descrambler passed all bypass and seed mechanics tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule