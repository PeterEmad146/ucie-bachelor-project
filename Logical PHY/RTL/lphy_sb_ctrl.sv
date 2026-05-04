`timescale 1ps / 1ps

module lphy_sb_ctrl (
    input logic lclk,               // Local downstream processing clock (e.g., 2 GHz)
    input logic rst_n,
    input logic rdi_in_reset,       // RDI Reset state indicator for Flow Control
    
    // Local TX Interface (from D2D Adapter)
    input  logic        tx_req_valid,
    output logic        tx_req_ready,
    input  logic [4:0]  tx_opcode,
    input  logic [2:0]  tx_srcid,
    input  logic [2:0]  tx_dstid,
    input  logic        tx_ep,
    input  logic        tx_cr,
    input  logic [63:0] tx_payload,
    input  logic [4:0]  tx_tag,
    input  logic [7:0]  tx_be,
    input  logic [23:0] tx_addr,
    input  logic [2:0]  tx_cp_status,
    input  logic [7:0]  tx_msgcode, 
    input  logic [7:0]  tx_msgsubcode,
    input  logic [15:0] tx_msginfo,
    input  logic        tx_local_crd_ret,
    
    // Local RX Interface (to D2D Adapter)
    output logic        rx_req_valid,
    output logic [4:0]  rx_opcode, 
    output logic [2:0]  rx_srcid,
    output logic [2:0]  rx_dstid,
    output logic        rx_ep, 
    output logic        rx_cr, 
    output logic [63:0] rx_payload, 
    output logic [4:0]  rx_tag,
    output logic [7:0]  rx_be, 
    output logic [23:0] rx_addr, 
    output logic [2:0]  rx_cp_status, 
    output logic [7:0]  rx_msgcode,
    output logic [7:0]  rx_msgsubcode, 
    output logic [15:0] rx_msginfo,
    output logic        rx_parity_err,
    
    // PARALLEL SIDEBAND INTERFACE (To/From AFE based on CSV specifications)
    output logic        afe_tx_valid,
    output logic [63:0] afe_tx_data,    // Sends Header, then Payload sequentially
    input  logic        afe_tx_ready,   // AFE asserts when ready to accept 64-bit chunk

    input  logic        afe_rx_valid,
    input  logic [63:0] afe_rx_data,    // Receives Header, then Payload sequentially
    output logic        afe_rx_en       // Enables Sideband RX in the AFE
);

    // Internal Signals
    logic tx_allowed;
    logic seq_tx_ready;
    logic fire_encoder;
    
    logic enc_pkt_valid;
    logic [63:0] enc_pkt_header;
    logic [63:0] enc_pkt_data;
    logic enc_pkt_has_data;
    
    logic dec_pkt_valid;
    logic [63:0] dec_pkt_header;
    logic [63:0] dec_pkt_data;
    
    // Decode Opcode for Flow Control
    logic is_reg_req, is_reg_cpl, is_msg;
    always_comb begin
        is_reg_req = (tx_opcode == 5'b00000) || (tx_opcode == 5'b00001) || 
                     (tx_opcode == 5'b00100) || (tx_opcode == 5'b00101) || 
                     (tx_opcode == 5'b01000) || (tx_opcode == 5'b01001) || 
                     (tx_opcode == 5'b01100) || (tx_opcode == 5'b01101);
                 
        is_reg_cpl = (tx_opcode == 5'b10000) || (tx_opcode == 5'b10001) || 
                     (tx_opcode == 5'b11001);
                     
        is_msg     = (tx_opcode == 5'b10010) || (tx_opcode == 5'b11011);
    end
    
    // 1. Flow Control
    lphy_sb_flow_ctrl #(.LOCAL_CREDITS_INIT(32)) fc_inst (
        .clk(lclk),
        .rst_n(rst_n),
        .rdi_in_reset(rdi_in_reset), 
        .req_valid(tx_req_valid),
        .is_reg_req(is_reg_req),
        .is_reg_cpl(is_reg_cpl), 
        .is_msg(is_msg), 
        .tx_allowed(tx_allowed), 
        .local_crd_ret(tx_local_crd_ret), 
        .remote_crd_ret(rx_req_valid & rx_cr)
    );
    
    // 2. Packet Encoder 
    assign fire_encoder = tx_req_valid & tx_allowed & seq_tx_ready;
    assign tx_req_ready = tx_allowed & seq_tx_ready;
    
    lphy_sb_pkt_enc enc_inst (
        .clk(lclk), 
        .rst_n(rst_n), 
        .req_valid(fire_encoder), 
        .req_ready(),   
        .opcode(tx_opcode),
        .srcid(tx_srcid), 
        .dstid(tx_dstid),
        .ep(tx_ep),
        .cr(tx_cr), 
        .payload_in(tx_payload), 
        .tag(tx_tag), 
        .be(tx_be), 
        .addr(tx_addr), 
        .cp_status(tx_cp_status), 
        .msgcode(tx_msgcode), 
        .msgsubcode(tx_msgsubcode), 
        .msginfo(tx_msginfo), 
        .pkt_valid(enc_pkt_valid), 
        .pkt_header(enc_pkt_header), 
        .pkt_data(enc_pkt_data), 
        .pkt_has_data(enc_pkt_has_data)
    );
    
        // =========================================================================
        // 3. TX Word Sequencer (Replaces the TX SerDes)
        // =========================================================================
        typedef enum logic {ST_TX_IDLE, ST_TX_DATA} tx_st_t;
        tx_st_t tx_state, tx_next_state;
        
        logic [63:0] hold_tx_data;
    
        // State Register
        always_ff @(posedge lclk or negedge rst_n) begin
            if (!rst_n) tx_state <= ST_TX_IDLE;
            else tx_state <= tx_next_state;
        end
    
        // Next State Logic
        always_comb begin
            tx_next_state = tx_state;
            case (tx_state)
                ST_TX_IDLE: begin
                    // If a packet arrives and it has data, move to DATA state
                    if (enc_pkt_valid && seq_tx_ready && enc_pkt_has_data) 
                        tx_next_state = ST_TX_DATA;
                end
                ST_TX_DATA: begin
                    // Once the AFE accepts the data payload, return to IDLE
                    if (afe_tx_ready) 
                        tx_next_state = ST_TX_IDLE;
                end
            endcase
        end
    
        // Registered Outputs (Glitch-free to AFE)
        always_ff @(posedge lclk or negedge rst_n) begin
            if (!rst_n) begin
                afe_tx_valid <= 1'b0;
                afe_tx_data <= 64'h0;
                seq_tx_ready <= 1'b1;
                hold_tx_data <= 64'h0;
            end else begin
                case (tx_state)
                    ST_TX_IDLE: begin
                        if (enc_pkt_valid && seq_tx_ready) begin
                            // Push Header to AFE
                            afe_tx_valid <= 1'b1;
                            afe_tx_data <= enc_pkt_header;
                            
                            if (enc_pkt_has_data) begin
                                hold_tx_data <= enc_pkt_data;
                                seq_tx_ready <= 1'b0; // Block new packets until payload is sent
                            end
                        end else if (afe_tx_ready) begin
                            // Clear valid if no new packet is pending
                            afe_tx_valid <= 1'b0;
                        end
                    end
                    
                    ST_TX_DATA: begin
                        if (afe_tx_ready) begin
                            // Push Payload to AFE
                            afe_tx_valid <= 1'b1;
                            afe_tx_data <= hold_tx_data;
                            seq_tx_ready <= 1'b1; // Ready for next packet
                        end
                    end
                endcase
            end
        end
    
    // =========================================================================
    // 4. RX Word Sequencer (Replaces the RX SerDes)
    // =========================================================================
    assign afe_rx_en = 1'b1; // Enable AFE receivers
    
    typedef enum logic {ST_RX_HDR, ST_RX_DATA} rx_st_t;
    rx_st_t rx_state;
    
    logic [63:0] hold_rx_header;
    logic        rx_expects_data;
    logic [4:0]  raw_opcode;

    always_ff @(posedge lclk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= ST_RX_HDR;
            dec_pkt_valid <= 1'b0;
            dec_pkt_header <= 64'h0;
            dec_pkt_data <= 64'h0;
            hold_rx_header <= 64'h0;
            rx_expects_data <= 1'b0;
        end else begin
            dec_pkt_valid <= 1'b0; // Default clear pulse
            
            case (rx_state)
                ST_RX_HDR: begin
                    if (afe_rx_valid) begin
                        hold_rx_header <= afe_rx_data;
                        
                        // Peek into the raw header to determine if payload is expected
                        raw_opcode = afe_rx_data[4:0];
                        if (raw_opcode == 5'b00001 || raw_opcode == 5'b00101 || 
                            raw_opcode == 5'b01001 || raw_opcode == 5'b01101 || 
                            raw_opcode == 5'b10001 || raw_opcode == 5'b11001 || 
                            raw_opcode == 5'b11011) begin
                            rx_state <= ST_RX_DATA; // Move to data wait state
                        end else begin
                            // Header-only packet is complete
                            dec_pkt_header <= afe_rx_data;
                            dec_pkt_data <= 64'h0;
                            dec_pkt_valid <= 1'b1;
                        end
                    end
                end
                
                ST_RX_DATA: begin
                    if (afe_rx_valid) begin
                        // Payload received, push full packet to decoder
                        dec_pkt_header <= hold_rx_header;
                        dec_pkt_data <= afe_rx_data;
                        dec_pkt_valid <= 1'b1;
                        rx_state <= ST_RX_HDR;
                    end
                end
            endcase
        end
    end

    // 5. Packet Decoder
    lphy_sb_pkt_dec dec_inst (
        .clk(lclk),
        .rst_n(rst_n),
        .pkt_valid(dec_pkt_valid),
        .pkt_header(dec_pkt_header),
        .pkt_data(dec_pkt_data),
        .req_valid(rx_req_valid),
        .opcode(rx_opcode), 
        .srcid(rx_srcid), 
        .dstid(rx_dstid),
        .ep(rx_ep), 
        .cr(rx_cr), 
        .payload_out(rx_payload),
        .tag(rx_tag), 
        .be(rx_be), 
        .addr(rx_addr), 
        .cp_status(rx_cp_status),
        .msgcode(rx_msgcode), 
        .msgsubcode(rx_msgsubcode), 
        .msginfo(rx_msginfo),
        .parity_err(rx_parity_err)
    );

endmodule