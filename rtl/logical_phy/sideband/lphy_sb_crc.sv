// Sideband CRC (Parity)
//
// The UCIe sideband relies on CP/DP parity (not the 16-bit mainband CRC from
// Appendix B). However, this module computes and checks the even parity 
// fields CP and DP for the sideband packets.
//
// Key behaviors:
//      - CP computation: Even parity of all bits in the 64-bit header excluding
//                        the CP bit position itself and the DP bit position
//      - DP computation: Even parity of all 64 bits of the data payload 
//      - Support both encode (TX) and check (RX) modes
//      - On RX mismatch: assert parity_err - this is a fatal UIE
//
// Important note: This is not the same as the mainband 16-bit CRC. The sideband
//                 uses simple even parity for integrity.

module lphy_sb_crc (
    input  logic [63:0] hdr_in,     // for TX: fields to protect; for RX: received header
    input  logic [63:0] data_in,    // payload
    input  logic        has_data, 
    input  logic        mode_tx,    // 1=encode, 0=check
    output logic        cp_out,     // computed CP (TX) or error flag (RX)
    output logic        dp_out,     // computed DP (TX) or error flag (RX)
    output logic        parity_err  // RX only: mismatch detected
);