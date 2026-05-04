`timescale 1ns / 1ps

module lphy_pattern_gen (
    input logic [7:0] lane_id,          // 8-bit Lane ID (from Table 18/19)
    input logic select_valtrain,        // 0 = Per-Lane ID Pattern, 1 = VALTRAIN Pattern
    output logic [15:0] pattern_out     // 16-bit training pattern output
);

    logic [15:0] lane_id_pattern;
    logic [15:0] valtrain_pattern;
    
    // 1. Per-Lane ID Pattern (Table 23 & 24) 
    // Format: 0 1 0 1 | Lane ID (LSB first) | 0 1 0 1
    // Note: In SystemVerilog, bit 0 is the LSB.
    // To transmit '0 1 0 1' LSB-first, bit 0=0, bit 1=1, bit 2=0, bit 3=1 -> 4'b1010
    assign lane_id_pattern[3:0] = 4'b1010;
    assign lane_id_pattern[11:4] = lane_id;
    assign lane_id_pattern[15:12] = 4'b1010;
    
    // 2. VALTRAIN Pattern
    // Format: Four 1's followed by Four 0's.
    // LSB-first: bits 0-3 are 1, bits 4-7 are 0 -> 8'b00001111 (8'h0F)
    // Duplicated across 16 bits -> 16'h0F0F
    assign valtrain_pattern = 16'h0F0F;
    
    // Output Mux 
    assign pattern_out = select_valtrain ? valtrain_pattern : lane_id_pattern;

endmodule