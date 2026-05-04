`timescale 1ns / 1ps

module lphy_sb_crc (
    // TX Sideband Parity Generation
    input logic [63:0] tx_header_in,    // 64-bit Header (Phase 0 and Phase 1)
    input logic [63:0] tx_data_in,      // 64-bit Data Payload (Phase 2 and Phase 3)
    input logic tx_has_data,            // High if the packet type includes a data payload
    
    // Header with Bit 63 (DP) and Bit 62 (CP) correctly populated
    output logic [63:0] tx_header_out,
    
    // RX Sideband Parity Checking
    input logic [63:0] rx_header_in,
    input logic [63:0] rx_data_in,
    input logic rx_has_data,
    
    // Error flags (should be routed to fatal UIE escalation logic)
    output logic rx_cp_err,         // High if Control Parity mismatch
    output logic rx_dp_err          // High if Data Parity mismatch
);

    // TX Logic 
    logic tx_cp_gen;
    logic tx_dp_gen;
    
    // Data Parity is the even parity of all bits in the data payload.
    // If there is not data payload, this bit is set to 0b.
    assign tx_dp_gen = tx_has_data ? ^tx_data_in : 1'b0;
    
    // Control Parity is the even parity of all the header bits excluding DP (and CP itself)
    // Bits [61:0] represent the header excluding CP (Bit 62) and DP (Bit 63).
    assign tx_cp_gen = ^tx_header_in[61:0];
    
    // Assemble the final header for transmission
    assign tx_header_out = {tx_dp_gen, tx_cp_gen, tx_header_in[61:0]};
    
    // RX Logic
    logic rx_cp_calc;
    logic rx_dp_calc;
    
    // Calculate expected parties from incoming data
    assign rx_dp_calc = rx_has_data ? ^rx_data_in : 1'b0;
    assign rx_cp_calc = ^rx_header_in[61:0];
    
    // Check calculated parity against received parity bits
    assign rx_dp_err = (rx_header_in[63] !== rx_dp_calc);
    assign rx_cp_err = (rx_header_in[62] !== rx_cp_calc);
endmodule