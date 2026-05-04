`timescale 1ps / 1ps

module lphy_ltssm_mbinit #(
    // Scaled down 8ms timeout for simulation
    parameter int TIMEOUT_CYCLES = 800000
)(
    input logic clk, 
    input logic rst_n, 
    input logic en_mbinit,          // Triggered by exit from SBINIT state
    input logic package_type,       // 0: Advanced, 1: Standard
    
    // Handshake Status Inputs from Sideband / Repair Logic
    input logic param_done,
    input logic cal_done, 
    input logic repairclk_done, 
    input logic repairval_done, 
    input logic reversal_done, 
    input logic repairmb_done, 
    input logic substate_error,     // Triggers immediate exit to TRAINERROR
    
    // Sub-state enables to trigger underlying hardware modules
    output logic en_param, 
    output logic en_cal, 
    output logic en_repairclk, 
    output logic en_repairval, 
    output logic en_reversal, 
    output logic en_repairmb, 
    
    // State Machine Exits
    output logic exit_to_mbtrain, 
    output logic exit_to_trainerror
);

    typedef enum logic [3:0] {
        ST_IDLE       = 4'h0, 
        ST_PARAM      = 4'h1, 
        ST_CAL        = 4'h2, 
        ST_REPAIRCLK  = 4'h3, 
        ST_REPAIRVAL  = 4'h4, 
        ST_REVERSALMB = 4'h5, 
        ST_REPAIRMB   = 4'h6, 
        ST_DONE       = 4'h7, 
        ST_ERROR      = 4'h8
    } state_t;
    
    state_t state, next_state;
    logic [31:0] timeout_cnt;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            timeout_cnt <= '0;
        end else begin
            state <= next_state;
            
            // 8ms Timeout Counter (Accumulates over the ENTIRE MBINIT state)
            if (state == ST_IDLE || state == ST_DONE || state == ST_ERROR) begin
                timeout_cnt <= '0;
            end else begin
                if (timeout_cnt < TIMEOUT_CYCLES)
                    timeout_cnt <= timeout_cnt + 1'b1;
            end
        end
    end
    
    always_comb begin
        next_state = state;
        en_param = 1'b0;
        en_cal = 1'b0;
        en_repairclk = 1'b0;
        en_repairval = 1'b0;
        en_reversal = 1'b0;
        en_repairmb = 1'b0;
        exit_to_mbtrain = 1'b0;
        exit_to_trainerror = 1'b0;
        
        // State Machine execution
        case (state)
            ST_IDLE: begin
                if (en_mbinit) next_state = ST_PARAM;
            end
            
            ST_PARAM: begin
                en_param = 1'b1;
                if(param_done) next_state = ST_CAL;
            end
            
            ST_CAL: begin
                en_cal = 1'b1;
                if(cal_done) begin
                    // ARCHITECTURAL FIX: Standard packages skip clock/valid repair
                    if (package_type == 1'b1) 
                        next_state = ST_REVERSALMB;
                    else 
                        next_state = ST_REPAIRCLK;
                end
            end
            
            ST_REPAIRCLK: begin
                en_repairclk = 1'b1;
                if(repairclk_done) next_state = ST_REPAIRVAL;
            end
            
            ST_REPAIRVAL: begin
                en_repairval = 1'b1;
                if (repairval_done) next_state = ST_REVERSALMB;
            end
            
            ST_REVERSALMB: begin
                en_reversal = 1'b1;
                if (reversal_done) next_state = ST_REPAIRMB;
            end
            
            ST_REPAIRMB: begin
                en_repairmb = 1'b1;
                if(repairmb_done) next_state = ST_DONE;
            end
            
            ST_DONE: begin
                exit_to_mbtrain = 1'b1;
                if (!en_mbinit) next_state = ST_IDLE; // Reset when Master LTSSM moves on
            end
            
            ST_ERROR: begin
                exit_to_trainerror = 1'b1;
                if(!en_mbinit) next_state = ST_IDLE;
            end
            
            default: next_state = ST_IDLE;
        endcase
        
        // Timeout or Substate Error overrides normal transitions
        if ((timeout_cnt == TIMEOUT_CYCLES) || substate_error) begin
            if (state != ST_IDLE && state != ST_DONE && state != ST_ERROR) begin
                next_state = ST_ERROR;
            end
        end
    end
endmodule