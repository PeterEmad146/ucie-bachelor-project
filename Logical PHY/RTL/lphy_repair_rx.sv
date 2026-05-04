`timescale 1ps / 1ps

module lphy_repair_rx (
    // Physical Data from Analog Front End (AFE)
    input logic [7:0] rx_physical_data [63:0], 
    input logic [7:0] rx_redundant_data [3:0],  // Exactly 4 Redundant Pins
    
    // Failure Map from Data Repair Controller / Lane ID Detect
    input logic [63:0] lane_failed, // 1: Physical Lane is broken
    
    // Logical Data to RX Top
    output logic [7:0] rx_logical_data [63:0]
);

    // Group 1: Lower 32 Lanes (0 to 31) using RRD_P and RRD_P[5] 
    logic [1:0] fail_cnt_lower;
    logic [4:0] f0_l, f1_l;
    
    always_comb begin
        fail_cnt_lower = 0;
        f0_l = '0;
        f1_l = '0;
        
        // Count failures and record their physical indices
        for (int i = 0; i < 32; i++) begin
            if (lane_failed[i]) begin
                if (fail_cnt_lower == 0) f0_l = i[4:0];
                else if (fail_cnt_lower == 1) f1_l = i[4:0];
                fail_cnt_lower++;
            end
        end
        
        // Default 1:1 Mapping
        for (int i = 0; i < 32; i++) rx_logical_data[i] = rx_physical_data[i];
        
        if (fail_cnt_lower == 1) begin
            // Single Failure: Reconstruct shift-right mapping
            rx_logical_data[0] = rx_redundant_data[0];    // Lower edge lane
            for (int i = 1; i <= 31; i++) begin
                if ( i <= f0_l)
                    rx_logical_data[i] = rx_physical_data[i-1];
            end
        end
        
        else if (fail_cnt_lower == 2) begin
            // Two Failures: Reconstruct split shift mapping
            rx_logical_data[0] = rx_redundant_data[0];    // lower edge lane
            rx_logical_data[31] = rx_redundant_data[1];  // Upper edge lane
            
            for (int i = 1; i <= 30; i++) begin
                if (i <= f0_l)
                    rx_logical_data[i] = rx_physical_data[i-1];
                else if (i >= f1_l)
                    rx_logical_data[i] = rx_physical_data[i+1];
            end
        end
    end
    
    // Group 2: Upper 32 Lanes (32 to 63) using RRD_P[7] and RRD_P[8]
    logic [1:0] fail_cnt_upper;
    logic [5:0] f0_u, f1_u;
    
    always_comb begin
        fail_cnt_upper = 0;
        f0_u = '0;
        f1_u = '0;
        
        // Count failures and record their physical indices
        for (int i = 32; i < 64; i++) begin
            if (lane_failed[i]) begin
                if (fail_cnt_upper == 0) f0_u = i[5:0];
                else if (fail_cnt_upper == 1) f1_u = i[5:0];
                fail_cnt_upper++;
            end
        end
        
        // Default 1:1 mapping 
        for (int i = 32; i < 64; i++) rx_logical_data[i] = rx_physical_data[i];
        
        if (fail_cnt_upper == 1) begin
            // Single Failure: Reconstruct shift-right mapping
            rx_logical_data[32] = rx_redundant_data[2];  // FIXED: Lower edge of Group 2
            for (int i = 33; i <= 63; i++) begin
                if (i <= f0_u)
                    rx_logical_data[i] = rx_physical_data[i-1];
            end
        end
        else if (fail_cnt_upper == 2) begin
            // Two Failures: Reconstruct split shift mapping
            rx_logical_data[32] = rx_redundant_data[2]; // FIXED: Lower edge of Group 2
            rx_logical_data[63] = rx_redundant_data[3]; // FIXED: Upper edge of Group 2
            
            for (int i = 33; i <= 62; i++) begin
                if (i <= f0_u)
                    rx_logical_data[i] = rx_physical_data[i-1];
                else if ( i >= f1_u)
                    rx_logical_data[i] = rx_physical_data[i+1];
            end 
        end
    end
endmodule