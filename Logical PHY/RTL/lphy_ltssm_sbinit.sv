`timescale 1ps / 1ps

module lphy_ltssm_sbinit #(
    // Scaled down 8ms timeout for simulation
    parameter int TIMEOUT_CYCLES = 800000
)(
    input logic clk, 
    input logic rst_n, 
    input logic en_sbinit,              // Triggered by exit from RESET state
    input logic package_type,           // 0: Advanced, 1: Standard
    
    // Status inputs from sideband RX Logic
    // Result mapping (Advanced): [3]: CKSBRD/DATASBRD, [2]: CKSB/DATASBRD, [1]: CKSBRD/DATASB, [0] : CKSB/DATASB
    input logic [3:0] rx_pattern_detected, 
    input logic rx_msg_out_of_reset, 
    input logic rx_msg_done_req,        // ADDED: Needed to prevent deadlock
    input logic rx_msg_done_resp, 
    
    // Control Outputs to Sideband TX/RX Logic
    output logic tx_send_pattern,       // 1: Send 64UI clock + 32UI low
    output logic tx_msg_out_of_reset,   // 1: Send {SBINIT Out of Reset}
    output logic tx_msg_done_req,       // 1: Send {SBINIT done req}
    output logic tx_msg_done_resp,      // ADDED: Needed to satisfy remote PHY
    output logic [2:0] sb_repair_sel,   // 0: No Repair, 1-3: Mux routing for Advanced Package
    
    // State Machine Stats
    output logic exit_to_mbinit, 
    output logic exit_to_trainerror        
);

    typedef enum logic [2:0] {
        ST_IDLE = 3'b000, 
        ST_SEND_PATTERN = 3'b001, 
        ST_WAIT_4_ITER = 3'b010, 
        ST_OUT_OF_RESET = 3'b011, 
        ST_DONE_REQ = 3'b100, 
        ST_DONE = 3'b101, 
        ST_ERROR = 3'b110
    } state_t;

    state_t state, next_state;
    logic [31:0] timeout_cnt;
    logic [5:0] wait_cnt;           // Expanded to 6 bits to count up to 48
    logic [3:0] latched_rx_pattern;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            timeout_cnt <= '0;
            wait_cnt <= '0;
            latched_rx_pattern <= '0;
        end else begin
            state <= next_state;
            
            // 8ms Timeout Counter (Active during SBINIT)
            if (state != ST_IDLE && state != ST_DONE && state != ST_ERROR) begin
                if (timeout_cnt < TIMEOUT_CYCLES)
                    timeout_cnt <= timeout_cnt + 1'b1;
            end else begin
                timeout_cnt <= '0;
            end
            
            if (state == ST_SEND_PATTERN && rx_pattern_detected != 4'b0000) begin
                latched_rx_pattern <= rx_pattern_detected;
            end
            
            if (state == ST_WAIT_4_ITER) begin
                wait_cnt <= wait_cnt + 1'b1;
            end else begin
                wait_cnt <= '0;
            end
        end
    end

    always_comb begin
        next_state = state;
        tx_send_pattern = 1'b0;
        tx_msg_out_of_reset = 1'b0;
        tx_msg_done_req = 1'b0;
        tx_msg_done_resp = 1'b0; // FIXED
        exit_to_mbinit = 1'b0;
        exit_to_trainerror = 1'b0;
        sb_repair_sel = 3'b000;
        
        // Resolve Sideband Repair Routing for Advanced Packages
        if (package_type == 1'b0) begin
            if (latched_rx_pattern[0]) sb_repair_sel = 3'b000;      // DATASB / CKSB
            else if (latched_rx_pattern[1]) sb_repair_sel = 3'b001; // DATASB / CKSBRD
            else if (latched_rx_pattern[2]) sb_repair_sel = 3'b010; // DATASBRD / CKSB
            else if (latched_rx_pattern[3]) sb_repair_sel = 3'b011; // DATASBRD / CKSBRD
        end 
        
        // Timeout condition causes immediate exit to TRAINERROR
        if (timeout_cnt == TIMEOUT_CYCLES && state != ST_IDLE) begin
            next_state = ST_ERROR;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (en_sbinit) next_state = ST_SEND_PATTERN;
                end
                
                ST_SEND_PATTERN: begin
                    tx_send_pattern = 1'b1;
                    if(rx_pattern_detected != 4'b0000) begin
                        next_state = ST_WAIT_4_ITER;
                    end
                end
                
                ST_WAIT_4_ITER: begin
                    tx_send_pattern = 1'b1;
                    // Wait 48 byte-clock cycles (4 iterations of 96 UI).
                    // wait_cnt counts 0..47 = 48 cycles total.
                    if (wait_cnt == 6'd47) begin
                        next_state = ST_OUT_OF_RESET;
                    end
                end
                
                ST_OUT_OF_RESET: begin
                    tx_msg_out_of_reset = 1'b1;
                    if(rx_msg_out_of_reset) begin
                        next_state = ST_DONE_REQ;
                    end 
                end
                
                ST_DONE_REQ: begin
                    tx_msg_done_req = 1'b1;
                    // FIXED: Transition on EITHER a Request (Tie) or a Response
                    if(rx_msg_done_req || rx_msg_done_resp) begin
                        next_state = ST_DONE;
                    end 
                end
                
                ST_DONE: begin
                    tx_msg_done_resp = 1'b1; // FIXED: Output RESP to unblock remote PHY
                    exit_to_mbinit = 1'b1;
                    if(!en_sbinit) next_state = ST_IDLE;    // Reset when LTSSM leaves
                end
                
                ST_ERROR: begin
                    exit_to_trainerror = 1'b1;
                    if(!en_sbinit) next_state = ST_IDLE;
                end
            endcase
        end
    end
endmodule