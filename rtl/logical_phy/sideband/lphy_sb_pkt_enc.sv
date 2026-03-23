// Packet Encoder
//
// Build a 64-bit or 128-bit sideband packet from structured fileds, compute
// CP and DP parity, and present it to the TX serializer.
//
// Key behaviors:
//      - Accept decoded fields: 'opcode', 'srcid', 'dstid', 'addr', 'be', 'tag', 'data', 'msgcode', 'msgsubcode', 'msginfo'
//      - Compute CP = even parity over all header bits except DP
//      - Compute DP = even parity over all data payload bits
//      - For messages without data (opcode '10010b'): produce single 64b frame
//      - For emssages with data / completions with data: produce header frame + data frame = 128b total
//      - Zero-pad 32b data to 64b
//
// Parity computation rule (Table 50):
//      - CP = XOR of all header bits [63:0] excluding bit positions of CP and DP themselves
//      - DP = XOR all data payload bits

module lphy_sb_pkt_enc (
    input  logic [4:0]  opcode,
    input  logic [2:0]  srcid,
    input  logic [2:0]  dstid, 
    input  logic [26:0] addr, 
    input  logic [7:0]  be, 
    input  logic        ep,
    input  logic [4:0]  tag,
    input  logic        cr, 
    input  logic [15:0] msginfo,
    input  logic [7:0]  msgcode,
    input  logic [7:0]  msgsubcode, 
    input  logic [63:0] data_in,
    input  logic        has_data, 
    output logic [63:0] hdr_out, 
    output logic [63:0] data_out, 
    output logic        two_frame_pkt   // 1=128b, 0=64b
);