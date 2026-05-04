`timescale 1ps / 1ps

module lphy_valid_repair (
    // Logical Signals (From/To internal PHY Logic, 8-bit Parallel)
    input  logic [7:0] tvld_l, 
    input  logic [7:0] trdvld_l,
    
    output logic [7:0] rvld_l, 
    output logic [7:0] rrdvld_l, 
    
    // Physical Pins (To/From Analog Front End Boundary, 8-bit Parallel)
    output logic [7:0] tvld_p, 
    output logic [7:0] trdvld_p,  // Transmit Redundant Valid
    
    input  logic [7:0] rvld_p, 
    input  logic [7:0] rrdvld_p,  // Receive Redundant Valid
    
    // Repair Encodings from Data Repair Controller
    // 2'h3: No Repair, 2'h0: TVLD_P Repaired
    input  logic [1:0] tx_repair_addr, 
    input  logic [1:0] rx_repair_addr
);

    // -----------------------------------------------------------------
    // TX Valid Repair Multiplexing (Byte-Rate)
    // -----------------------------------------------------------------
    always_comb begin
        // Default 1:1 Mapping
        tvld_p   = tvld_l;
        trdvld_p = trdvld_l;
        
        if (tx_repair_addr == 2'h0) begin
            // TVLD_P Failed: Route TVLD_L byte onto the Redundant Valid pin
            tvld_p   = 8'h00;     // Dead bump (Park at 0)
            trdvld_p = tvld_l;
        end
    end
    
    // -----------------------------------------------------------------
    // RX Valid Repair Multiplexing (Byte-Rate)
    // -----------------------------------------------------------------
    always_comb begin
        // Default 1:1 Mapping
        rvld_l   = rvld_p;
        rrdvld_l = rrdvld_p;
        
        if (rx_repair_addr == 2'h0) begin
            // RVLD_P Failed: Recover RVLD_L byte from the Redundant Valid pin
            rvld_l   = rrdvld_p;
            rrdvld_l = 8'h00;     // Redundant pin is consumed
        end
    end
    
endmodule