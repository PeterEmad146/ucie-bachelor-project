`timescale 1ns / 1ps

module lphy_sb_pkt_enc(
    input logic clk,
    input logic rst_n,
    
    // Handshake 
    input logic req_valid, 
    output logic req_ready,
    
    // Common Packet Fields
    input logic [4:0] opcode,       // 5-bit opcode (Table 47)
    input logic [2:0] srcid,        // 3-bit Source ID
    input logic [2:0] dstid,        // 3-bit Destination ID
    input logic ep,                 // Data Poison bit
    input logic cr,                 // Credit return bit
    input logic [63:0] payload_in,  // 64-bit Data Payload (if applicable)
    
    // Register Access Specific Fields
    input logic [4:0] tag,          // 5-bit Request Tag
    input logic [7:0] be,           // 8-bit Byte Enables
    input logic [23:0] addr,        // 24-bit Address (Requests only)
    input logic [2:0] cp_status,    // 3-bit Completion Status (Completions Only)
    
    // Message Specific Fields
    input logic [7:0] msgcode,      // 8-bit Message Code
    input logic [7:0] msgsubcode,   // 8-bit Message Subcode
    input logic [15:0] msginfo,     // 16-bit Message Info
    
    // Formatted Output to Sideband TX Serializer
    output logic pkt_valid,
    output logic [63:0] pkt_header,
    output logic [63:0] pkt_data,
    output logic pkt_has_data        
);

    logic is_reg_req;
    logic is_reg_cpl;
    logic is_msg;
    logic has_data;
    logic [31:0] phase0_reg;
    logic [31:0] phase1_reg;
    logic [63:0] raw_header;
    logic [63:0] calc_header;
    
    // Decode Opcode to determine packet type and data presence (Table 47)
    always_comb begin
        is_msg = (opcode == 5'b10010) || (opcode == 5'b11011);
        
        has_data = (opcode == 5'b00001) ||  // 32b Mem Write
                   (opcode == 5'b00101) ||  // 32b Cfg Write
                   (opcode == 5'b01001) ||  // 64b Mem Write
                   (opcode == 5'b01101) ||  // 64b Cfg Write
                   (opcode == 5'b10001) ||  // Cpl with 32b Data
                   (opcode == 5'b11001) ||  // Cpl with 64b Data
                   (opcode == 5'b11011);    // Message with 64b Data
                   
       is_reg_req = (opcode == 5'b00000) || (opcode == 5'b00001) || 
                    (opcode == 5'b00100) || (opcode == 5'b00101) ||
                    (opcode == 5'b01000) || (opcode == 5'b01001) ||
                    (opcode == 5'b01100) || (opcode == 5'b01101);
       
       is_reg_cpl = (opcode == 5'b10000) || (opcode == 5'b10001) ||
                    (opcode == 5'b11001);
    end
    
    // Assemble the 64-bit Header (Phase 0 and Phase 1)
    always_comb begin
        if (is_msg) begin
            // Message Format
            // Phase 0: srcid[31:29], rsvd[28:22], msgcode[21:14], rsvd[13:5], opcode[4:0]
            phase0_reg = {srcid, 7'h00, msgcode, 9'h000, opcode};
            // Phase 1: dp[31], cp[30], rsvd[29:27], dstid[26:24], msginfo[23:8], msgsubcode[7:0]
            // Note: dp and cp are left 0 here; they will be calculated by the CRC block.
            phase1_reg = {2'b00, 3'b0, dstid, msginfo, msgsubcode};
        end else if (is_reg_cpl) begin
            // Register Access Completions
            // Phase 0: srcid[31:28], rsvd[28:27], tag[26:22], be[21:14], rsvd[13:6], ep[5], opcode[4:0]
            phase0_reg =  {srcid, 2'b00, tag, be, 8'h00, ep, opcode};
            // Phase 1: dp[31], cp[30], cr[29], rsvd[28:27], dstid[26:24], rsvd[23:3], cp_status[2:0]
            phase1_reg = {2'b00, cr, 2'b00, dstid, 21'b0, cp_status};
        end else begin
            // Register Access Requests 
            // Phase 0: srcid[31:28], rsvd[28:27], tag[26:22], be[21:14], rsvd[13:6], ep[5], opcode[4:0]
            phase0_reg =  {srcid, 2'b00, tag, be, 8'h00, ep, opcode};
            // Phase 1: dp[31], cp[30], cr[29], rsvd[28:27], dstid[26:24], addr[23:0]
            phase1_reg = {2'b00, cr, 2'b00, dstid, addr};
        end
        raw_header = {phase1_reg, phase0_reg};
    end
    
    // Instantiate Phase 1 Parity Calculator
    lphy_sb_crc parity_calc (
        .tx_header_in (raw_header),
        .tx_data_in (payload_in),
        .tx_has_data (has_data),
        .tx_header_out (calc_header),
        .rx_header_in (64'h0),
        .rx_data_in (64'h0),
        .rx_has_data (1'b0),
        .rx_cp_err (),
        .rx_dp_err ()
    );
    
    // Output assignments 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pkt_valid <= 1'b0;
            pkt_data <= 64'h0;
            pkt_has_data <= 1'b0;
            pkt_header <= 64'b0;
        end else begin
            pkt_valid <= req_valid;
            pkt_header <= calc_header;
            pkt_data <= payload_in;
            pkt_has_data <= has_data;
        end
    end
    
    assign req_ready = 1'b1;
    
endmodule
