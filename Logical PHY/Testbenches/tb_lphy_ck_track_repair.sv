`timescale 1ps / 1ps

module tb_lphy_ck_track_repair;

    // TX Signals
    logic tckp_l, tckn_l, ttrk_l;
    logic tckp_p, tckn_p, ttrk_p, trdck_p;
    
    // RX Signals 
    logic rckp_p, rckn_p, rtrk_p, rrdck_p;
    logic rckp_l, rckn_l, rtrk_l;
    
    // Control
    logic [3:0] tx_repair_addr;
    logic [3:0] rx_repair_addr;
    
    // Instantiate DUT
    lphy_ck_track_repair dut (.*);
    
    initial begin
        $display("Starting Clock & Track Repair Simulation...");
        
        // Setup distinct logical values to trace routing easily
        tckp_l = 1'b1;  // Logical Clock P is High
        tckn_l = 1'b0;  // Logical Clock N is Low
        ttrk_l = 1'b1;  // Logical Track is High
        
        // Test 1: No Repair (4'hF)
        $display("\n--- Test 1: No Repair ---");
        tx_repair_addr = 4'hF;
        rx_repair_addr = 4'hF;
        
        // Feedback TX physical outputs into RX physical inputs to simulate loopback
        #1;
        rckp_p = tckp_p; 
        rckn_p = tckn_p;
        rtrk_p = ttrk_p;
        rrdck_p = trdck_p;
        #1;
        
        if (tckp_p === 1'b1 && tckn_p === 1'b0 && ttrk_p === 1'b1 &&
            rckp_l === 1'b1 && rckn_l === 1'b0 && rtrk_l === 1'b1)
            $display("SUCCESS: 1:1 Mapping works correctly!");
        else 
            $error("FAILED: 1:1 Mapping!");
            
        // Test 2: Repair Clock P (4'h0)
        $display("\n--- Test 2: Repair Clock P (TCKP/RCKP) ---");
        tx_repair_addr = 4'h0;
        rx_repair_addr = 4'h0;
        
        #1;
        rckp_p = 1'b0;
        rckn_p = tckn_p;
        rtrk_p = ttrk_p; 
        rrdck_p = trdck_p;
        #1;
        
        // Expect TCKP_L(1) -> TCKN_P
        // Expect TCKN_L(0) -> TRDCK_P
        if (tckn_p === 1'b1 && trdck_p === 1'b0 && rckp_l === 1'b1 && rckn_l === 1'b0)
            $display("SUCCESS: Clock P successfully shifted and reconstructed!");
        else 
            $error("FAILED: Clock P repair mapping!");
            
        // Test 3: Repair Clock N (4'h1)
        $display("\n--- Test 3: Repair Clock N (TCKN/RCKN) ---");
        tx_repair_addr = 4'h1;
        rx_repair_addr = 4'h1;
        
        #1;
        rckp_p = tckp_p;
        rckn_p = 1'b0;
        rtrk_p = ttrk_p;
        rrdck_p = trdck_p;
        #1;
        
        // Expect TCKP_L(1) -> TCKP_P (Unshifted)
        // Expect TCKN_L(0) -> TRDCK_P
        if (tckp_p === 1'b1 && trdck_p === 1'b0 && rckn_l === 1'b0 && rckp_l === 1'b1)
            $display("SUCCESS: Clock N successfully shifted and reconstructed!");
        else
            $error("FAILED: Clock N repair mapping!");
            
        // Test 4: Repair Track (4'h2)
        $display("\n--- Test 4: Repair Track (TTRK/RTRK) ---");
        tx_repair_addr = 4'h2;
        rx_repair_addr = 4'h2;
        
        #1;
        rckp_p = tckp_p;
        rckn_p = tckn_p;
        rtrk_p = 1'b0;
        rrdck_p = trdck_p;
        #1;
        
        if (trdck_p === 1'b1 && rtrk_l === 1'b1 && tckp_p === 1'b1)
            $display("SUCCESS: Track successfully shifted and reconstructed!");
        else
            $error("FAILED: Track repair mapping!");
            
        $display("\nClock & Track Repair Simulation Complete!");
        $finish;
    end

endmodule