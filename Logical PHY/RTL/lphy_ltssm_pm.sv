`timescale 1ps / 1ps

module lphy_ltssm_pm (
    input logic clk, 
    input logic rst_n,
    
    // Entry Triggers from Master LTSSM
    input logic en_l1, 
    input logic en_l2, 
    
    // Adapter Interface (RDI) State Requests & Status
    input  logic [3:0] lp_state_req,        // Looking for 4'b0001 (Active) to initiate wake-up
    output logic [3:0] pl_state_sts,        // Tell Adapter we are successfully asleep
    
    // Handshake Status Inputs from Sideband RX (1-Cycle Pulses)
    input logic rx_req_active,              // Remote Link partner requesting PM exit
    input logic rx_rsp_active,              // Remote Link partner acknowledging our wake-up
    
    // Handshake Triggers to Sideband TX (1-Cycle Pulses)
    output logic tx_req_active, 
    output logic tx_rsp_active, 
    
    // State Machine Exits
    output logic exit_to_speedidle,         // L1 wake-up routes to MBTRAIN.SPEEDIDLE
    output logic exit_to_reset              // L2 wake-up routes to RESET
);

    typedef enum logic [2:0] {
        ST_IDLE     = 3'h0, 
        ST_L1       = 3'h1, 
        ST_L2       = 3'h2,
        ST_WAKE_REQ = 3'h3,  // Waiting for Remote PHY to acknowledge wake-up
        ST_EXITING  = 3'h4   // Holding exit flags high
    } state_t;
    
    state_t state, next_state;
    
    // Track which sleep state we are waking up from
    logic was_in_l2; 
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            was_in_l2 <= 1'b0;
        end else begin
            state <= next_state;
            
            if (state == ST_L2) was_in_l2 <= 1'b1;
            else if (state == ST_IDLE) was_in_l2 <= 1'b0;
        end
    end
    
    always_comb begin
        next_state = state;
        exit_to_speedidle = 1'b0;
        exit_to_reset = 1'b0;
        tx_req_active = 1'b0;
        tx_rsp_active = 1'b0;
        pl_state_sts = 4'b0000;
        
        case (state)
            ST_IDLE: begin
                if (en_l1) next_state = ST_L1;
                else if (en_l2) next_state = ST_L2;
            end
            
            ST_L1: begin
                pl_state_sts = 4'b0100; // Tell Adapter we are in L1
                
                // 1. Remote PHY wakes us up
                if (rx_req_active) begin
                    tx_rsp_active = 1'b1;
                    next_state = ST_EXITING;
                end 
                // 2. Local Adapter wakes us up
                else if (lp_state_req == 4'b0001) begin
                    tx_req_active = 1'b1;
                    next_state = ST_WAKE_REQ;
                end
            end
            
            ST_L2: begin
                pl_state_sts = 4'b1000; // Tell Adapter we are in L2
                
                // 1. Remote PHY wakes us up
                if (rx_req_active) begin
                    tx_rsp_active = 1'b1;
                    next_state = ST_EXITING;
                end 
                // 2. Local Adapter wakes us up
                else if (lp_state_req == 4'b0001) begin
                    tx_req_active = 1'b1;
                    next_state = ST_WAKE_REQ;
                end 
            end
            
            ST_WAKE_REQ: begin
                // Hold the sleep status while waking up
                pl_state_sts = was_in_l2 ? 4'b1000 : 4'b0100;
                
                if (rx_rsp_active) begin
                    next_state = ST_EXITING;
                end
            end
            
            ST_EXITING: begin
                if (was_in_l2) exit_to_reset = 1'b1;
                else exit_to_speedidle = 1'b1;
                
                if (!en_l1 && !en_l2) next_state = ST_IDLE;
            end
        endcase
    end
endmodule