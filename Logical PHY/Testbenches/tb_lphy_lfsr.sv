`timescale 1ns / 1ps

module tb_lphy_lfsr;

    // Testbench signals
    logic clk;
    logic rst_n;
    logic enable;
    logic load_seed;
    logic [22:0] seed_in;
    logic [22:0] lfsr_out;
    
    // Instantiate the LFSR
    lphy_lfsr dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .load_seed(load_seed),
        .seed_in(seed_in),
        .lfsr_out(lfsr_out)
    );
    
    // Clock generation (1 GHz = 1ns period)
    initial begin
        clk = 0;
        forever #0.5 clk = ~clk;
    end
    
    // Test sequence
    initial begin
        // Initialize signals
        rst_n = 0;
        enable = 0;
        load_seed = 0;
        seed_in = 23'h0;
        
        // Apply Reset
        #2;
        rst_n = 1;
        
        // 1. Load Lane 0 Seed (Table 20)
        #1; 
        load_seed = 1;
        seed_in = 23'h1DBFBC;
        #1;
        load_seed = 0;
        
        // Verify loaded seed
        if (lfsr_out != 23'h1DBFBC) $error("Seed load failed!");
        
        // 2. Enable LFSR and observe sequence
        #1;
        enable = 1;
        
        // Run for 20 clock cycles
        #20;
        enable = 0;
        
        // 3. Load Lane 1 Seed (Table 20)
        #2;
        load_seed = 1;
        seed_in = 23'h0607BB;
        #1;
        load_seed = 0;
        enable = 1;
        
        // Run for 10 clock cycles
        #10;
        enable = 0;
        
        $display("LFSR simulation completed successfully.");
        $finish;
    end
    
        // 1. Golden Reference Function (Defines the math)
        function logic [22:0] get_expected_lfsr(logic [22:0] current_state);
            logic msb;
            msb = current_state[22]; // Corrected tap!
            
            get_expected_lfsr = (current_state << 1); 
            
            if (msb) begin
                get_expected_lfsr = get_expected_lfsr ^ 23'h210125;
            end
        endfunction
    
        // 2. Expected Value Tracker
        logic [22:0] expected_val;
    
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                expected_val <= 23'h1DBFBC; // Default Lane 0 seed
            end else if (load_seed) begin
                expected_val <= seed_in;
            end else if (enable) begin
                expected_val <= get_expected_lfsr(expected_val);
            end
        end
    
        // 3. The Checker (Evaluates on negedge to avoid race conditions)
        always_ff @(negedge clk) begin
            // Only check when out of reset and not actively loading a new seed
            if (rst_n && !load_seed) begin 
                if (lfsr_out !== expected_val) begin
                    $error("Time=%0t | MISMATCH! Expected: %h, RTL Got: %h", $time, expected_val, lfsr_out);
                    // Optional: $stop; // Halts the simulation on the first error
                end
            end
        end
    
    // Monitor changes
    initial begin
        $monitor("Time=%0t | rst_n=%b | load=%b | en=%b | seed_in=%h | lfsr_out=%h",
                 $time, rst_n, load_seed, enable, seed_in, lfsr_out);
    end
    
endmodule