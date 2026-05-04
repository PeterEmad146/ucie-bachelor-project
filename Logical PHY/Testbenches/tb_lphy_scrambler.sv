`timescale 1ns / 1ps

module tb_lphy_scrambler();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    
    // Common Control
    logic enable;
    logic load_seed;
    logic [22:0] seed_in;
    
    // TX Scrambler
    logic [7:0] tx_data_in;
    logic [7:0] tx_data_out;
    
    // RX Descrambler (Identical module)
    logic [7:0] rx_data_out;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT) - Back-to-Back Instantiation
    // -------------------------------------------------------------------------
    lphy_scrambler tx_scrambler (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .load_seed(load_seed),
        .seed_in(seed_in),
        .data_in(tx_data_in),
        .data_out(tx_data_out)
    );

    lphy_scrambler rx_descrambler (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .load_seed(load_seed),
        .seed_in(seed_in),
        .data_in(tx_data_out),     // RX reads the scrambled data from TX!
        .data_out(rx_data_out)
    );

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
        $display("Starting Verification: lphy_scrambler");
        $display("==========================================================");

        // Reset
        rst_n = 0;
        enable = 0;
        load_seed = 0;
        seed_in = 23'h1DBFBC; // Standard UCIe Lane 0 Seed
        tx_data_in = 8'h00;
        
        @(negedge clk);
        rst_n = 1;
        
        // =====================================================================
        // TEST 1: Seed Loading
        // =====================================================================
        load_seed = 1'b1;
        @(negedge clk);
        load_seed = 1'b0;
        
        // =====================================================================
        // TEST 2: Scrambler Bypass (Enable = 0)
        // =====================================================================
        tx_data_in = 8'hAA;
        enable = 1'b0;
        
        // Give comb logic time to propagate through TX and RX
        #1; 
        
        if (tx_data_out !== 8'hAA) begin
            $error("TEST 2 FAILED: Scrambler altered data while enable=0.");
            error_count++;
        end

        // =====================================================================
        // TEST 3: Scramble/Descramble Loopback (100 cycles)
        // =====================================================================
        enable = 1'b1;
        
        for (int i = 0; i < 100; i++) begin
            // Generate a random payload byte
            tx_data_in = $urandom();
            
            // Advance clock to trigger the LFSR shift
            @(negedge clk);
            
            // TX and RX comb logic will instantly XOR the new data against the new key
            #1; 
            
            // The data on the wire should look completely different
            if (tx_data_in === tx_data_out && tx_data_in !== 8'h00) begin
                $display("Warning: Scrambled data matched input by chance (1 in 256 probability).");
            end
            
            // The descrambled data MUST match the original input perfectly
            if (rx_data_out !== tx_data_in) begin
                $error("TEST 3 FAILED (Iter %0d): Loopback mismatch! Sent: %h, Wire: %h, Recv: %h", 
                        i, tx_data_in, tx_data_out, rx_data_out);
                error_count++;
            end
        end

        // =====================================================================
        // TEST 4: Seed Desynchronization Fault Injection
        // =====================================================================
        // If the RX misses a clock cycle and its LFSR gets out of sync with TX, 
        // the data should instantly become corrupted garbage.
        
        // Force RX descrambler to skip an enable cycle
        force rx_descrambler.enable = 1'b0; 
        @(negedge clk);
        release rx_descrambler.enable;
        
        tx_data_in = 8'h55;
        @(negedge clk);
        #1;
        
        if (rx_data_out === tx_data_in) begin
            $error("TEST 4 FAILED: RX recovered data despite being desynchronized!");
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_scrambler passed all loopback and synchronization tests.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule