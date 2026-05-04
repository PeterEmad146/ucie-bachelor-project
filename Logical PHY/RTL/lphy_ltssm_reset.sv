`timescale 1ps / 1ps

module lphy_ltssm_reset #(
    // Number of clock cycles required to achieve a 4ms hold time. 
    // Example: For a 100 MHz processing clock (10ns period), 4ms = 400,000 cycles.
    parameter int CLK_CYCLES_4MS = 400000
)(
    input  logic clk, 
    input  logic rst_n,
    
    // Status inputs from Analog Front End (AFE) / Clocking logic
    input  logic power_stable, 
    input  logic sb_clk_stable,         // Sideband clock running at 800 MHz
    input  logic mb_clk_stable,         // Mainband clock stable
    input  logic mb_clk_slow,           // Mainband clock set to slowest rate (4 GT/s)
    
    // Control inputs from SoC / Software
    input  logic soc_reset_n,           // 0: SoC forces PHY reset, 1: SoC releases PHY
    input  logic start_link_training,   // Trigger from UCIe Link Control register
    input  logic en_reset,              // High while master LTSSM is in ST_RESET; re-entry clears timer
    
    // State Machine output
    output logic exit_to_sbinit,        // Asserts high when all conditions are met to transition  
    output logic phy_reset_active       // Clamps PHY to electrical quiet state
);

    logic [31:0] timer_4ms;             // 32-bit counter handles massive clock domains safely
    logic        timer_done;
    logic        en_reset_q;            // Previous-cycle en_reset for rising-edge detection
    logic        reset_reentry;         // Pulses high on the cycle the LTSSM re-enters RESET
    assign reset_reentry = en_reset & ~en_reset_q;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer_4ms        <= '0;
            timer_done       <= 1'b0;
            exit_to_sbinit   <= 1'b0;
            phy_reset_active <= 1'b1;   // Active High flag
            en_reset_q       <= 1'b0;
        end else begin
            en_reset_q <= en_reset;

            // On LTSSM re-entry to RESET (rising edge of en_reset), clear the
            // timer so the 4ms wait is re-enforced (required for L2 wakeup).
            if (reset_reentry) begin
                timer_4ms  <= '0;
                timer_done <= 1'b0;
            end

            // If the SoC forces a hard reset, clamp everything immediately
            if (!soc_reset_n) begin
                timer_4ms        <= '0;
                timer_done       <= 1'b0;
                exit_to_sbinit   <= 1'b0;
                phy_reset_active <= 1'b1;
            end
            else begin
                // 1. Enforce the mandatory 4ms hold for PLLs to stabilize
                // ONLY AFTER power and clocks are completely stable
                if (power_stable && sb_clk_stable && mb_clk_stable) begin
                    if (timer_4ms < CLK_CYCLES_4MS) begin
                        timer_4ms  <= timer_4ms + 1'b1;
                        timer_done <= 1'b0;
                    end else begin
                        timer_done <= 1'b1;
                    end
                end else begin
                    // Reset timer if power/clocks glitch or drop
                    timer_4ms  <= '0;
                    timer_done <= 1'b0;
                end

                // 2. Evaluate exit conditions (UCIe Spec Section 8.2.1)
                if (timer_done && mb_clk_slow && start_link_training) begin
                    exit_to_sbinit   <= 1'b1;  // Trigger master LTSSM to move to SBINIT
                    phy_reset_active <= 1'b0;  // Release electrical clamps
                end else begin
                    exit_to_sbinit   <= 1'b0;
                    phy_reset_active <= 1'b1;  // Keep PHY clamped
                end
            end
        end
    end
endmodule