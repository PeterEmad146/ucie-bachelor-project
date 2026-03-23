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
// 
// This module is PURELY COMBINATIONAL - zero clock latency.
//
// ======================================================================================
// Specification References:
//      S6.1.1      Packet types and common fields (opcode, srcid, dstid, CP, DP)
//      S6.1.2      Packet formmats - Table 50 (Register Access), Table 52 (Completion)
//      S6.1.3.2    Sideband data integrity: parity mismatch -> fatal UIE, no retry
// ======================================================================================
// Parity Convention - Even Parity
//      A packet is parity-correct when:
//          XOR (all protected header bits INCLUDING the CP bit ) == 0
//
//      Therefore, on TX:
//          cp_computed = XOR( hdr_in with CP=0, DP=0 ) <- 62 meaningful bits
//
//      On RX, checking proceeds identically:
//          expected_cp = XOR( hdr_in with CP=0, DP=0 )
//          cp_err      = ( expected_cp != hdr_in[CP_BIT] )
// ======================================================================================
// ERROR SEVERITY:
//      The UCIe sideband targets 1e-27 raw BER. No retry is provided at this layer.
//      Any CP or DP mismatch on receive is classified as a fatal Uncorrectable Internal 
//      Error (UIE) and must propagate to the Adapter via RDI pl_trainerror.
// ======================================================================================
// HEADER BIT-FIELD MAP  (64-bit header word — see also lphy_sb_pkt_enc.sv)
// -------------------------------------------------------------------------
//   Bits     Width  Field
//   -------  -----  -------------------------------------------------------
//   [63:59]    5    opcode[4:0]
//   [58:56]    3    srcid[2:0]
//   [55:53]    3    dstid[2:0]
//   [52]       1    CP  ← protected / verified by this module
//   [51]       1    DP  ← protected / verified by this module
//   [50]       1    Cr  (credit-return flag)
//   [49]       1    EP  (data poison)
//   [48:44]    5    Tag[4:0]
//   [43:17]   27    Addr[26:0] | MsgInfo[15:0]+MsgCode[7:0]+MsgSubcode[2:0]
//   [16:9]     8    BE[7:0]    | MsgSubcode[7:3] + reserved
//   [8:0]      9    Reserved
// ======================================================================================
// OPERATING MODES
// ---------------
//   mode_tx = 1 → TX / Encode
//     • hdr_in  : caller drives CP=0 and DP=0 before passing the header
//     • data_in : payload (ignored when has_data=0)
//     • cp_out  : value to INSERT at hdr[CP_BIT] before serialisation
//     • dp_out  : value to INSERT at hdr[DP_BIT] before serialisation
//     • parity_err : tied LOW (no checking in TX path)
//
//   mode_tx = 0 → RX / Check
//     • hdr_in  : complete received header including received CP and DP bits
//     • data_in : received payload
//     • cp_out  : re-computed expected CP (visible for debug)
//     • dp_out  : re-computed expected DP (visible for debug)
//     • parity_err : HIGH when cp or dp does not match → fatal UIE
//
// ======================================================================================

`timescale 1ns/1ps

module lphy_sb_crc (
    input  logic [63:0] hdr_in,     // for TX: fields to protect; for RX: received header
    input  logic [63:0] data_in,    // payload
    input  logic        has_data, 
    input  logic        mode_tx,    // 1=encode, 0=check
    output logic        cp_out,     // computed CP (TX) or error flag (RX)
    output logic        dp_out,     // computed DP (TX) or error flag (RX)
    output logic        parity_err  // RX only: mismatch detected
);

// Local parameters
//      These constants define which bits within the 64-bit header word
//      hold the CP and DP fields. All other sideband modules (encoder, decoder,
//      controller) MUST use these same positions.

localparam int unsigned CP_BIT = 52;    // Bit index of the Control Parity (CP) field in the 64-bit header
localparam int unsigned DP_BIT = 51;    // Bit index of the Data Parity (DP) field in the 64-bit header

// Internal signals

// Header with both CP and DP bit positions forced to zero.
// Used as the operand for the XOR-reduction that computes CP.
// Zeroing CP removes the self-reference; zeroing DP removes the
// excluded field from the CP computation per the spec definition
logic [63:0] hdr_masked;

// XOR-reduction of hdr_masked - this is expected (computed) CP
logic        cp_computed;

// XOR-reduction of the data payload - this is the expected (computed) DP
logic        dp_computed;


// Step 1 - Build the masked header
//
// Force CP[52] = 0 and DP[51] = 0.
//      TX mode: caller should already have these at 0; masking is a safety net that prevents
//               accidental self-corruption
//      RX mode: strips the received parity bits so the XOR-reduction computes expected
//               parity from the data fields only.
always_comb begin : proc_hdr_masked
    hdr_masked          = hdr_in;       // copy all 64 bits
    hdr_masked[CP_BIT]  = 1'b0;         // clear CP position
    hdr_masked[DP_BIT]  = 1'b0;         // clear DP position
end

// Step 2 - Compute Control Parity (CP)
//
// Even parity rule: XOR of (all protected bits ++ CP bits) == 0
//
// Therefore CP = XOR of all 64 bits in hdr_masked (bits 52 and 51 are 0, so
// the reduction effectively covers the other 62 bits).
//
// Synthesized as a 64-input XOR tree - single LUT depth on most FPGAs, one gate level on ASIC.
always_comb begin : proc_cp
    cp_computed = ^hdr_masked;
end

// Step 3 - Compute Data Parity (DP)
//
// DP = XOR of all 64 data payload bits when has_data = 1
// DP = 0                               when has_data = 0
//
// Callers supplying a 32-bit payload MUST zero-pad data_in[63:32].
always_comb begin : proc_dp
    if(has_data) begin
        dp_computed = ^data_in;     // even parity over full 64-bit payload
    end else begin
        dp_computed = 1'b0;         // spec: "if not data payload, this bit is 0"
    end
end

// Step 4 - Drive outputs
// 
// CP and DP computed values are always exported (useful for debug in both modes).
// The parity_err flag is meaningful only in RX mode.
always_comb begin : proc_outputs
    // Computed parity values - visible in both TX and RX modes
    cp_out = cp_computed;
    dp_out = dp_computed;

    if(mode_tx) begin
        parity_err = 1'b0;  // TX / Encode mode
                            // The caller will read cp_out and dp_out and insert them into the outgoing header word. No error checking here.
    end else begin
        // RX / Check mode
        // Compare the re-computed parity values against the parity fields carried in the received header word.
        parity_err = (cp_computed != hdr_in[CP_BIT]) |  // CP mismatch 
                     (dp_computed != hdr_in[DP_BIT]);   // DP mismatch
    end     
end // proc_outputs

// Formal / simulation assertions
// Excluded from synthesis via translate_off guards.

// synthesis translate_off

always_comb begin : proc_assertions
    // TX mode: CP bit in the incoming header must be 0.
    // The caller is responsible for clearing it before calling this module.
    // A non-zero CP at this stage indicates an integration error in the upper-level encoder.
    if(mode_tx && hdr_in[CP_BIT]) begin
        $warning("[lphy_sb_crc][TX] hdr_in[%0d] (CP) is not 0. \
                 Caller must zero CP before encoding. Computed parity will be incorrect.",
                     CP_BIT);
    end 

    // TX mode: DP bit in the incoming header must be 0.
    if (mode_tx && hdr_in[DP_BIT]) begin
            $warning("[lphy_sb_crc][TX] hdr_in[%0d] (DP) is not 0. \
                     Caller must zero DP before encoding. Computed parity will be incorrect.",
                     DP_BIT);    
    end

    // RX mode: a parity error is a fatal UIE; flag it promiently.
    if(!mode_tx && parity_err) begin
            $warning("[lphy_sb_crc][RX] Parity error detected! \
                     cp_expected=%b cp_received=%b | dp_expected=%b dp_received=%b. \
                     This is a fatal Uncorrectable Internal Error (UIE) per UCIe §6.1.3.2.",
                     cp_computed, hdr_in[CP_BIT],
                     dp_computed, hdr_in[DP_BIT]);    
    end
end // proc_assertions

// synthesis translate_on


endmodule : lphy_sb_crc