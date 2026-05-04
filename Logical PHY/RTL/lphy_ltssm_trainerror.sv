`timescale 1ps / 1ps

module lphy_ltssm_trainerror #(
    // Scaled down 8ms timeout for simulation
    parameter int TIMEOUT_CYCLES = 800000 
)(
    input  logic clk,
    input  logic rst_n,
    input  logic en_trainerror,       // Triggered by Master LTSSM

    // Handshake Status Inputs from Sideband RX (1-Cycle Pulses)
    input  logic rx_trainerror_req,
    input  logic rx_trainerror_resp,

    // Adapter / RDI Status
    input  logic rdi_in_linkerror,    // 1b if RDI pl_state_sts == LinkError

    // Handshake Triggers to Sideband TX
    output logic tx_trainerror_req,
    output logic tx_trainerror_resp,

    // State Machine Exits & Control
    output logic exit_to_reset
);

    typedef enum logic [2:0] {
        ST_IDLE          = 3'h0,
        ST_SEND_REQ      = 3'h1, // Local initiated error
        ST_WAIT_RESP     = 3'h2,
        ST_SEND_RESP     = 3'h3, // Remote initiated error
        ST_WAIT_RDI      = 3'h4, // Hold if RDI is in LinkError
        ST_DONE          = 3'h5
    } state_t;

    state_t state, next_state;
    logic [31:0] timeout_cnt;
    
    // Latches to catch 1-cycle sideband pulses
    logic rcvd_req;
    logic rcvd_resp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            timeout_cnt <= '0;
            rcvd_req    <= 1'b0;
            rcvd_resp   <= 1'b0;
        end else begin
            state <= next_state;
            
            // 8ms Timeout Counter (Resets on entry to WAIT_RESP)
            if (state == ST_WAIT_RESP) begin
                if (timeout_cnt < TIMEOUT_CYCLES)
                    timeout_cnt <= timeout_cnt + 1'b1;
            end else begin
                timeout_cnt <= '0;
            end
            
            // FIXED: Pulse Latching Logic
            // Clear latches ONLY when transitioning back to IDLE
            if (state != ST_IDLE && next_state == ST_IDLE) begin
                rcvd_req  <= 1'b0;
                rcvd_resp <= 1'b0;
            end else begin
                // Always catch pulses, even while sitting in IDLE!
                if (rx_trainerror_req)  rcvd_req  <= 1'b1;
                if (rx_trainerror_resp) rcvd_resp <= 1'b1;
            end
        end
    end

    always_comb begin
        next_state         = state;
        tx_trainerror_req  = 1'b0;
        tx_trainerror_resp = 1'b0;
        exit_to_reset      = 1'b0;

        case (state)
            ST_IDLE: begin
                if (en_trainerror) begin
                    // FIXED: Evaluate latched requests in case pulse already passed
                    if (rx_trainerror_req || rcvd_req) next_state = ST_SEND_RESP;
                    else next_state = ST_SEND_REQ;
                end
            end

            // -------------------------------------------------------------
            // LOCAL INITIATED FLOW
            // -------------------------------------------------------------
            ST_SEND_REQ: begin
                tx_trainerror_req = 1'b1;
                next_state = ST_WAIT_RESP;
            end
            
            ST_WAIT_RESP: begin
                // Proceed if remote partner responds OR 8ms timeout expires
                if (rx_trainerror_resp || rcvd_resp || (timeout_cnt == TIMEOUT_CYCLES)) begin
                    next_state = ST_WAIT_RDI;
                end 
                // FIXED: Crossover Deadlock Resolution (Bypass 8ms penalty)
                else if (rx_trainerror_req || rcvd_req) begin
                    tx_trainerror_resp = 1'b1;
                    next_state = ST_WAIT_RDI;
                end
            end

            // -------------------------------------------------------------
            // REMOTE INITIATED FLOW
            // -------------------------------------------------------------
            ST_SEND_RESP: begin
                tx_trainerror_resp = 1'b1;
                next_state = ST_WAIT_RDI;
            end

            // -------------------------------------------------------------
            // COMMON EXITS
            // -------------------------------------------------------------
            ST_WAIT_RDI: begin
                // Per Spec: Must hold in TRAINERROR as long as RDI is in LinkError.
                if (!rdi_in_linkerror) begin
                    next_state = ST_DONE;
                end
            end

            ST_DONE: begin
                exit_to_reset = 1'b1;
                if (!en_trainerror) next_state = ST_IDLE;
            end
            
            default: next_state = ST_IDLE;
        endcase
    end
endmodule