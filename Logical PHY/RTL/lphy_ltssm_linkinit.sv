`timescale 1ps / 1ps

module lphy_ltssm_linkinit #(
    // Scaled down 8ms timeout for simulation
    parameter int TIMEOUT_CYCLES = 800000
)(
    input logic clk, 
    input logic rst_n, 
    input logic en_linkinit,        // Triggered by exit from MBTRAIN state
    
    // Adapter Interface (RDI)
    input logic [3:0] lp_state_req, // Looking for 4'b0001 (Active)
    
    // Handshake Status Inputs from Sideband RX (1-Cycle Pulses)
    input logic rx_req_active,      // Received {LinkMgmt.RDI.Req.Active}
    input logic rx_rsp_active,      // Received {LinkMgmt.RDI.Rsp.Active}
    
    // Handshake Triggers to Sideband TX (1-Cycle Pulses)
    output logic tx_req_active,     // Send {LinkMgmt.RDI.Req.Active}
    output logic tx_rsp_active,     // Send {LinkMgmt.RDI.Rsp.Active}
    
    // State Machine Exits & Control
    output logic lfsr_reset,        // Mandatory LFSR reset upon entry
    output logic clear_start_training,  // Clear "Start UCIe Link Training" bit
    output logic exit_to_active, 
    output logic exit_to_trainerror
);

    typedef enum logic [2:0] {
        ST_IDLE         = 3'h0, 
        ST_WAIT_ADAPTER = 3'h1, 
        ST_HANDSHAKE    = 3'h2, 
        ST_DONE         = 3'h3, 
        ST_ERROR        = 3'h4
    } state_t;

    state_t state, next_state;
    logic [31:0] timeout_cnt;
    
    // Tracking flags for the Active Entry Handshake
    logic sent_req_active;
    logic sent_rsp_active;
    logic rcvd_req_active;  // FIXED: Added to catch early remote requests
    logic rcvd_rsp_active;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            timeout_cnt <= '0;
            sent_req_active <= 1'b0;
            sent_rsp_active <= 1'b0;
            rcvd_req_active <= 1'b0;
            rcvd_rsp_active <= 1'b0;
        end else begin
            state <= next_state;
            
            // 8ms Timeout Counter
            if (state != ST_IDLE && state != ST_DONE && state != ST_ERROR) begin
                if (timeout_cnt < TIMEOUT_CYCLES)
                    timeout_cnt <= timeout_cnt + 1'b1;
            end else begin
                timeout_cnt <= '0;
            end
            
            // FIXED: Track sideband message status GLOBALLY while in LinkInit
            if (state == ST_IDLE) begin
                sent_req_active <= 1'b0;
                sent_rsp_active <= 1'b0;
                rcvd_req_active <= 1'b0;
                rcvd_rsp_active <= 1'b0;
            end else begin
                // Latch incoming pulses instantly, regardless of sub-state
                if (rx_req_active) rcvd_req_active <= 1'b1;
                if (rx_rsp_active) rcvd_rsp_active <= 1'b1;
                
                // Latch our own outgoing pulses
                if (tx_req_active) sent_req_active <= 1'b1;
                if (tx_rsp_active) sent_rsp_active <= 1'b1;
            end
        end
    end
    
    always_comb begin
        next_state = state;
        tx_req_active = 1'b0;
        tx_rsp_active = 1'b0;
        lfsr_reset = 1'b0;
        clear_start_training = 1'b0;
        exit_to_active = 1'b0;
        exit_to_trainerror = 1'b0;
        
        // State Machine execution
        case (state)
            ST_IDLE: begin
                if (en_linkinit) begin
                    lfsr_reset = 1'b1;  // Mandatory LFSR reset upon entry
                    next_state = ST_WAIT_ADAPTER;
                end
            end
            
            ST_WAIT_ADAPTER: begin
                // Wait for Adapter to request ACTIVE state (0001b)
                if (lp_state_req == 4'b0001) begin
                    next_state = ST_HANDSHAKE;
                end
            end
            
            ST_HANDSHAKE: begin
                // 1. Send Active Request to remote partner
                if (!sent_req_active) tx_req_active = 1'b1;
                
                // 2. Respond with Active Response if remote partner's request was received
                // FIXED: Uses the globally latched flag instead of the raw input pin
                if (rcvd_req_active && !sent_rsp_active) tx_rsp_active = 1'b1;
                
                // 3. Move to DONE once all handshake criteria are met
                if (sent_req_active && sent_rsp_active && rcvd_rsp_active) begin
                    next_state = ST_DONE;
                end
            end
            
            ST_DONE: begin
                exit_to_active = 1'b1;
                clear_start_training = 1'b1;
                if (!en_linkinit) next_state = ST_IDLE;
            end
            
            ST_ERROR: begin
                exit_to_trainerror = 1'b1;
                if (!en_linkinit) next_state = ST_IDLE;
            end
            
            default: next_state = ST_IDLE;
        endcase

        // Sub-state timeout causes immediate exit to TRAINERROR
        if (timeout_cnt == TIMEOUT_CYCLES) begin
            // Include ST_DONE and ST_ERROR in protected states
            if (state != ST_IDLE && state != ST_DONE && state != ST_ERROR) begin
                next_state = ST_ERROR;
            end
        end
    end
endmodule