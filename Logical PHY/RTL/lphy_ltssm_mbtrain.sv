`timescale 1ps / 1ps

module lphy_ltssm_mbtrain #(
    // Scaled down 8ms timeout for simulation
    parameter int TIMEOUT_CYCLES = 800000
)(
    input logic clk, 
    input logic rst_n, 
    input logic en_mbtrain,         // Triggered by exit from MBINIT state
    input logic package_type,       // ADDED: 0: Advanced, 1: Standard
    
    // Handshake Status Inputs from Sideband / Calibration logic
    input logic valvref_done, 
    input logic datavref_done, 
    input logic speedidle_done, 
    input logic txselfcal_done, 
    input logic rxclkcal_done, 
    input logic valtraincenter_done, 
    input logic valtrainvref_done, 
    input logic datatraincenter1_done, 
    input logic datatrainvref_done, 
    input logic rxdeskew_done, 
    input logic datatraincenter2_done, 
    
    // LINKSPEED Status
    input logic linkspeed_done, 
    input logic linkspeed_error, 
    input logic needs_repair, 
    input logic needs_speed_degrade, 
    
    input logic repair_done, 
    input logic substate_error,         // Triggers immediate exit to TRAINERROR
    
    // Sub-state enables to trigger underlying hardware modules
    output logic en_valvref, 
    output logic en_datavref, 
    output logic en_speedidle, 
    output logic en_txselfcal, 
    output logic en_rxclkcal, 
    output logic en_valtraincenter, 
    output logic en_valtrainvref, 
    output logic en_datatraincenter1,
    output logic en_datatrainvref, 
    output logic en_rxdeskew, 
    output logic en_datatraincenter2, 
    output logic en_linkspeed, 
    output logic en_repair, 
    
    // State Machine Exits
    output logic exit_to_linkinit, 
    output logic exit_to_trainerror
);

    typedef enum logic [4:0] {
        ST_IDLE             = 5'h00,
        ST_VALVREF          = 5'h01, 
        ST_DATAVREF         = 5'h02, 
        ST_SPEEDIDLE        = 5'h03, 
        ST_TXSELFCAL        = 5'h04,
        ST_RXCLKCAL         = 5'h05, 
        ST_VALTRAINCENTER   = 5'h06, 
        ST_VALTRAINVREF     = 5'h07, 
        ST_DATATRAINCENTER1 = 5'h08, 
        ST_DATATRAINVREF    = 5'h09, 
        ST_RXDESKEW         = 5'h0A, 
        ST_DATATRAINCENTER2 = 5'h0B, 
        ST_LINKSPEED        = 5'h0C, 
        ST_REPAIR           = 5'h0D, 
        ST_DONE             = 5'h0E, 
        ST_ERROR            = 5'h0F
    } state_t;

    state_t state, next_state;
    logic [31:0] timeout_cnt;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            timeout_cnt <= '0;
        end else begin
            state <= next_state;
            
            // FIXED: Global 8ms Timeout Counter
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
        en_valvref = 1'b0;
        en_datavref = 1'b0;
        en_speedidle = 1'b0;
        en_txselfcal = 1'b0;
        en_rxclkcal = 1'b0;
        en_valtraincenter = 1'b0;
        // FIXED: Removed duplicate assignments here
        en_valtrainvref = 1'b0;
        en_datatraincenter1 = 1'b0;
        en_datatrainvref = 1'b0;
        en_rxdeskew = 1'b0;
        en_datatraincenter2 = 1'b0;
        en_linkspeed = 1'b0;
        en_repair = 1'b0;
        exit_to_linkinit = 1'b0;
        exit_to_trainerror = 1'b0;
        
        // State Machine execution
        case (state)
            ST_IDLE: begin
                if(en_mbtrain) begin
                    // ARCHITECTURAL FIX: Standard Package bypasses initial Vref
                    if (package_type == 1'b1) next_state = ST_SPEEDIDLE;
                    else next_state = ST_VALVREF;
                end
            end
                
            ST_VALVREF: begin
                en_valvref = 1'b1;
                if(valvref_done) next_state = ST_DATAVREF;
            end
            
            ST_DATAVREF: begin
                en_datavref = 1'b1;
                if(datavref_done) next_state = ST_SPEEDIDLE;
            end
            
            ST_SPEEDIDLE: begin
                en_speedidle = 1'b1;
                if (speedidle_done) next_state = ST_TXSELFCAL;
            end
            
            ST_TXSELFCAL: begin
                en_txselfcal = 1'b1;
                if (txselfcal_done) next_state = ST_RXCLKCAL;
            end
            
            ST_RXCLKCAL: begin
                en_rxclkcal = 1'b1;
                if (rxclkcal_done) next_state = ST_VALTRAINCENTER;
            end
            
            ST_VALTRAINCENTER: begin
                en_valtraincenter = 1'b1;
                if(valtraincenter_done) begin
                    // ARCHITECTURAL FIX: Bypass internal Vref states
                    if (package_type == 1'b1) next_state = ST_DATATRAINCENTER1;
                    else next_state = ST_VALTRAINVREF;
                end
            end
            
            ST_VALTRAINVREF: begin
                en_valtrainvref = 1'b1;
                if (valtrainvref_done) next_state = ST_DATATRAINCENTER1;
            end
            
            ST_DATATRAINCENTER1: begin
                en_datatraincenter1 = 1'b1;
                if (datatraincenter1_done) begin
                    // ARCHITECTURAL FIX: Bypass internal Vref states
                    if (package_type == 1'b1) next_state = ST_RXDESKEW;
                    else next_state = ST_DATATRAINVREF;
                end
            end
            
            ST_DATATRAINVREF: begin
                en_datatrainvref = 1'b1;
                if(datatrainvref_done) next_state = ST_RXDESKEW;
            end
            
            ST_RXDESKEW: begin
                en_rxdeskew = 1'b1;
                if (rxdeskew_done) next_state = ST_DATATRAINCENTER2;
            end
            
            ST_DATATRAINCENTER2: begin
                en_datatraincenter2 = 1'b1;
                if (datatraincenter2_done) next_state = ST_LINKSPEED;
            end
            
            ST_LINKSPEED: begin
                en_linkspeed = 1'b1;
                if (linkspeed_done) begin
                    next_state = ST_DONE;
                end else if (linkspeed_error) begin
                    if (needs_repair) next_state = ST_REPAIR;
                    else if (needs_speed_degrade) next_state = ST_SPEEDIDLE;
                    else next_state = ST_ERROR;
                end
            end
            
            ST_REPAIR: begin
                en_repair = 1'b1;
                if (repair_done) next_state = ST_TXSELFCAL; // Loop back to selfcal after repair
            end
            
            ST_DONE: begin
                exit_to_linkinit = 1'b1;
                if (!en_mbtrain) next_state = ST_IDLE;
            end
            ST_ERROR: begin
                exit_to_trainerror = 1'b1;
                if (!en_mbtrain) next_state = ST_IDLE;
            end
            
            default: next_state = ST_IDLE;
        endcase

        // Timeout or Substate Error overrides normal transitions
        if ((timeout_cnt == TIMEOUT_CYCLES) || substate_error) begin
            // Include ST_DONE in the protected states just like in MBINIT
            if (state != ST_IDLE && state != ST_ERROR && state != ST_DONE) 
                next_state = ST_ERROR;
        end
    end
endmodule