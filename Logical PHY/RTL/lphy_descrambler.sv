`timescale 1ns / 1ps

module lphy_descrambler (
    input logic clk,
    input logic rst_n,
    input logic enable, 
    input logic load_seed, 
    input logic [22:0] seed_in,
    input logic [7:0] data_in,      // Scrambled 8-bit payload
    output logic [7:0] data_out     // Descrambler (Original) 8-bit payload
);

    logic [22:0] lfsr_reg;
    logic [22:0] next_lfsr;
    logic [7:0] descramble_key;
    
    always_comb begin
        next_lfsr = lfsr_reg;
        for (int i =0; i < 8; i++) begin
            descramble_key[i] = next_lfsr[22];
            if (next_lfsr[22]) begin
                next_lfsr = (next_lfsr << 1) ^ 23'h210125;
            end else begin
                next_lfsr = (next_lfsr << 1);
            end
        end
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr_reg <= 23'h1DBFBC;
        end else if (load_seed) begin
            lfsr_reg <= seed_in;
        end else if (enable) begin
            lfsr_reg <= next_lfsr;
        end
    end 
    
    // Descrambling is identically XORing the scrambled dtaa with the same generated key
    assign data_out = enable ? (data_in ^ descramble_key) : data_in;

endmodule