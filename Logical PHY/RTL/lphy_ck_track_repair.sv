`timescale 1ps / 1ps

module lphy_ck_track_repair (
    // Logical Signals (From/To internal PHY Logic)
    input logic tckp_l, 
    input logic tckn_l, 
    input logic ttrk_l,
    
    output logic rckp_l, 
    output logic rckn_l, 
    output logic rtrk_l, 
    
    // Physical Pins (To/From Analog Front End)
    output logic tckp_p,
    output logic tckn_p, 
    output logic ttrk_p, 
    output logic trdck_p,   // Transmit Redundant Clock/Track
    
    input logic rckp_p, 
    input logic rckn_p, 
    input logic rtrk_p, 
    input logic rrdck_p,    // Receive Redundant Clock/Track
    
    // Repair Encodings from Data Repair Controller
    // 4'hF: No Repair, 4'h0: CKP, 4'h1: CKN, 4'h2: TRK
    input logic [3:0] tx_repair_addr, 
    input logic [3:0] rx_repair_addr
);

    // TX Repair Multiplexing [2]
    always_comb begin
        // Default 1:1 Mapping
        tckp_p = tckp_l;
        tckn_p = tckn_l;
        ttrk_p = ttrk_l;
        trdck_p = 1'b0; // Park redundant pin when unused
        
        if (tx_repair_addr == 4'h0) begin
            // TCKP_P Failed: Shift CKP to CKN, and CKN to Redundant
            tckp_p = 1'b0;      // Dead bump
            tckn_p = tckp_l;
            trdck_p = tckn_l;
            ttrk_p = ttrk_l;    // Unshifted
        end
        else if (tx_repair_addr == 4'h1) begin
            // TCKN_P Failed: Shift CKN to Redundant
            tckp_p = tckp_l;    // Unshifted
            tckn_p = 1'b0;      // Dead bump
            trdck_p = tckn_l;   
            ttrk_p = ttrk_l;    // Unshifted
        end
        else if (tx_repair_addr == 4'h2) begin
            // TTRK_P Failed: Shift TRK to Redundant
            tckp_p = tckp_l;    // Unshifted
            tckn_p = tckn_l;    // Unshifted
            ttrk_p = 1'b0;      // Dead bump
            trdck_p = ttrk_l;
        end
    end
    
    // RX Repair Multiplexing [2]
    always_comb begin
        // Default 1:1 Mapping
        rckp_l = rckp_p;
        rckn_l = rckn_p;
        rtrk_l = rtrk_p;
        
        if (rx_repair_addr == 4'h0) begin
            // RCKP_P Failed: Recover CKP from CKN, and CKN from Redundant
            rckp_l = rckn_p;
            rckn_l = rrdck_p;
            rtrk_l = rtrk_p;    // Unshifted
        end
        else if (rx_repair_addr == 4'h1) begin
            // RCKN_P Failed: Recover CKN from Redundant
            rckp_l = rckp_p;    // Unshifted
            rckn_l = rrdck_p;   
            rtrk_l = rtrk_p;
        end
        else if (rx_repair_addr == 4'h2) begin
            // RTRK_P Failed: Recover TRK from Redundant
            rckp_l = rckp_p;    // Unshifted
            rckn_l = rckn_p;    // Unshifted
            rtrk_l = rrdck_p;
        end
    end
endmodule