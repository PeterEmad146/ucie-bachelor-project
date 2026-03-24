// ============================================================================
// Module   : lphy_sb_crc
// Project  : UCIe Logical PHY — Sideband Subsystem
// File     : lphy_sb_crc.sv
//
// ============================================================================
// PURPOSE
// -------
// Computes (TX mode) or verifies (RX mode) the two parity fields embedded
// inside every UCIe sideband packet header:
//
//   CP — Control Parity : even parity of all 64 header bits, excluding CP
//                         and DP positions themselves
//   DP — Data Parity    : even parity of all 64 data-payload bits;
//                         forced to 0 when no payload is present
//
// This module is PURELY COMBINATIONAL — zero clock latency, implemented
// entirely with continuous assign statements (no always blocks).
//
// ============================================================================
// SPECIFICATION REFERENCES
// ------------------------
//   §6.1.1   Packet types and common fields (opcode, srcid, dstid, CP, DP)
//   §6.1.2   Packet formats
//              Table 50 — Register Access field descriptions (CP, DP, EP...)
//              Table 52 — Completion field descriptions
//   §6.1.3.2 Sideband data integrity:
//              "Receivers of sideband packets must check for Data or Control
//               parity errors, and any of these errors is mapped to a fatal
//               Uncorrectable Internal Error (UIE)."
//
// ============================================================================
// PARITY CONVENTION — EVEN PARITY
// --------------------------------
// Even parity: XOR of all protected bits equals 0 for a valid word.
//
// TX path (encode):
//   1. Caller provides the header with CP[52]=0 and DP[51]=0.
//   2. This module computes:
//        cp_out = XOR of all 64 header bits  (with CP=0, DP=0 already set)
//        dp_out = XOR of all 64 payload bits (or 0 if no payload)
//   3. Caller inserts cp_out into hdr[CP_BIT] and dp_out into hdr[DP_BIT].
//
// RX path (check):
//   1. Caller provides the complete received header (CP and DP present).
//   2. This module re-computes expected CP/DP by masking those two positions
//      to 0 and XOR-reducing the result.
//   3. Comparison: expected vs. received — sets parity_err on mismatch.
//
// Self-consistency property:
//   If a packet is correctly encoded, then for the received header H:
//     XOR( H with CP=0, DP=0 )  ==  H[CP_BIT]   →  no CP error
//     XOR( payload )             ==  H[DP_BIT]   →  no DP error
//
// ============================================================================
// IVERILOG COMPATIBILITY NOTE
// ---------------------------
// Iverilog 12 emits "sorry: constant selects in always_* processes are not
// currently supported" when a localparam is used as a bit-select INDEX on
// the LEFT-HAND SIDE inside an always_comb block (e.g. hdr[CP_BIT] = 0).
// To keep the code clean and warning-free across all simulators:
//
//   • ALL combinational logic uses continuous assign statements only.
//   • Bit masking is achieved via bitwise AND with a precomputed mask constant
//     — no LHS bit-selects, no always blocks.
//   • Bit extraction on the RHS uses right-shift followed by AND-with-1,
//     which is guaranteed to work in all tools.
//
// ============================================================================
// HEADER BIT-FIELD MAP  (64-bit header word)
// -------------------------------------------
// All sideband modules in this project share this layout.
//
//   Bits     Width  Field
//   -------  -----  -------------------------------------------------------
//   [63:59]    5    opcode[4:0]          — packet type (Table 47)
//   [58:56]    3    srcid[2:0]           — source identifier (Tables 48/49)
//   [55:53]    3    dstid[2:0]           — destination identifier
//   [52]       1    CP                   ← computed / verified by this module
//   [51]       1    DP                   ← computed / verified by this module
//   [50]       1    Cr                   — credit-return flag
//   [49]       1    EP                   — data poison
//   [48:44]    5    Tag[4:0]             — request / completion tag
//   [43:17]   27    Addr[26:0]           — byte address (register access)
//                   or MsgInfo[15:0] + MsgCode[7:0] + MsgSubcode[3:0]
//   [16:9]     8    BE[7:0]              — byte enables
//   [8:0]      9    Reserved
//

`timescale 1ns / 1ps

module lphy_sb_crc (

    // -----------------------------------------------------------------------
    // hdr_in [63:0] — 64-bit packet header
    //
    //   TX mode : caller must pre-clear CP[52]=0 and DP[51]=0.
    //             The PARITY_CLEAR_MASK provides a safety net, but callers
    //             must not rely on it (correct practice is to zero those
    //             bits before calling).
    //   RX mode : complete received header including received CP and DP.
    // -----------------------------------------------------------------------
    input  logic [63:0] hdr_in,

    // -----------------------------------------------------------------------
    // data_in [63:0] — 64-bit data payload
    //
    //   32-bit payloads must be zero-padded by the caller in bits [63:32].
    //   Ignored entirely (DP forced to 0) when has_data = 0.
    // -----------------------------------------------------------------------
    input  logic [63:0] data_in,

    // -----------------------------------------------------------------------
    // has_data — payload-present flag
    //   0 : no payload — DP = 0 regardless of data_in  (§6.1.2 Table 50)
    //   1 : payload present — DP = even parity of data_in[63:0]
    // -----------------------------------------------------------------------
    input  logic        has_data,

    // -----------------------------------------------------------------------
    // mode_tx — mode select
    //   1 : TX / encode  — compute CP and DP; parity_err = 0
    //   0 : RX / check   — verify CP and DP; assert parity_err on mismatch
    // -----------------------------------------------------------------------
    input  logic        mode_tx,

    // -----------------------------------------------------------------------
    // cp_out — computed / expected Control Parity
    //   TX mode : insert this value into hdr[52] before serialisation
    //   RX mode : expected CP value (also visible in waveform for debug)
    // -----------------------------------------------------------------------
    output logic        cp_out,

    // -----------------------------------------------------------------------
    // dp_out — computed / expected Data Parity
    //   TX mode : insert this value into hdr[51] before serialisation
    //   RX mode : expected DP value (also visible in waveform for debug)
    // -----------------------------------------------------------------------
    output logic        dp_out,

    // -----------------------------------------------------------------------
    // parity_err — parity error flag
    //   TX mode : always 0 (no checking in the encode path)
    //   RX mode : 1 when received CP or DP does not match the expected value
    //             → fatal UIE; must propagate via RDI pl_trainerror §6.1.3.2
    // -----------------------------------------------------------------------
    output logic        parity_err

);

    // ========================================================================
    // Local parameters — header field positions and derived bit masks
    //
    // CP_BIT and DP_BIT define the authoritative positions.
    //
    // CP_MASK and DP_MASK are the single-bit masks for those positions:
    //   CP_MASK = 2^52 = 0x0010_0000_0000_0000
    //   DP_MASK = 2^51 = 0x0008_0000_0000_0000
    //
    // PARITY_CLEAR_MASK clears both positions simultaneously:
    //   = ~(CP_MASK | DP_MASK) = ~0x0018_0000_0000_0000 = 0xFFE7_FFFF_FFFF_FFFF
    //
    // Using pre-computed mask constants instead of localparams as bit-select
    // indices eliminates the iverilog "constant selects in always_*" warning
    // while keeping the intent explicit and readable.
    // ========================================================================

    // Bit positions (kept as documentation and used in the consistency check)
    localparam int unsigned CP_BIT = 52;
    localparam int unsigned DP_BIT = 51;

    // Single-bit masks
    localparam logic [63:0] CP_MASK = 64'h0010_0000_0000_0000;   // 1 << 52
    localparam logic [63:0] DP_MASK = 64'h0008_0000_0000_0000;   // 1 << 51

    // Combined clear mask: AND with any header to zero both CP and DP
    localparam logic [63:0] PARITY_CLEAR_MASK = 64'hFFE7_FFFF_FFFF_FFFF;

    // ========================================================================
    // Internal signals
    // ========================================================================

    // Header with CP[52] and DP[51] forced to 0 via bitwise AND.
    // Used as the operand for the CP XOR-reduction.
    logic [63:0] hdr_masked;

    // Re-computed (expected) parity values
    logic cp_computed;
    logic dp_computed;

    // Received parity values extracted from hdr_in.
    // Extraction via (hdr_in >> N) & 1 is clean and portable.
    logic cp_received;
    logic dp_received;

    // ========================================================================
    // Step 1 — Mask the header: zero CP[52] and DP[51]
    //
    // AND with PARITY_CLEAR_MASK zeros bits 52 and 51 without affecting
    // any other bit.  The result is the set of "data" header bits only —
    // the operand for computing the expected CP.
    //
    // This is a 64-bit AND: single gate stage on ASIC, 1 LUT-6 per 6 bits
    // on FPGA.  Zero clock latency.
    // ========================================================================

    assign hdr_masked = hdr_in & PARITY_CLEAR_MASK;

    // ========================================================================
    // Step 2 — Compute expected Control Parity (CP)
    //
    // XOR-reduce all 64 bits of hdr_masked.  Because bits 52 and 51 are
    // guaranteed to be 0 after the mask step, the reduction covers the
    // remaining 62 data bits exactly as the specification requires.
    //
    // Synthesis: log2(64) = 6-stage balanced XOR tree.
    // ========================================================================

    assign cp_computed = ^hdr_masked;

    // ========================================================================
    // Step 3 — Compute expected Data Parity (DP)
    //
    // XOR-reduce all 64 payload bits when has_data = 1; return 0 otherwise.
    // Per §6.1.2 Table 50: "If there is no data payload, this bit is set 0."
    //
    // Callers supplying a 32-bit payload MUST zero-pad data_in[63:32].
    // ========================================================================

    assign dp_computed = has_data ? (^data_in) : 1'b0;

    // ========================================================================
    // Step 4 — Extract received CP and DP from the incoming header
    //
    // Right-shift and mask: portable across all simulators and synthesisers.
    // On synthesis this collapses to a direct wire assignment (zero hardware).
    //
    //   cp_received = hdr_in[52]    (equivalent, but the shift form avoids
    //   dp_received = hdr_in[51]     the iverilog localparam-index warning)
    // ========================================================================

    assign cp_received = (hdr_in >> CP_BIT) & 1'b1;   // bit 52 of hdr_in
    assign dp_received = (hdr_in >> DP_BIT) & 1'b1;   // bit 51 of hdr_in

    // ========================================================================
    // Step 5 — Drive outputs
    //
    // cp_out and dp_out always reflect the computed values regardless of mode
    // so that they remain visible in simulation waveforms and debug flows.
    //
    // parity_err:
    //   TX mode → tied 0  (no error checking in the encode direction)
    //   RX mode → 1 if computed CP != received CP, OR
    //               computed DP != received DP.
    //             The OR is correct: either field mismatch is independently
    //             sufficient to indicate a corrupted packet.
    //             §6.1.3.2 specifies this as a fatal UIE — no retry.
    // ========================================================================

    assign cp_out = cp_computed;
    assign dp_out = dp_computed;

    assign parity_err = mode_tx ? 1'b0
                                : ( (cp_computed != cp_received) |
                                    (dp_computed != dp_received)  );

    // ========================================================================
    // Simulation-only: parameter consistency check
    //
    // Fires once at time 0.  Catches future maintenance errors where CP_BIT
    // or DP_BIT are changed without updating the mask constants.
    //
    // Excluded from synthesis by translate_off guard.
    // ========================================================================

    // synthesis translate_off
    initial begin : param_consistency_check
        // Verify CP_MASK matches CP_BIT.
        // Iverilog requires a single string literal per $fatal call (no concatenation).
        if (CP_MASK !== (64'h1 << CP_BIT))
            $fatal(1, "[lphy_sb_crc] CP_MASK=0x%016h != (1<<%0d). Update CP_MASK.", CP_MASK, CP_BIT);

        // Verify DP_MASK matches DP_BIT
        if (DP_MASK !== (64'h1 << DP_BIT))
            $fatal(1, "[lphy_sb_crc] DP_MASK=0x%016h != (1<<%0d). Update DP_MASK.", DP_MASK, DP_BIT);

        // Verify PARITY_CLEAR_MASK is the complement of the union of both masks
        if (PARITY_CLEAR_MASK !== ~(CP_MASK | DP_MASK))
            $fatal(1, "[lphy_sb_crc] PARITY_CLEAR_MASK=0x%016h is wrong. Must be ~(CP_MASK|DP_MASK)=0x%016h.",
                   PARITY_CLEAR_MASK, ~(CP_MASK | DP_MASK));
    end
    // synthesis translate_on

endmodule : lphy_sb_crc