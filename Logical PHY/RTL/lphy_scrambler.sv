`timescale 1ns / 1ps

module lphy_scrambler (
    input logic clk,
    input logic rst_n,              // Active-low reset
    input logic enable,             // High when data is valid and needs scrambling
    input logic load_seed,          // Load the initial per-lane seed
    input logic [22:0] seed_in,     // Per-lane seed value
    input logic [7:0] data_in,      // 8-bit payload from datapath
    output logic [7:0] data_out     // Scrambled 8-bit payload
);

    logic [22:0] lfsr_reg;
    logic [22:0] next_lfsr;
    logic [7:0] scramble_key;
    
    // Combinatorial block to advance LFSR by 8 steps and generate an 8-bit key
    always_comb begin
        next_lfsr = lfsr_reg;
        for (int i = 0; i < 8; i++) begin
            // The output bit of the LFSR is the MSB (bit 22)
            scramble_key[i] = next_lfsr[22];
            
            // Advance the LFSR state by 1 step 
            if (next_lfsr[22]) begin
                next_lfsr = (next_lfsr << 1) ^ 23'h210125;
            end else begin
                next_lfsr = (next_lfsr << 1);
            end
        end
    end     
    
    // Sequential block to update the LFSR register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr_reg <= 23'h1DBFBC;     // Default to Lane 0 Seed
        end else if (load_seed) begin
            lfsr_reg <= seed_in;
        end else if (enable) begin
            lfsr_reg <= next_lfsr;
        end
    end
    
    // XOR the input data with the generated 8-bit scramble key
    // If enable is low, we pass the data through unmodified 
    assign data_out = enable ? (data_in ^ scramble_key) : data_in;

endmodule