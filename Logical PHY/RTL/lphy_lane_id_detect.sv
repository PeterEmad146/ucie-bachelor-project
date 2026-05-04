`timescale 1ps / 1ps

module lphy_lane_id_detect #(
    // 64 for Advanced Package, 16 for Standard Package
    parameter int NUM_LANES = 64
)(
    input logic clk,
    input logic rst_n, 
    
    // Data from RX Valid Deframer / Deserializer
    input logic [7:0] rx_lane_data_in [NUM_LANES - 1:0], 
    input logic rx_lane_valid, 
    
    // Control Signals from LTSSM (MBINIT.REPAIRMB)
    input logic en_lane_check, 
    input logic is_reversed,    // 1 if LTSSM determined lanes are reversed
    
    // Outputs to Data Repair Controller
    output logic [NUM_LANES - 1:0] lane_failed,     // 1: Lane failed (needs repair), 0: Lane passed
    output logic check_done
);

    // 1. Elaboration-Time Expected Pattern Generation
    logic [7:0] exp_norm_b0 [NUM_LANES - 1:0];
    logic [7:0] exp_norm_b1 [NUM_LANES - 1:0];
    logic [7:0] exp_rev_b0 [NUM_LANES - 1:0];
    logic [7:0] exp_rev_b1 [NUM_LANES - 1:0];
    
    generate 
        for (genvar i = 0; i < NUM_LANES; i++) begin: gen_exp_patterns
            wire [7:0] norm_id = i[7:0];
            wire [7:0] rev_id = (NUM_LANES - 1 - i);
            
            // Pattern: 0 1 0 1 Lane ID (LSB First) 0 1 0 1
            // Sent over 2 bytes:
            assign exp_norm_b0[i] = {norm_id[3:0], 4'b1010};
            assign exp_norm_b1[i] = {4'b1010, norm_id[7:4]};
            
            assign exp_rev_b0[i] = {rev_id[3:0], 4'b1010};
            assign exp_rev_b1[i] = {4'b1010, rev_id[7:4]};
        end
    endgenerate
    
    // 2. Detection & Consecutive Hit Logic
    logic [7:0] prev_byte [NUM_LANES-1:0];
    logic [7:0] cycle_cnt;
    
    // Counters to track the mandatory 16 consecutive hits
    logic [4:0] consec_hits [NUM_LANES-1:0]; 
    logic       lane_passed [NUM_LANES-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_byte   <= '{default: '0};
            consec_hits <= '{default: '0};
            lane_passed <= '{default: '0};
            lane_failed <= '0;
            cycle_cnt  <= '0;
            check_done <= 1'b0;
        end else begin
            check_done <= 1'b0; // Default to 0

            if (en_lane_check && rx_lane_valid) begin
                cycle_cnt <= cycle_cnt + 1'b1;

                for (int i = 0; i < NUM_LANES; i++) begin
                    prev_byte[i] <= rx_lane_data_in[i];

                    // THE ACTUAL FIX: Evaluate on every odd cycle by checking the LSB
                    if (cycle_cnt[0] == 1'b1) begin
                        logic match;
                        if (is_reversed) begin
                            match = (prev_byte[i] == exp_rev_b0[i] && rx_lane_data_in[i] == exp_rev_b1[i]);
                        end else begin
                            match = (prev_byte[i] == exp_norm_b0[i] && rx_lane_data_in[i] == exp_norm_b1[i]);
                        end

                        if (match) begin
                            // Increment consecutive hits, capping at 16
                            if (consec_hits[i] < 5'd16) begin
                                consec_hits[i] <= consec_hits[i] + 1'b1;
                            end
                            // If we hit the 16th consecutive match, flag the lane as passed
                            if (consec_hits[i] == 5'd15) begin 
                                lane_passed[i] <= 1'b1;
                            end
                        end else begin
                            // A single bit error resets the consecutive counter
                            consec_hits[i] <= '0; 
                        end
                    end
                end

                // Evaluate results after 128 iterations (256 clock cycles)
                if (cycle_cnt == 8'hFF) begin
                    for (int i = 0; i < NUM_LANES; i++) begin
                        // If a lane didn't achieve 16 consecutive hits, mark it as failed
                        lane_failed[i] <= ~lane_passed[i];
                    end
                    check_done <= 1'b1;
                end
            end else if (!en_lane_check) begin
                // Clear state when not testing
                cycle_cnt <= '0;
                check_done <= 1'b0;
                for (int i = 0; i < NUM_LANES; i++) begin
                    consec_hits[i] <= '0;
                    lane_passed[i] <= 1'b0;
                    lane_failed[i] <= 1'b0;
                end
            end
        end
    end
endmodule