// Packet Decoder
//
// Parse a received 64-bit header (and optional 64-bit data frame) into structured
// fields, verify CP/DP parity integrity.
//
// Key behaviors:
//      - Extract all fields from hdr_in[63:0]
//      - Recompute CP and DP; assert cp_err / dp_err on mismatch
//      - Determine if a second (data) frame is expected based on opcode
//      - Assert pkt_ready when full packet (header + optional data) has been
//        received and parsed.
//      - Map to Completion Status filed (Table 52) for completions: 000b=SC, 001b=UR, 100b=CA, 111b=Stall
//
// Error handling: Any parity error on the UCIe sideband link is a fatal UIE - no
//                 retry at the sideband level

module lphy_sb_pkt_dec (
    input  logic [63:0] hdr_in,
    input  logic [63:0] data_in, 
    input  logic        data_valid, 
    output logic [4:0]  opcode,
    output logic [2:0]  srcid,
    output logic [2:0]  dstid,
    output logic [26:0] addr,
    output logic [7:0]  be, 
    output logic        ep, 
    output logic [4:0]  tag,
    output logic        cr, 
    output logic [15:0] msginfo, 
    output logic [7:0]  msgcode, 
    output logic [7:0]  msgsubcode, 
    output logic [63:0] data_out, 
    output logic [2:0]  cpl_status,
    output logic        cp_err, 
    output logic        dp_err,
    output logic        pkt_ready
);