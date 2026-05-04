`timescale 1ps / 1ps

module lphy_lane_derotate #(
    parameter int NUM_LANES = 16 // 16 for Standard Package, 64 for Advanced Package
)(
    input  logic clk,
    input  logic rst_n,

    // Data from RX Valid Deframer / Deserializer
    input  logic [7:0] rx_lane_data_in [NUM_LANES-1:0],
    input  logic       rx_lane_valid,

    // Control Signals from LTSSM (MBINIT.REVERSALMB state)
    input  logic       en_reversal_check,
    output logic       reversal_detected,   // 1: Reversed, 0: Normal
    output logic       reversal_check_done, // Pulses high when 128-iteration check is complete

    // Deskewed and Aligned Data to RX Top
    output logic [7:0] rx_lane_data_out [NUM_LANES-1:0]
);

    // -----------------------------------------------------------------
    // 1. Deskew Buffer Logic
    // -----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_LANES; i++) begin
                rx_lane_data_out[i] <= '0;
            end
        end else if (rx_lane_valid) begin
            for (int i = 0; i < NUM_LANES; i++) begin
                if (reversal_detected)
                    rx_lane_data_out[i] <= rx_lane_data_in[NUM_LANES-1-i];
                else
                    rx_lane_data_out[i] <= rx_lane_data_in[i];
            end
        end
    end

    // -----------------------------------------------------------------
    // 2. Elaboration-Time Expected Pattern Generation
    // -----------------------------------------------------------------
    // Using generate blocks evaluates these constants before simulation runs!
    logic [7:0] exp_norm_b0 [NUM_LANES-1:0];
    logic [7:0] exp_norm_b1 [NUM_LANES-1:0];
    logic [7:0] exp_rev_b0  [NUM_LANES-1:0];
    logic [7:0] exp_rev_b1  [NUM_LANES-1:0];

    generate
        for (genvar i = 0; i < NUM_LANES; i++) begin : gen_exp_patterns
            wire [7:0] norm_id = i[7:0];
            wire [7:0] rev_id  = (NUM_LANES - 1 - i);

            // Pattern: 0 1 0 1 Lane ID (LSB first) 0 1 0 1
            assign exp_norm_b0[i] = {norm_id[3:0], 4'b1010};
            assign exp_norm_b1[i] = {4'b1010, norm_id[7:4]};
            
            assign exp_rev_b0[i]  = {rev_id[3:0], 4'b1010};
            assign exp_rev_b1[i]  = {4'b1010, rev_id[7:4]};
        end
    endgenerate

    // -----------------------------------------------------------------
    // 3. Per-Lane ID Reversal Detection (MBINIT.REVERSALMB)
    // -----------------------------------------------------------------
    logic [7:0] prev_byte [NUM_LANES-1:0];
    logic [7:0] cycle_cnt;
    logic [6:0] normal_hits   [NUM_LANES-1:0];
    logic [6:0] reversed_hits [NUM_LANES-1:0];
    
    // Combinatorial Majority Vote Tally
    logic [7:0] total_normal;
    logic [7:0] total_reversed;
    
    always_comb begin
        total_normal = '0;
        total_reversed = '0;
        for (int i = 0; i < NUM_LANES; i++) begin
            if (normal_hits[i] >= 16)   total_normal = total_normal + 1'b1;
            if (reversed_hits[i] >= 16) total_reversed = total_reversed + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_LANES; i++) begin
                prev_byte[i]     <= '0;
                normal_hits[i]   <= '0;
                reversed_hits[i] <= '0;
            end
            cycle_cnt           <= '0;
            reversal_detected   <= 1'b0;
            reversal_check_done <= 1'b0;
        end else begin
            reversal_check_done <= 1'b0; // Default

            if (en_reversal_check && rx_lane_valid) begin
                cycle_cnt <= cycle_cnt + 1'b1;

                for (int i = 0; i < NUM_LANES; i++) begin
                    prev_byte[i] <= rx_lane_data_in[i];

                    // Check for Normal ID
                    if (prev_byte[i] == exp_norm_b0[i] && rx_lane_data_in[i] == exp_norm_b1[i]) begin
                        if (normal_hits[i] < 127) normal_hits[i] <= normal_hits[i] + 1'b1;
                    end

                    // Check for Reversed ID
                    if (prev_byte[i] == exp_rev_b0[i] && rx_lane_data_in[i] == exp_rev_b1[i]) begin
                        if (reversed_hits[i] < 127) reversed_hits[i] <= reversed_hits[i] + 1'b1;
                    end
                end

                // Evaluate results after 128 iterations (256 clock cycles)
                if (cycle_cnt == 8'hFF) begin
                    if (total_reversed > total_normal) begin
                        reversal_detected <= 1'b1;
                    end else begin
                        reversal_detected <= 1'b0;
                    end
                    reversal_check_done <= 1'b1;
                end
            end else if (!en_reversal_check) begin
                cycle_cnt <= '0;
                for (int i = 0; i < NUM_LANES; i++) begin
                    normal_hits[i]   <= '0;
                    reversed_hits[i] <= '0;
                end
            end
        end
    end
endmodule