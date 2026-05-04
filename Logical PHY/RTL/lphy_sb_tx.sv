`timescale 1ns / 1ps

module lphy_sb_tx (
    input logic clk,        // 800 MHz clock (1.25ns period)
    input logic rst_n,
    
    // Interface from Sideband Packet Encoder
    input logic pkt_valid,
    input logic [63:0] pkt_header,
    input logic [63:0] pkt_data,
    input logic pkt_has_data, 
    output logic tx_req_ready,  // High when ready to accept a new packet
    
    // Physica Sideband Pins to Remote Die
    output logic TXDATASB,     // 1-bit serial sideband data   -> analog driver -> bump
    output logic TXCKSB        // Gated 800 MHz stroble        -> analog driver -> bump    
);

    typedef enum logic [2:0] {
        IDLE,
        TX_HEADER,
        TX_DATA
    } state_t;
    
    state_t state, next_state;
    
    logic [6:0] bit_cnt;        // Counts up to 64
    
    logic [63:0] shift_reg;
    logic latch_data;
    logic shift_en;
    logic has_data_reg;

    logic clk_en;           // Glitch-free clock gate
    logic clk_en_latched;   // Latch Output (stable during clk high phase)
    
    always_ff @(negedge clk or negedge rst_n) begin
        if (!rst_n) 
            clk_en_latched <= 1'b0;
        else
            clk_en_latched <= (next_state == TX_HEADER || next_state == TX_DATA);
    end
    
    assign TXCKSB = clk_en_latched & clk;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            bit_cnt <= '0;
            shift_reg <= '0;
            has_data_reg <= '0;
        end else begin
            state <= next_state;
            
            if (latch_data) begin
                shift_reg <= pkt_header;
                has_data_reg <= pkt_has_data;
            end else if (state === TX_HEADER && bit_cnt == 63 && has_data_reg) begin
                shift_reg <= pkt_data;  // Load data payload for next phase
            end else if (shift_en) begin
                shift_reg <= {1'b0, shift_reg[63:1]};   // Shift right (LSB first)
            end
            
            if (state == TX_HEADER || state == TX_DATA)
                bit_cnt <= bit_cnt + 1'b1;
            else
                bit_cnt <= '0;
        end
    end
    
    always_comb begin
        next_state = state;
        latch_data = 1'b0;
        shift_en = 1'b0;
        tx_req_ready = 1'b0;
        
        case (state)
            IDLE: begin
                tx_req_ready = 1'b1;
                if(pkt_valid) begin
                    latch_data = 1'b1;
                    next_state = TX_HEADER;
                end 
            end
            
            TX_HEADER: begin
                shift_en = 1'b1;
                if (bit_cnt == 63) begin
                    if (has_data_reg) 
                        next_state = TX_DATA;
                    else 
                        next_state = IDLE;
                end 
            end
            
            TX_DATA: begin
                shift_en = 1'b1;
                if (bit_cnt == 63) 
                    next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // Output assignments. Data is edge-aligned with clock.
    assign TXDATASB = (state == TX_HEADER || state == TX_DATA) ? shift_reg[0] : 1'b0;
endmodule