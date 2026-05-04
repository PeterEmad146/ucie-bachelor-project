`timescale 1ns / 1ps

module lphy_lfsr (
    input logic clk,
    input logic         rst_n,          // Active-low asynchronous reset
    input logic         enable,         // Advance LFSR when high
    input logic         load_seed,      // Load the inital seed value
    input logic [22:0]  seed_in,        // Per-lane seed value (Table 20)
    
    output logic [22:0] lfsr_out        // 23-bit LFSR parallel output
);  

    logic [22:0] lfsr_reg;
    logic [22:0] next_lfsr;
    
    // UCIe / PCIe LFSR Polynomial: G(X) = X^23 + X^21 + X^16 + X^8 + X^5 + X^2 + 1
    // Implemented as a Galois LFSR for high-speed operation.
    // The feedback bit is the MSB (bit 22).
    always_comb begin
        
        if (lfsr_reg[22]) begin
            // Shift left by 1 and XOR with the polynomial mask
            // Mask bits: 21, 16, 8, 5, 2, 0
            // 23'b00000000000000000000000 = 0
            // Bit positions:  21    16      8    5  2  0
            // Binary: 010 0001 0000 0001 0010 0101 -> 23'h210125
            next_lfsr = (lfsr_reg << 1) ^ 23'h210125;
        end else begin
            next_lfsr = (lfsr_reg << 1);
        end
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr_reg <= 23'h1DBFBC;     // Default to Lane 0 Seed
        end else if (load_seed) begin
            lfsr_reg <= seed_in;
        end else if (enable) begin
            lfsr_reg <= next_lfsr;
        end
    end
    
    assign lfsr_out = lfsr_reg;

endmodule