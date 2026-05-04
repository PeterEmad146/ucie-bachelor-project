`timescale 1ps / 1ps

module lphy_clkgate_rx (
    input logic clk, 
    input logic rst_n, 
    
    // Configuration
    input logic free_run_mode,      // 1: Clock never gates, 0: Dynamic clock gating enabled
    
    // Input from Valid Deframer
    input logic valid_in,           // High when data is actively being received
    
    // Gated Clock Output for internal RX logic and Adapter
    output logic gated_clk
);

    logic [3:0] postamble_cnt;
    logic clk_en;
    logic clk_en_latched;
    
    // Postamble Counter (Tracks 8 clock cycles / 16 UI after Valid drops)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            postamble_cnt <= 4'd2;  // Start fully idle
        end else begin
            if (valid_in) begin
                postamble_cnt <= 4'd0;
            end else if (postamble_cnt < 4'd2) begin
                postamble_cnt <= postamble_cnt + 1'b1;
            end
        end
    end

    // Combinatorial Enable
    assign clk_en = valid_in | (postamble_cnt < 4'd2) | free_run_mode;
    
    // Glitch-Free Clock Gating Latch
    always_latch begin
        if (!rst_n) begin
            clk_en_latched <= 1'b0;
        end else if (!clk) begin
            clk_en_latched <= clk_en;
        end
    end

    // Drive the gated clock
    assign gated_clk = clk & clk_en_latched;

endmodule