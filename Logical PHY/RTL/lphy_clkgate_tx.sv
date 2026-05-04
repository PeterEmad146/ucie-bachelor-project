`timescale 1ps / 1ps

module lphy_clkgate_tx (
    input logic clk,
    input logic rst_n,
    
    // Configuration from Adapter / Link Training
    input logic free_run_mode,      // 1. Clock never gates, 0: Dynamic clock gating enabled
    
    // Input from Valid Framer
    input logic valid_in,           // High when data is actively being transmitted
    
    // Output to Physical Lanes
    output logic gated_clk
);

    logic [3:0] postamble_cnt;
    logic clk_en;
    logic clk_en_latched;
    
    // Postamble Counter (Tracks 8 clock cycles / 16 UI after Valid drops)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            postamble_cnt <= 4'd2;  // Start fully idle so we don't generate false postamble
        end else begin
            if (valid_in) begin
                // While data is valid, keep resetting the counter
                postamble_cnt <= 4'd0;
            end else if (postamble_cnt < 4'd2) begin
                // Valid dropped, count 2 byte-cycles for the mandatory 16-UI postamble 
                postamble_cnt <= postamble_cnt + 1'b1;
            end
        end
    end
    
    // Combinatorial Enable
    // Ungates immediately when valid_in is high, or while the postamble is counting
    assign clk_en = valid_in | (postamble_cnt < 4'd2) | free_run_mode;
    
    // Glitch-Free Clock Gating Latch (Standard ICG)
    // Using a level-sensitive latch on the low phase of the clock prevents 
    // delta-cycle simulation races and avoids swallowing the first clock edge.
    always_latch begin
        if (!rst_n) begin
            clk_en_latched <= 1'b0;
        end else if (!clk) begin
            clk_en_latched <= clk_en;
        end
    end
    
    
    // Drive the physical clock pin
    assign gated_clk = clk & clk_en_latched;
    
endmodule