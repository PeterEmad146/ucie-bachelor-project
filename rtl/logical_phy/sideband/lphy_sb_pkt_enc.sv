// ============================================================================
// Module   : lphy_sb_pkt_enc
// Project  : UCIe Logical PHY — Sideband Subsystem
// File     : lphy_sb_pkt_enc.sv
//
// ============================================================================
// PURPOSE
// -------
// Builds a complete UCIe sideband packet from individual field inputs.
// This module:
//   1. Selects which field group to pack (register-access vs. message layout)
//      based on the opcode.
//   2. Assembles the 64-bit header word with CP[52]=0 and DP[51]=0 initially.
//   3. Instantiates lphy_sb_crc to compute the correct CP and DP values.
//   4. Inserts the computed CP and DP into the final header word.
//   5. Passes the data payload through unchanged.
//   6. Signals whether the packet is one frame (64 bits, no data) or
//      two frames (128 bits, header + payload).
//
// This module is PURELY COMBINATIONAL.  The downstream TX serializer
// (lphy_sb_tx) consumes hdr_out, data_out, and two_frame_pkt.
//
// ============================================================================
// SPECIFICATION REFERENCES
// ------------------------
//   §4.1.5   Sideband transmission — 64-bit serial frame, 32 UI gap
//   §6.1.1   Packet types and opcode table (Table 47)
//   §6.1.2   Packet formats
//              Figure 100 — Register Access request format
//              Figure 101 — Register Access completion format
//              Figure 102 — Message without data format
//              Figure 103 — Message with data format
//              Table 47   — Opcode encodings
//              Table 50   — Register Access field descriptions
//              Table 52   — Completion field descriptions
//   §6.1.3   Flow control and data integrity (CP, DP, even parity)
//
// ============================================================================
// HEADER BIT-FIELD MAP  (authoritative layout used by all sideband modules)
// --------------------------------------------------------------------------
//
//  ── COMMON TO ALL PACKET TYPES ──────────────────────────────────────────
//   [63:59]   5  opcode[4:0]   — packet type (see OPCODE DECODE below)
//   [58:56]   3  srcid[2:0]    — source identifier  (Table 48 / 49)
//   [55:53]   3  dstid[2:0]    — destination identifier
//   [52]      1  CP            ← computed and inserted by this module
//   [51]      1  DP            ← computed and inserted by this module
//   [50]      1  Cr            — credit-return flag
//
//  ── REGISTER ACCESS & COMPLETION (opcode[4] = 0, or completions) ────────
//   [49]      1  EP            — data poison
//   [48:44]   5  Tag[4:0]      — request / completion tag
//   [43:17]  27  Addr[26:0]    — byte address (reg access)
//                               or {24'h0, Status[2:0]} (completion caller)
//   [16:9]    8  BE[7:0]       — byte enables
//   [8:0]     9  Reserved
//
//  ── MESSAGE (is_msg = opcode[4] & opcode[1]) ─────────────────────────────
//   [49:44]   6  Reserved
//   [43:28]  16  MsgInfo[15:0] — message information / credit count / stall
//   [27:20]   8  MsgCode[7:0]  — message type (Tables 53–56)
//   [19:12]   8  MsgSubcode[7:0]
//   [11:0]   12  Reserved
//
// ============================================================================
// OPCODE DECODE  (Table 47)
// -------------------------
//   Opcode    Packet type                has_data  is_msg  is_reg_access
//   -------   -------------------------  --------  ------  -------------
//   00000b    32-bit Memory Read         0         0       1
//   00001b    32-bit Memory Write        1         0       1
//   00100b    32-bit Config Read         0         0       1
//   00101b    32-bit Config Write        1         0       1
//   01000b    64-bit Memory Read         0         0       1
//   01001b    64-bit Memory Write        1         0       1
//   01100b    64-bit Config Read         0         0       1
//   01101b    64-bit Config Write        1         0       1
//   10000b    Completion w/o Data        0         0       0
//   10001b    Completion w/ 32b Data     1         0       0
//   11001b    Completion w/ 64b Data     1         0       0
//   10010b    Message w/o Data           0         1       0
//   11011b    Message w/ 64b Data        1         1       0
//
//   has_data      = opcode[0]               (single-bit decode, verified)
//   is_msg        = opcode[4] & opcode[1]   (two-bit AND, verified)
//   is_reg_access = ~opcode[4]              (single-bit NOT)
//
// ============================================================================
// DATA PAYLOAD CONVENTION
// -----------------------
//   32-bit payloads (opcodes 00001b, 00101b, 10001b):
//     Caller MUST zero-pad data_in[63:32] = 0.
//     data_in[31:0] carries the actual 32-bit value.
//   64-bit payloads (opcodes 01001b, 01101b, 11001b, 11011b):
//     data_in[63:0] carries the full value.
//   No-data packets: data_in is ignored; data_out is tied to 64'h0.
//
// ============================================================================
// COMPLETION PACKETS — STATUS ENCODING CONVENTION
// ------------------------------------------------
//   Status[2:0] is placed by the CALLER into addr[2:0] before passing
//   addr[26:0] to this encoder.  The encoder treats addr uniformly.
//   Caller must set addr[26:3] = 24'h0 for completions.
//
//   Status encodings (Table 52):
//     000b — Successful Completion (SC)
//     001b — Unsupported Request (UR)
//     100b — Completer Abort (CA)
//     111b — Stall (for Retimers)
//
// ============================================================================
// IVERILOG COMPATIBILITY
// ----------------------
// All combinational logic is implemented with continuous assign statements.
// No always_comb blocks with LHS localparams as bit-select indices are used.
// Bit-field insertion uses bitwise OR with precomputed 64-bit mask constants.
// Bit-field extraction uses right-shift and AND-with-1 or direct slice.
//
// ============================================================================

`timescale 1ns / 1ps

module lphy_sb_pkt_enc (

    // -----------------------------------------------------------------------
    // ── COMMON FIELDS (all packet types) ───────────────────────────────────
    // -----------------------------------------------------------------------

    // opcode[4:0] — selects packet type (Table 47)
    // Drives has_data, is_msg, is_reg_access decode internally.
    input  logic [4:0]  opcode,

    // srcid[2:0] — source identifier (Tables 48/49)
    //   On the physical UCIe link: 001b=D2D Adapter, 010b=Physical Layer
    input  logic [2:0]  srcid,

    // dstid[2:0] — destination identifier (Tables 48/49)
    //   dstid[2]=1 means remote die; dstid[1:0] selects sub-target.
    input  logic [2:0]  dstid,

    // cr — credit-return flag (Table 50/52)
    //   Set by the D2D Adapter to piggyback a credit return on any packet.
    //   Used for the E2E credit loop between Link partners.
    input  logic        cr,

    // -----------------------------------------------------------------------
    // ── REGISTER ACCESS AND COMPLETION FIELDS ──────────────────────────────
    //   Used when opcode[4]=0 (register access) or for completions.
    //   Ignored (not packed into header) when is_msg=1.
    // -----------------------------------------------------------------------

    // ep — data poison flag (Table 50)
    //   The completer sets this to indicate poisoned data.
    input  logic        ep,

    // tag[4:0] — request / completion tag (Table 50/52)
    //   Unique tag per outstanding request; used to correlate completions.
    input  logic [4:0]  tag,

    // addr[26:0] — byte address for register reads/writes (Table 50)
    //   For completions: caller encodes Status[2:0] into addr[2:0] and
    //   sets addr[26:3]=24'h0.  See COMPLETION ENCODING CONVENTION above.
    input  logic [26:0] addr,

    // be[7:0] — byte enables (Table 50/52)
    //   BE[7:4] are reserved for 32-bit transactions (caller must set to 0).
    //   Completer echoes back the same BE value from the original request.
    input  logic [7:0]  be,

    // -----------------------------------------------------------------------
    // ── MESSAGE FIELDS ──────────────────────────────────────────────────────
    //   Used when is_msg = opcode[4] & opcode[1].
    //   Ignored when is_reg_access or is_completion.
    // -----------------------------------------------------------------------

    // msginfo[15:0] — message-specific information (Tables 53–56)
    //   Carries credit counts, stall flags, or link-management sub-fields.
    //   0000h = regular/non-stall; FFFFh = Stall (Retimer use)
    input  logic [15:0] msginfo,

    // msgcode[7:0] — message type identifier (Table 53)
    //   Examples: 01h=AdvCap.Adapter, 03h=LinkMgmt.Adapter0.Req,
    //             A5h=training req, AAh=training resp
    input  logic [7:0]  msgcode,

    // msgsubcode[7:0] — message sub-type (Table 53)
    //   Distinguishes variants within the same MsgCode family.
    //   Examples: 00h=SBINIT, 01h=PARAM, 03h=REPAIRCLK
    input  logic [7:0]  msgsubcode,

    // -----------------------------------------------------------------------
    // ── DATA PAYLOAD ────────────────────────────────────────────────────────
    // -----------------------------------------------------------------------

    // data_in[63:0] — 64-bit payload word
    //   32-bit payloads: caller zero-pads [63:32]=0, value in [31:0].
    //   64-bit payloads: full word used.
    //   No-data packets: data_in is ignored and data_out = 64'h0.
    input  logic [63:0] data_in,

    // -----------------------------------------------------------------------
    // ── OUTPUTS ─────────────────────────────────────────────────────────────
    // -----------------------------------------------------------------------

    // hdr_out[63:0] — complete 64-bit packet header
    //   CP[52] and DP[51] are computed and inserted by this module.
    //   Ready for the TX serializer (lphy_sb_tx) to send as frame 0.
    output logic [63:0] hdr_out,

    // data_out[63:0] — data payload
    //   Pass-through of data_in when has_data=1.
    //   Tied to 64'h0 when has_data=0.
    //   Ready for lphy_sb_tx to send as frame 1 (when two_frame_pkt=1).
    output logic [63:0] data_out,

    // two_frame_pkt — frame count indicator
    //   0 : packet is a single 64-bit frame (header only, no payload)
    //   1 : packet is 128 bits (header frame + data frame)
    //   Directly equals the decoded has_data signal.
    output logic        two_frame_pkt,

    // enc_cp_out — encoded Control Parity (debug / verification port)
    //   This is the CP value inserted into hdr_out[52].
    //   Exposed so the testbench and downstream decoder can cross-check.
    output logic        enc_cp_out,

    // enc_dp_out — encoded Data Parity (debug / verification port)
    //   This is the DP value inserted into hdr_out[51].
    output logic        enc_dp_out

);

    // ========================================================================
    // Local parameters — header bit positions and mask constants
    //
    // The mask constants are precomputed so that bit-field insertion is done
    // via bitwise OR with a 64-bit constant — no always_comb LHS bit-selects,
    // no iverilog warnings.
    // ========================================================================

    // Bit index of the Control Parity field in the 64-bit header
    localparam int unsigned CP_BIT = 52;

    // Bit index of the Data Parity field in the 64-bit header
    localparam int unsigned DP_BIT = 51;

    // Single-bit mask for CP (2^52)
    localparam logic [63:0] CP_MASK = 64'h0010_0000_0000_0000;

    // Single-bit mask for DP (2^51)
    localparam logic [63:0] DP_MASK = 64'h0008_0000_0000_0000;

    // ========================================================================
    // Step 1 — Opcode decode (single-bit combinational, verified above)
    //
    //   has_data      = opcode[0]            payload present?
    //   is_msg        = opcode[4] & opcode[1] message-type packet?
    //   is_reg_access = ~opcode[4]           register read/write/cfg packet?
    //
    // Note: completions have opcode[4]=1 and opcode[1]=0, so they fall
    // into neither is_msg nor is_reg_access.  They use the register-access
    // header layout (ep, tag, addr, be) since those fields are carried in
    // completions as well (Table 52).
    // ========================================================================

    logic has_data;       // packet carries a data payload frame
    logic is_msg;         // message-type packet (use msg header layout)

    assign has_data = opcode[0];
    assign is_msg   = opcode[4] & opcode[1];

    // ========================================================================
    // Step 2 — Build the 50-bit type-specific payload for bits [49:0]
    //
    // The header is split into two parts for clarity:
    //   Upper part [63:50] : 14 bits common to all types
    //                        {opcode, srcid, dstid, CP=0, DP=0, Cr}
    //   Lower part [49:0]  : 50 bits type-specific
    //                        (muxed between reg-access and message layouts)
    //
    // Register-access / Completion layout [49:0]:
    //   [49]    ep       (1 bit)
    //   [48:44] tag      (5 bits)
    //   [43:17] addr     (27 bits)
    //   [16:9]  be       (8 bits)
    //   [8:0]   reserved (9 bits)
    //   Total: 1+5+27+8+9 = 50 bits ✓
    //
    // Message layout [49:0]:
    //   [49:44] reserved  (6 bits)
    //   [43:28] msginfo   (16 bits)
    //   [27:20] msgcode   (8 bits)
    //   [19:12] msgsubcode(8 bits)
    //   [11:0]  reserved  (12 bits)
    //   Total: 6+16+8+8+12 = 50 bits ✓
    // ========================================================================

    // 50-bit payload for register-access and completion packets
    // Concatenation order: MSB first → LSB last, total = 1+5+27+8+9 = 50
    logic [49:0] payload_reg;
    assign payload_reg = {ep,          //  [49]    — EP flag
                          tag,         //  [48:44] — request tag
                          addr,        //  [43:17] — byte address / status
                          be,          //  [16:9]  — byte enables
                          9'h0};       //  [8:0]   — reserved

    // 50-bit payload for message packets
    // Concatenation order: MSB first → LSB last, total = 6+16+8+8+12 = 50
    logic [49:0] payload_msg;
    assign payload_msg = {6'h0,        //  [49:44] — reserved (covers Tag field)
                          msginfo,     //  [43:28] — MsgInfo[15:0]
                          msgcode,     //  [27:20] — MsgCode[7:0]
                          msgsubcode,  //  [19:12] — MsgSubcode[7:0]
                          12'h0};      //  [11:0]  — reserved

    // Mux between the two 50-bit payload variants
    // is_msg selects the message layout; all other packet types use reg layout
    logic [49:0] payload_sel;
    assign payload_sel = is_msg ? payload_msg : payload_reg;

    // ========================================================================
    // Step 3 — Assemble the raw 64-bit header (CP=0, DP=0)
    //
    // Concatenation: 5+3+3+1+1+1+50 = 64 bits exactly.
    //   opcode  [63:59]  5 bits
    //   srcid   [58:56]  3 bits
    //   dstid   [55:53]  3 bits
    //   CP      [52]     1 bit  — forced 0, computed parity inserted later
    //   DP      [51]     1 bit  — forced 0, computed parity inserted later
    //   Cr      [50]     1 bit
    //   payload [49:0]  50 bits — type-specific mux result
    // ========================================================================

    logic [63:0] hdr_raw;
    assign hdr_raw = {opcode,       //  [63:59]  5 bits
                      srcid,        //  [58:56]  3 bits
                      dstid,        //  [55:53]  3 bits
                      1'b0,         //  [52]     CP placeholder = 0
                      1'b0,         //  [51]     DP placeholder = 0
                      cr,           //  [50]     credit-return
                      payload_sel}; //  [49:0]   type-specific fields

    // ========================================================================
    // Step 4 — Compute CP and DP via lphy_sb_crc
    //
    // The CRC module is instantiated in TX mode (mode_tx=1).
    // It receives hdr_raw (with CP=0, DP=0 already in place — guaranteed by
    // the concatenation in Step 3) and computes:
    //   cp_computed = XOR-reduce( hdr_raw & PARITY_CLEAR_MASK )
    //   dp_computed = XOR-reduce( data_in )  if has_data=1, else 0
    //
    // parity_err from lphy_sb_crc is always 0 in TX mode and is not used.
    // ========================================================================

    logic cp_computed;  // computed Control Parity from lphy_sb_crc
    logic dp_computed;  // computed Data Parity from lphy_sb_crc
    logic crc_unused;   // parity_err — always 0 in TX mode (suppress lint)

    lphy_sb_crc u_crc (
        .hdr_in    (hdr_raw),       // header with CP=0, DP=0
        .data_in   (data_in),       // payload (ignored when has_data=0)
        .has_data  (has_data),      // derived from opcode[0]
        .mode_tx   (1'b1),          // always TX / encode
        .cp_out    (cp_computed),   // computed CP
        .dp_out    (dp_computed),   // computed DP
        .parity_err(crc_unused)     // unused in TX mode
    );

    // ========================================================================
    // Step 5 — Insert computed CP and DP into the final header
    //
    // Bit-field insertion via bitwise OR with mask constants:
    //   If cp_computed=1 : OR with CP_MASK sets bit 52
    //   If cp_computed=0 : OR with 64'h0 leaves bit 52 = 0 (already 0)
    //   Same logic for dp_computed / DP_MASK
    //
    // This is equivalent to:
    //   hdr_out = hdr_raw;
    //   hdr_out[52] = cp_computed;
    //   hdr_out[51] = dp_computed;
    // but avoids any LHS bit-select on a localparam index.
    // ========================================================================

    logic [63:0] hdr_with_cp;

    // Insert CP first
    assign hdr_with_cp = hdr_raw | (cp_computed ? CP_MASK : 64'h0);

    // Insert DP into the CP-updated header
    assign hdr_out     = hdr_with_cp | (dp_computed ? DP_MASK : 64'h0);

    // ========================================================================
    // Step 6 — Drive remaining outputs
    //
    // data_out: pass-through of data_in when has_data=1; zero otherwise.
    //   Tying data_out to 0 for no-data packets is a clean practice that
    //   prevents undefined-value propagation in the TX serializer.
    //
    // two_frame_pkt: directly equals has_data.
    //   0 → TX serializer sends one 64-bit frame (header only)
    //   1 → TX serializer sends two 64-bit frames (header + data)
    //
    // enc_cp_out, enc_dp_out: the computed parity bits, exposed for the
    //   testbench to verify independently without reading into hdr_out.
    // ========================================================================

    assign data_out     = has_data ? data_in : 64'h0;
    assign two_frame_pkt = has_data;
    assign enc_cp_out   = cp_computed;
    assign enc_dp_out   = dp_computed;

    // ========================================================================
    // Simulation-only: parameter consistency check
    // ========================================================================

    // synthesis translate_off
    initial begin : param_check
        if (CP_MASK !== (64'h1 << CP_BIT))
            $fatal(1, "[lphy_sb_pkt_enc] CP_MASK mismatch CP_BIT=%0d", CP_BIT);
        if (DP_MASK !== (64'h1 << DP_BIT))
            $fatal(1, "[lphy_sb_pkt_enc] DP_MASK mismatch DP_BIT=%0d", DP_BIT);
    end
    // synthesis translate_on

endmodule : lphy_sb_pkt_enc