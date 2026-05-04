`timescale 1ps / 1ps

module lphy_ltssm_phyretrain #(
    // Scaled down 8ms timeout for simulation
    parameter int TIMEOUT_CYCLES = 800000 
)(
    input  logic clk,
    input  logic rst_n,
    input  logic en_phyretrain,       // Asserted when LTSSM is in PHYRETRAIN
    
    // Internal PHY Triggers
    input  logic local_retrain_trigger, 
    input  logic [2:0] local_retrain_enc, // 001b: TXSELFCAL, 010b: SPEEDIDLE, 100b: REPAIR

    // RDI Stallreq/Ack Handshake
    output logic pl_stallreq,
    input  logic lp_stallack,

    // Handshake Status Inputs from Sideband RX
    input  logic rx_retrain_init_req,
    input  logic rx_retrain_init_resp,
    input  logic rx_retrain_start_req,
    input  logic [2:0] rx_retrain_enc,
    input  logic rx_retrain_start_resp,

    // Handshake Triggers to Sideband TX
    output logic tx_retrain_init_req,
    output logic tx_retrain_init_resp,
    output logic tx_retrain_start_req,
    output logic tx_retrain_start_resp,
    output logic [2:0] tx_retrain_enc,

    // State Machine Exits & Control
    output logic rdi_to_retrain,      // Instructs RDI Interface to transition to Retrain
    output logic phy_in_retrain,      // Mandatory PHY_IN_RETRAIN status variable
    
    output logic exit_to_txselfcal,
    output logic exit_to_speedidle,
    output logic exit_to_repair,
    output logic exit_to_trainerror
);

    typedef enum logic [3:0] {
        ST_IDLE            = 4'h0,
        // Local Initiated Flow
        ST_LOC_STALL       = 4'h1,
        ST_LOC_INIT_REQ    = 4'h2,
        ST_LOC_WAIT_RESP   = 4'h3,
        ST_LOC_START_REQ   = 4'h4,
        ST_LOC_WAIT_START  = 4'h5,
        // Remote Initiated Flow
        ST_REM_STALL       = 4'h6,
        ST_REM_INIT_RESP   = 4'h7,
        ST_REM_WAIT_REQ    = 4'h8,
        ST_REM_START_RESP  = 4'h9,
        // Common Exit
        ST_DONE            = 4'hA,
        ST_ERROR           = 4'hB
    } state_t;

    state_t state, next_state;
    logic [31:0] timeout_cnt;
    logic [2:0]  remote_enc_reg;
    logic [2:0]  resolved_enc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            timeout_cnt    <= '0;
            remote_enc_reg <= 3'b001;
        end else begin
            state <= next_state;
            
            if (state != next_state) begin
                timeout_cnt <= '0;
            end else if (state != ST_IDLE && state != ST_DONE && state != ST_ERROR) begin
                if (timeout_cnt < TIMEOUT_CYCLES)
                    timeout_cnt <= timeout_cnt + 1'b1;
            end

            // Capture remote encoding when start req/resp is received
            if (rx_retrain_start_req || rx_retrain_start_resp) begin
                remote_enc_reg <= rx_retrain_enc;
            end
        end
    end

    // Resolution Logic based on UCIe Priority Table 28
    always_comb begin
        logic [2:0] remote_val;
        // Dynamically select the live wire or the registered value
        remote_val = (rx_retrain_start_req || rx_retrain_start_resp) ? rx_retrain_enc : remote_enc_reg;
        
        if (local_retrain_enc == 3'b010 || remote_val == 3'b010) begin
            resolved_enc = 3'b010; // SPEEDIDLE has highest priority
        end else if (local_retrain_enc == 3'b100 || remote_val == 3'b100) begin
            resolved_enc = 3'b100; // REPAIR has next priority
        end else begin
            resolved_enc = 3'b001; // TXSELFCAL is default
        end
    end

    always_comb begin
        next_state            = state;
        pl_stallreq           = 1'b0;
        tx_retrain_init_req   = 1'b0;
        tx_retrain_init_resp  = 1'b0;
        tx_retrain_start_req  = 1'b0;
        tx_retrain_start_resp = 1'b0;
        tx_retrain_enc        = 3'b000;
        rdi_to_retrain        = 1'b0;
        phy_in_retrain        = 1'b0;
        
        exit_to_txselfcal     = 1'b0;
        exit_to_speedidle     = 1'b0;
        exit_to_repair        = 1'b0;
        exit_to_trainerror    = 1'b0;

        if (en_phyretrain) phy_in_retrain = 1'b1; 
        
        // FIXED: RDI Stallreq must be held HIGH during the entire retrain process
        if (state != ST_IDLE) pl_stallreq = 1'b1; 

        case (state)
            ST_IDLE: begin
                pl_stallreq = 1'b0; // Drop stall only in IDLE
                if (en_phyretrain) begin
                    if (local_retrain_trigger) next_state = ST_LOC_STALL;
                    else if (rx_retrain_init_req) next_state = ST_REM_STALL;
                end
            end

            // LOCAL INITIATED FLOW
            ST_LOC_STALL: begin
                if (lp_stallack) next_state = ST_LOC_INIT_REQ;
            end
            ST_LOC_INIT_REQ: begin
                tx_retrain_init_req = 1'b1;
                next_state = ST_LOC_WAIT_RESP;
            end
            ST_LOC_WAIT_RESP: begin
                // FIXED: Crossover Deadlock Resolution
                if (rx_retrain_init_resp || rx_retrain_init_req) begin
                    if (rx_retrain_init_req) tx_retrain_init_resp = 1'b1; // Resolve crossover
                    next_state = ST_LOC_START_REQ;
                end
            end
            ST_LOC_START_REQ: begin
                rdi_to_retrain = 1'b1; 
                tx_retrain_start_req = 1'b1;
                tx_retrain_enc = local_retrain_enc;
                next_state = ST_LOC_WAIT_START;
            end
            ST_LOC_WAIT_START: begin
                rdi_to_retrain = 1'b1;
                // FIXED: Crossover Deadlock Resolution for Start phase
                if (rx_retrain_start_resp || rx_retrain_start_req) begin
                    if (rx_retrain_start_req) begin
                        tx_retrain_start_resp = 1'b1;
                        tx_retrain_enc = resolved_enc;
                    end
                    next_state = ST_DONE;
                end
            end

            // REMOTE INITIATED FLOW
            ST_REM_STALL: begin
                if (lp_stallack) next_state = ST_REM_INIT_RESP;
            end
            ST_REM_INIT_RESP: begin
                tx_retrain_init_resp = 1'b1;
                rdi_to_retrain = 1'b1;
                next_state = ST_REM_WAIT_REQ;
            end
            ST_REM_WAIT_REQ: begin
                rdi_to_retrain = 1'b1;
                if (rx_retrain_start_req) next_state = ST_REM_START_RESP;
            end
            ST_REM_START_RESP: begin
                rdi_to_retrain = 1'b1;
                tx_retrain_start_resp = 1'b1;
                tx_retrain_enc = resolved_enc;
                next_state = ST_DONE;
            end

            // COMMON EXITS
            ST_DONE: begin
                rdi_to_retrain = 1'b1; 
                if (resolved_enc == 3'b010) exit_to_speedidle = 1'b1;
                else if (resolved_enc == 3'b100) exit_to_repair = 1'b1;
                else exit_to_txselfcal = 1'b1;
                
                if (!en_phyretrain) next_state = ST_IDLE;
            end

            ST_ERROR: begin
                exit_to_trainerror = 1'b1;
                if (!en_phyretrain) next_state = ST_IDLE;
            end
        endcase

        if (timeout_cnt == TIMEOUT_CYCLES) begin
            if (state != ST_IDLE && state != ST_DONE && state != ST_ERROR) begin
                next_state = ST_ERROR;
            end
        end
    end
endmodule