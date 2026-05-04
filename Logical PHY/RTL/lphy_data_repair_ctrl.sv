`timescale 1ps / 1ps

module lphy_data_repair_ctrl (
    input  logic        clk,
    input  logic        rst_n,
    
    // Configuration
    // 0: Advanced Package (64 Data + 4 Redundant), 1: Standard Package (16 Data)
    input  logic        package_type, 

    // Inputs from Lane ID Detect Module
    input  logic [63:0] lane_failed,
    input  logic        check_done,

    // Outputs for Advanced Package Repair (Payload for Sideband Message)
    // Indices: 0=TRD_P, 1=TRD_P[1], 2=TRD_P[8], 3=TRD_P[9]
    output logic [7:0]  trd_repair_addr [3:0],
    
    // Outputs to Width Degradation Module
    // 2'b11: Full Width (x64/x16), 2'b01: Lower Half, 2'b10: Upper Half, 2'b00: Fail
    output logic [1:0]  lane_map, 

    // Global Status
    output logic        is_unrepairable 
);

    // Internal signals for combinational logic
    logic [7:0] adv_trd_addr [3:0];
    logic [1:0] adv_lane_map;
    logic       adv_unrepairable;
    
    logic [1:0] std_lane_map;
    logic       std_unrepairable;

    // -----------------------------------------------------------------
    // Advanced Package Logic (64 Lanes, 4 Redundant Pins)
    // -----------------------------------------------------------------
    always_comb begin
        int fail_cnt_lower;
        int fail_cnt_upper;
        logic [7:0] f0_l, f1_l;
        logic [7:0] f0_u, f1_u;
        logic lower_fatal;
        logic upper_fatal;

        // Initialize defaults
        fail_cnt_lower = 0;
        fail_cnt_upper = 0;
        f0_l = 8'hFF; f1_l = 8'hFF;
        f0_u = 8'hFF; f1_u = 8'hFF;
        
        for (int i = 0; i < 4; i++) adv_trd_addr[i] = 8'hFF; 

        // Analyze Lower 32 Lanes (0-31)
        for (int i = 0; i < 32; i++) begin
            if (lane_failed[i]) begin
                if (fail_cnt_lower == 0)      f0_l = i[7:0];
                else if (fail_cnt_lower == 1) f1_l = i[7:0];
                fail_cnt_lower++;
            end
        end

        // Analyze Upper 32 Lanes (32-63)
        for (int i = 32; i < 64; i++) begin
            if (lane_failed[i]) begin
                if (fail_cnt_upper == 0)      f0_u = i[7:0];
                else if (fail_cnt_upper == 1) f1_u = i[7:0];
                fail_cnt_upper++;
            end
        end
        
        // Map Redundant Pin Addresses
        if (fail_cnt_lower == 1) begin
            adv_trd_addr[0] = f0_l;
        end else if (fail_cnt_lower == 2) begin
            adv_trd_addr[0] = f0_l;
            adv_trd_addr[1] = f1_l;
        end 
        
        if (fail_cnt_upper == 1) begin
            adv_trd_addr[2] = f0_u; 
        end else if (fail_cnt_upper == 2) begin
            adv_trd_addr[2] = f0_u;
            adv_trd_addr[3] = f1_u; 
        end 
        
        // Width Degradation & Fatal Check
        lower_fatal = (fail_cnt_lower > 2);
        upper_fatal = (fail_cnt_upper > 2);
        
        if (lower_fatal && upper_fatal) begin
            adv_unrepairable = 1'b1;
            adv_lane_map = 2'b00;
        end else if (upper_fatal) begin
            // Upper is dead, degrade to Lower x32
            adv_unrepairable = 1'b0;
            adv_lane_map = 2'b01;
        end else if (lower_fatal) begin
            // Lower is dead, degrade to Upper x32
            adv_unrepairable = 1'b0;
            adv_lane_map = 2'b10;
        end else begin
            // Healthy or Repaired
            adv_unrepairable = 1'b0;
            adv_lane_map = 2'b11;
        end
    end

    // -----------------------------------------------------------------
    // Standard Package Logic (16 Lanes, 0 Redundant Pins)
    // -----------------------------------------------------------------
    always_comb begin
        logic lower_fail;
        logic upper_fail;

        lower_fail = 1'b0;
        upper_fail = 1'b0; 
        std_unrepairable = 1'b0;
        std_lane_map = 2'b11;

        // Check lower 8 (0-7) and upper 8 (8-15)
        lower_fail = |lane_failed[7:0];
        upper_fail = |lane_failed[15:8];

        if (lower_fail && upper_fail) begin
            std_lane_map = 2'b00; 
            std_unrepairable = 1'b1;
        end else if (upper_fail) begin
            std_lane_map = 2'b01; // Use lower x8
        end else if (lower_fail) begin
            std_lane_map = 2'b10; // Use upper x8
        end
    end

    // -----------------------------------------------------------------
    // Sequential Output Routing
    // -----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i=0; i<4; i++) trd_repair_addr[i] <= 8'hFF;
            lane_map        <= 2'b11;
            is_unrepairable <= 1'b0;
        end else if (check_done) begin
            if (package_type == 1'b0) begin
                // Advanced Package Update
                trd_repair_addr <= adv_trd_addr; 
                lane_map        <= adv_lane_map; // FIXED: Allows x32 degradation
                is_unrepairable <= adv_unrepairable;
            end else begin
                // Standard Package Update
                for (int i=0; i<4; i++) trd_repair_addr[i] <= 8'hFF;
                lane_map        <= std_lane_map;
                is_unrepairable <= std_unrepairable;
            end
        end
    end

endmodule