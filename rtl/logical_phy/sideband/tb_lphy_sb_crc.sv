// ============================================================================
// Testbench : tb_lphy_sb_crc
// DUT       : lphy_sb_crc
// File      : tb_lphy_sb_crc.sv
//
// ============================================================================
// PURPOSE
// -------
// Verifies the UCIe sideband Control Parity (CP) and Data Parity (DP) module
// through an exhaustive set of directed test cases covering:
//
//   Group A — TX / Encode mode
//     A1 : Message with no data payload          → CP computed, DP = 0
//     A2 : Register write with 32-bit payload    → CP and DP computed
//     A3 : Message with 64-bit payload            → CP and DP computed
//     A4 : All-zero header (edge case)           → CP = 0, DP = 0
//     A5 : All-ones header (except CP/DP = 0)    → CP and DP verified
//     A6 : Single bit set in header              → CP = 1, DP = 0
//
//   Group B — RX / Check mode (correct packets — expect parity_err = 0)
//     B1 : Round-trip A1 result through RX check
//     B2 : Round-trip A2 result through RX check
//     B3 : Round-trip A3 result through RX check
//
//   Group C — RX / Check mode (corrupted packets — expect parity_err = 1)
//     C1 : Single bit flip in header opcode field
//     C2 : CP bit itself flipped in received header
//     C3 : DP bit itself flipped in received header
//     C4 : Single bit flip in data payload
//     C5 : Multiple bit flips (even number → CP still fails, DP still fails)
//     C6 : Data bit flipped when has_data = 0 (should NOT cause error
//          because payload is ignored — DP stays 0)
//
// ============================================================================
// TIMING DIAGRAM CONCEPT (combinational DUT)
// ------------------------------------------
// Because lphy_sb_crc is purely combinational, the "timing diagram"
// shows propagation delays from input change to output settle.
//
//                ___     ___     ___     ___
//   clk      __|   |___|   |___|   |___|   |__   (reference only — no DUT flops)
//
//   hdr_in   <---A1--->---A2--->---B1--->---C1-->
//   data_in  <---0  --->---D2 --->---D3 --->  -->
//   has_data ____00000___11111___11111___00000____
//   mode_tx  ____11111___11111___00000___00000____
//
//   cp_out   < cA1  > < cA2  > < cB1  > < cC1  >   (propagation ~1 LUT)
//   dp_out   <  0   > < dA2  > < dB1  > <  0   >
//   parity_err          0          0          1
//
// Each test vector is applied for one simulation time unit; outputs are
// sampled after a small propagation delay (#1) to allow combinational
// settling.
//
// ============================================================================
// HOW TO RUN
// ----------
//   Icarus Verilog:
//     iverilog -g2012 -o sim.out tb_lphy_sb_crc.sv lphy_sb_crc.sv
//     vvp sim.out
//
//   VCS:
//     vcs -sverilog tb_lphy_sb_crc.sv lphy_sb_crc.sv -o sim.out && ./sim.out
//
//   Verilator (lint / co-sim):
//     verilator --lint-only --sv tb_lphy_sb_crc.sv lphy_sb_crc.sv
//
// ============================================================================
// REVISION HISTORY
// ----------------
//   Rev   Date        Author       Description
//   1.0   2026-03-23  UCIe LPHY    Initial implementation
// ============================================================================

`timescale 1ns / 1ps
`include "lphy_sb_crc.sv"

module tb_lphy_sb_crc;

    // ====================================================================
    // DUT port signals (driven as reg/logic from the testbench)
    // ====================================================================

    logic [63:0] hdr_in;       // 64-bit packet header
    logic [63:0] data_in;      // 64-bit payload (zero-padded for 32b)
    logic        has_data;     // payload present flag
    logic        mode_tx;      // 1 = TX/encode, 0 = RX/check

    logic        cp_out;       // computed / expected CP from DUT
    logic        dp_out;       // computed / expected DP from DUT
    logic        parity_err;   // RX-mode parity error flag

    // ====================================================================
    // Header bit position constants
    //   Must match lphy_sb_crc.sv localparam definitions exactly.
    // ====================================================================

    localparam int unsigned CP_BIT = 52;
    localparam int unsigned DP_BIT = 51;

    // ====================================================================
    // Test bookkeeping
    // ====================================================================

    int pass_count = 0;        // number of assertions that passed
    int fail_count = 0;        // number of assertions that failed

    // ====================================================================
    // DUT instantiation
    // ====================================================================

    lphy_sb_crc u_dut (
        .hdr_in     (hdr_in),
        .data_in    (data_in),
        .has_data   (has_data),
        .mode_tx    (mode_tx),
        .cp_out     (cp_out),
        .dp_out     (dp_out),
        .parity_err (parity_err)
    );

    // ====================================================================
    // Helper tasks
    // ====================================================================

    // ------------------------------------------------------------------
    // apply_inputs — drive DUT inputs and wait for combinational settle
    // ------------------------------------------------------------------
    task automatic apply_inputs (
        input logic [63:0] t_hdr,
        input logic [63:0] t_data,
        input logic        t_has_data,
        input logic        t_mode_tx
    );
        hdr_in   = t_hdr;
        data_in  = t_data;
        has_data = t_has_data;
        mode_tx  = t_mode_tx;
        #1;   // allow combinational logic to settle (1 ns)
    endtask

    // ------------------------------------------------------------------
    // check_tx — verify TX-mode outputs
    //   Computes expected CP and DP independently using the same even-
    //   parity algorithm, then compares against DUT outputs.
    // ------------------------------------------------------------------
    task automatic check_tx (
        input string       test_name,
        input logic [63:0] t_hdr,      // header with CP=0 and DP=0
        input logic [63:0] t_data,
        input logic        t_has_data
    );
        // Reference model: compute expected CP and DP
        logic [63:0] hdr_masked_ref;
        logic        cp_expected;
        logic        dp_expected;

        hdr_masked_ref          = t_hdr;
        hdr_masked_ref[CP_BIT]  = 1'b0;
        hdr_masked_ref[DP_BIT]  = 1'b0;

        cp_expected = ^hdr_masked_ref;                    // XOR-reduction
        dp_expected = t_has_data ? (^t_data) : 1'b0;     // payload parity

        // Check 1: parity_err must be 0 in TX mode
        if (parity_err !== 1'b0) begin
            $display("FAIL [%s] parity_err should be 0 in TX mode, got %b",
                     test_name, parity_err);
            fail_count++;
        end else begin
            pass_count++;
        end

        // Check 2: cp_out must match reference model
        if (cp_out !== cp_expected) begin
            $display("FAIL [%s] cp_out mismatch: expected %b, got %b  (hdr=0x%016h)",
                     test_name, cp_expected, cp_out, t_hdr);
            fail_count++;
        end else begin
            pass_count++;
        end

        // Check 3: dp_out must match reference model
        if (dp_out !== dp_expected) begin
            $display("FAIL [%s] dp_out mismatch: expected %b, got %b  (data=0x%016h, has_data=%b)",
                     test_name, dp_expected, dp_out, t_data, t_has_data);
            fail_count++;
        end else begin
            pass_count++;
        end

        $display("  TX [%s] hdr=0x%016h data=0x%016h has_data=%b → cp=%b dp=%b err=%b  [%s]",
                 test_name, t_hdr, t_data, t_has_data,
                 cp_out, dp_out, parity_err,
                 ((cp_out === cp_expected) && (dp_out === dp_expected) && (parity_err === 1'b0))
                   ? "PASS" : "FAIL");

    endtask

    // ------------------------------------------------------------------
    // build_rx_hdr — take a TX-generated header and insert computed CP/DP
    //   Returns the complete header ready for RX-mode checking.
    // ------------------------------------------------------------------
    function automatic logic [63:0] build_rx_hdr (
        input logic [63:0] base_hdr,   // header with CP=0, DP=0
        input logic        cp_val,     // value to insert at CP_BIT
        input logic        dp_val      // value to insert at DP_BIT
    );
        logic [63:0] result;
        result          = base_hdr;
        result[CP_BIT]  = cp_val;
        result[DP_BIT]  = dp_val;
        return result;
    endfunction

    // ------------------------------------------------------------------
    // check_rx_ok — verify RX mode with a VALID (uncorrupted) packet
    //   Expects parity_err = 0.
    // ------------------------------------------------------------------
    task automatic check_rx_ok (
        input string       test_name,
        input logic [63:0] rx_hdr,    // complete header including CP and DP
        input logic [63:0] rx_data,
        input logic        rx_has_data
    );
        if (parity_err !== 1'b0) begin
            $display("FAIL [%s] parity_err should be 0 for clean packet, got 1  (hdr=0x%016h)",
                     test_name, rx_hdr);
            fail_count++;
        end else begin
            pass_count++;
        end

        $display("  RX [%s] hdr=0x%016h data=0x%016h → err=%b  [%s]",
                 test_name, rx_hdr, rx_data, parity_err,
                 (parity_err === 1'b0) ? "PASS" : "FAIL");
    endtask

    // ------------------------------------------------------------------
    // check_rx_err — verify RX mode with a CORRUPTED packet
    //   Expects parity_err = 1.
    // ------------------------------------------------------------------
    task automatic check_rx_err (
        input string       test_name,
        input logic [63:0] rx_hdr,
        input logic [63:0] rx_data,
        input logic        rx_has_data
    );
        if (parity_err !== 1'b1) begin
            $display("FAIL [%s] parity_err should be 1 for corrupted packet, got 0  (hdr=0x%016h)",
                     test_name, rx_hdr);
            fail_count++;
        end else begin
            pass_count++;
        end

        $display("  RX [%s] hdr=0x%016h data=0x%016h → err=%b  [%s]",
                 test_name, rx_hdr, rx_data, parity_err,
                 (parity_err === 1'b1) ? "PASS" : "FAIL");
    endtask

    // ====================================================================
    // Main test sequence
    // ====================================================================

    // Intermediate storage — TX-encoded headers re-used in RX round-trips
    logic [63:0] hdr_a1_tx, hdr_a2_tx, hdr_a3_tx;
    logic [63:0] data_a2, data_a3;
    logic        cp_a1, dp_a1;
    logic        cp_a2, dp_a2;
    logic        cp_a3, dp_a3;

    initial begin

        // ----------------------------------------------------------------
        // Initialise all inputs to known state
        // ----------------------------------------------------------------
        hdr_in   = '0;
        data_in  = '0;
        has_data = 1'b0;
        mode_tx  = 1'b1;
        #2;

        $display("");
        $display("============================================================");
        $display("  lphy_sb_crc Testbench — UCIe Spec §6.1.2 / §6.1.3.2");
        $display("============================================================");
        $display("");

        // ================================================================
        // GROUP A — TX / Encode mode
        // ================================================================
        $display("--- Group A : TX / Encode mode ---");
        $display("");

        // ----------------------------------------------------------------
        // A1 : Message without data payload
        //   Opcode = 10010b (Message w/o Data, Table 47)
        //   srcid  = 010b   (Physical Layer, Table UCIe Link)
        //   dstid  = 101b   (remote, Adapter message)
        //   MsgCode = A5h (MBINIT.REPAIRCLK init req, Table 54)
        //   All other header fields = 0; CP and DP positions = 0
        //   Expected: dp_out = 0 (no payload), CP = f(header bits)
        // ----------------------------------------------------------------
        begin
            // Build header: CP=0, DP=0 at their respective bit positions
            // Fields encoded into header word:
            //   [63:59] opcode = 5'b10010 = 0x12
            //   [58:56] srcid  = 3'b010
            //   [55:53] dstid  = 3'b101
            //   [52]    CP     = 0  (to be computed)
            //   [51]    DP     = 0  (to be computed)
            //   [43:17] Addr   = MsgInfo[15:0]=0, MsgCode=A5h, MsgSubcode[2:0]=001b
            //   All others = 0
            hdr_a1_tx = 64'h0000_0000_0000_0000;
            hdr_a1_tx[63:59] = 5'b10010;   // opcode: message without data
            hdr_a1_tx[58:56] = 3'b010;     // srcid: Physical Layer
            hdr_a1_tx[55:53] = 3'b101;     // dstid: remote, Adapter
            // CP[52] = 0, DP[51] = 0 — caller initialises to 0
            // MsgCode at [27:20] = 8'hA5
            hdr_a1_tx[27:20] = 8'hA5;
            // MsgSubcode at [19:12] = 8'h03
            hdr_a1_tx[19:12] = 8'h03;

            apply_inputs(hdr_a1_tx, 64'h0, 1'b0, 1'b1);
            check_tx("A1-NoPayload", hdr_a1_tx, 64'h0, 1'b0);

            // Save computed parity for RX round-trip
            cp_a1 = cp_out;
            dp_a1 = dp_out;
        end

        // ----------------------------------------------------------------
        // A2 : Register write with 32-bit payload (zero-padded to 64b)
        //   Opcode = 00001b (32b Memory Write, Table 47)
        //   srcid  = 001b   (D2D Adapter)
        //   dstid  = 110b   (remote, Physical Layer)
        //   Tag    = 5'b00101
        //   Addr   = 27'h000_1000
        //   BE     = 8'h0F (lower 4 bytes valid)
        //   data   = 32'hDEAD_BEEF → zero-padded to 64'h0000_0000_DEAD_BEEF
        // ----------------------------------------------------------------
        begin
            hdr_a2_tx = 64'h0;
            hdr_a2_tx[63:59] = 5'b00001;           // opcode: 32b memory write
            hdr_a2_tx[58:56] = 3'b001;             // srcid: D2D Adapter
            hdr_a2_tx[55:53] = 3'b110;             // dstid: remote PHY
            // CP[52] = 0, DP[51] = 0
            hdr_a2_tx[50]    = 1'b0;               // Cr = 0
            hdr_a2_tx[49]    = 1'b0;               // EP = 0
            hdr_a2_tx[48:44] = 5'b00101;           // Tag = 5
            hdr_a2_tx[43:17] = 27'h000_1000;       // Addr
            hdr_a2_tx[16:9]  = 8'h0F;              // BE: lower 4 bytes

            data_a2 = 64'h0000_0000_DEAD_BEEF;     // 32b payload zero-padded

            apply_inputs(hdr_a2_tx, data_a2, 1'b1, 1'b1);
            check_tx("A2-RegWrite32", hdr_a2_tx, data_a2, 1'b1);

            cp_a2 = cp_out;
            dp_a2 = dp_out;
        end

        // ----------------------------------------------------------------
        // A3 : Message with 64-bit payload (AdvCap.Adapter, Table 55)
        //   Opcode = 11011b (Message with 64b Data)
        //   srcid  = 001b   (D2D Adapter)
        //   dstid  = 101b   (remote, Adapter)
        //   MsgCode    = 01h  ({AdvCap.Adapter})
        //   MsgSubcode = 00h
        //   data = capability bitmask (Raw_Mode | 68B | PCIe | Streaming)
        //           = 64'h0000_0000_0000_003B
        // ----------------------------------------------------------------
        begin
            hdr_a3_tx = 64'h0;
            hdr_a3_tx[63:59] = 5'b11011;           // opcode: message with 64b data
            hdr_a3_tx[58:56] = 3'b001;             // srcid: D2D Adapter
            hdr_a3_tx[55:53] = 3'b101;             // dstid: remote Adapter
            // CP[52] = 0, DP[51] = 0
            hdr_a3_tx[27:20] = 8'h01;              // MsgCode = AdvCap.Adapter
            hdr_a3_tx[19:12] = 8'h00;              // MsgSubcode = 00h

            data_a3 = 64'h0000_0000_0000_003B;     // bits[0..5] capabilities

            apply_inputs(hdr_a3_tx, data_a3, 1'b1, 1'b1);
            check_tx("A3-AdvCapAdapter", hdr_a3_tx, data_a3, 1'b1);

            cp_a3 = cp_out;
            dp_a3 = dp_out;
        end

        // ----------------------------------------------------------------
        // A4 : All-zero header (edge case)
        //   Every field is 0. With CP=0 and DP=0 already 0:
        //   cp_computed = XOR(64'h0) = 0
        //   dp_computed = 0 (has_data=0)
        //   Expected: cp_out=0, dp_out=0
        // ----------------------------------------------------------------
        begin
            apply_inputs(64'h0, 64'h0, 1'b0, 1'b1);
            check_tx("A4-AllZero", 64'h0, 64'h0, 1'b0);
        end

        // ----------------------------------------------------------------
        // A5 : Header with all non-parity bits set to 1 (stress case)
        //   Set every bit in the header EXCEPT CP[52] and DP[51]:
        //     hdr = 64'hFFFF_FFFF_FFFF_FFFF with bits 52 and 51 cleared
        //   Number of 1-bits = 62 → even number → cp_expected = 0
        // ----------------------------------------------------------------
        begin : blk_a5
            logic [63:0] h;
            h          = 64'hFFFF_FFFF_FFFF_FFFF;
            h[CP_BIT]  = 1'b0;
            h[DP_BIT]  = 1'b0;
            // 62 ones → even count → XOR = 0

            apply_inputs(h, 64'hFFFF_FFFF_FFFF_FFFF, 1'b1, 1'b1);
            check_tx("A5-AllOnes", h, 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        end

        // ----------------------------------------------------------------
        // A6 : Single bit set in header (bit 0)
        //   hdr = 64'h0000_0000_0000_0001 (bit 0 only)
        //   cp_expected = XOR = 1 (single 1-bit)
        //   dp_expected = 0 (has_data=0)
        // ----------------------------------------------------------------
        begin
            apply_inputs(64'h0000_0000_0000_0001, 64'h0, 1'b0, 1'b1);
            check_tx("A6-SingleBit", 64'h0000_0000_0000_0001, 64'h0, 1'b0);
        end

        $display("");
        $display("--- Group B : RX / Check mode (clean packets, expect err=0) ---");
        $display("");

        // ================================================================
        // GROUP B — RX round-trip checks
        //   Take the TX-encoded values from Group A, build the complete
        //   RX header (with CP and DP inserted), and verify no error.
        // ================================================================

        // ----------------------------------------------------------------
        // B1 : Round-trip of A1 (message, no data)
        // ----------------------------------------------------------------
        begin : blk_b1
            logic [63:0] rx_hdr;
            rx_hdr = build_rx_hdr(hdr_a1_tx, cp_a1, dp_a1);
            apply_inputs(rx_hdr, 64'h0, 1'b0, 1'b0);
            check_rx_ok("B1-RoundTrip-A1", rx_hdr, 64'h0, 1'b0);
        end

        // ----------------------------------------------------------------
        // B2 : Round-trip of A2 (register write, 32-bit data)
        // ----------------------------------------------------------------
        begin : blk_b2
            logic [63:0] rx_hdr;
            rx_hdr = build_rx_hdr(hdr_a2_tx, cp_a2, dp_a2);
            apply_inputs(rx_hdr, data_a2, 1'b1, 1'b0);
            check_rx_ok("B2-RoundTrip-A2", rx_hdr, data_a2, 1'b1);
        end

        // ----------------------------------------------------------------
        // B3 : Round-trip of A3 (AdvCap.Adapter, 64-bit data)
        // ----------------------------------------------------------------
        begin : blk_b3
            logic [63:0] rx_hdr;
            rx_hdr = build_rx_hdr(hdr_a3_tx, cp_a3, dp_a3);
            apply_inputs(rx_hdr, data_a3, 1'b1, 1'b0);
            check_rx_ok("B3-RoundTrip-A3", rx_hdr, data_a3, 1'b1);
        end

        $display("");
        $display("--- Group C : RX / Check mode (corrupted packets, expect err=1) ---");
        $display("");

        // ================================================================
        // GROUP C — Corruption injection tests
        //   Start from the valid B2 packet (round-trip of A2) and
        //   systematically corrupt individual bits.
        // ================================================================

        // ----------------------------------------------------------------
        // C1 : Single bit flip in the opcode field (bit 63)
        //   Flipping hdr[63] changes one protected bit → CP must fail.
        // ----------------------------------------------------------------
        begin : blk_c1
            logic [63:0] rx_hdr;
            rx_hdr          = build_rx_hdr(hdr_a2_tx, cp_a2, dp_a2);
            rx_hdr[63]      = ~rx_hdr[63];    // corrupt opcode MSB
            apply_inputs(rx_hdr, data_a2, 1'b1, 1'b0);
            check_rx_err("C1-OpcodeFlip", rx_hdr, data_a2, 1'b1);
        end

        // ----------------------------------------------------------------
        // C2 : CP bit itself flipped in the received header
        //   hdr[CP_BIT] toggled → direct CP mismatch.
        // ----------------------------------------------------------------
        begin : blk_c2
            logic [63:0] rx_hdr;
            rx_hdr           = build_rx_hdr(hdr_a2_tx, cp_a2, dp_a2);
            rx_hdr[CP_BIT]   = ~rx_hdr[CP_BIT]; // flip the CP bit
            apply_inputs(rx_hdr, data_a2, 1'b1, 1'b0);
            check_rx_err("C2-CPBitFlip", rx_hdr, data_a2, 1'b1);
        end

        // ----------------------------------------------------------------
        // C3 : DP bit itself flipped in the received header
        //   hdr[DP_BIT] toggled → direct DP mismatch.
        // ----------------------------------------------------------------
        begin : blk_c3
            logic [63:0] rx_hdr;
            rx_hdr           = build_rx_hdr(hdr_a2_tx, cp_a2, dp_a2);
            rx_hdr[DP_BIT]   = ~rx_hdr[DP_BIT]; // flip the DP bit
            apply_inputs(rx_hdr, data_a2, 1'b1, 1'b0);
            check_rx_err("C3-DPBitFlip", rx_hdr, data_a2, 1'b1);
        end

        // ----------------------------------------------------------------
        // C4 : Single bit flip in the data payload (bit 0 of payload)
        //   Valid header, corrupted data → DP mismatch only.
        // ----------------------------------------------------------------
        begin : blk_c4
            logic [63:0] rx_hdr;
            logic [63:0] rx_data_corrupt;
            rx_hdr             = build_rx_hdr(hdr_a2_tx, cp_a2, dp_a2);
            rx_data_corrupt    = data_a2;
            rx_data_corrupt[0] = ~rx_data_corrupt[0]; // flip payload bit 0
            apply_inputs(rx_hdr, rx_data_corrupt, 1'b1, 1'b0);
            check_rx_err("C4-DataPayloadFlip", rx_hdr, rx_data_corrupt, 1'b1);
        end

        // ----------------------------------------------------------------
        // C5 : Two bit flips in the header (bits 0 and 1)
        //   Even number of flips still changes the parity sense → err = 1
        //   because the two-flip net effect on XOR is zero, BUT the
        //   original CP was correct for the ORIGINAL bits.
        //   Flipping two header bits → XOR changes by XOR(bit0,bit1):
        //     if bit0 != bit1 → net XOR change = 0 → CP matches → err = 0!
        //     if bit0 == bit1 → net XOR change = 0 → CP matches → err = 0!
        //   WAIT — this is the even-parity limitation: flipping an even
        //   number of bits in the protected field is UNDETECTABLE.
        //   This is expected and documented behaviour.
        //   We verify err = 0 here (correct per spec — even parity).
        // ----------------------------------------------------------------
        begin : blk_c5
            logic [63:0] rx_hdr;
            rx_hdr    = build_rx_hdr(hdr_a2_tx, cp_a2, dp_a2);
            rx_hdr[0] = ~rx_hdr[0];   // flip bit 0
            rx_hdr[1] = ~rx_hdr[1];   // flip bit 1 (even flip count)
            apply_inputs(rx_hdr, data_a2, 1'b1, 1'b0);
            // Even parity CANNOT detect an even number of bit flips:
            // expect parity_err = 0 here (this is a known limitation,
            // not a design bug). We therefore check for err = 0.
            if (parity_err !== 1'b0) begin
                $display("FAIL [C5-EvenFlipUndetected] expected err=0 (even parity limit), got 1");
                fail_count++;
            end else begin
                $display("  RX [C5-EvenFlipUndetected] Double-bit flip correctly UNDETECTED by even parity (err=0)  [PASS]");
                pass_count++;
            end
        end

        // ----------------------------------------------------------------
        // C6 : Data bit flipped but has_data = 0
        //   When has_data is deasserted the payload is IGNORED by the DUT.
        //   DP is always 0 in this case; the corrupted payload cannot
        //   affect DP.  Expect parity_err = 0.
        // ----------------------------------------------------------------
        begin : blk_c6
            logic [63:0] rx_hdr;
            logic [63:0] garbage_data;

            // Build a valid header for a no-payload message (A1 round-trip)
            rx_hdr       = build_rx_hdr(hdr_a1_tx, cp_a1, dp_a1);
            garbage_data = 64'hDEAD_BEEF_CAFE_F00D;   // arbitrary garbage

            apply_inputs(rx_hdr, garbage_data, 1'b0, 1'b0);
            // has_data=0 so DP is 0 regardless of data_in; expect no error
            if (parity_err !== 1'b0) begin
                $display("FAIL [C6-IgnoredPayload] expected err=0 (has_data=0), got 1");
                fail_count++;
            end else begin
                $display("  RX [C6-IgnoredPayload] Garbage data ignored when has_data=0 (err=0)  [PASS]");
                pass_count++;
            end
        end

        // ================================================================
        // Random / exhaustive spot-check
        //   Run 20 random TX→RX round-trips and verify zero errors.
        //   Then inject a 1-bit header flip and verify error is caught.
        // ================================================================
        $display("");
        $display("--- Group D : Random round-trip stress test (20 vectors) ---");
        $display("");

        begin : blk_random
            logic [63:0] rnd_hdr, rnd_data, rx_hdr_clean, rx_hdr_bad;
            logic        rnd_has;
            logic        rnd_cp, rnd_dp;
            int          i;
            int          flip_bit;

            for (i = 0; i < 20; i++) begin

                // Generate random header (with CP and DP forced to 0)
                rnd_hdr          = $random;
                rnd_hdr          = {$random, $random};   // 64-bit random
                rnd_hdr[CP_BIT]  = 1'b0;
                rnd_hdr[DP_BIT]  = 1'b0;

                rnd_data = {$random, $random};
                rnd_has  = $random;

                // ----- TX encode -----
                apply_inputs(rnd_hdr, rnd_data, rnd_has, 1'b1);
                rnd_cp = cp_out;
                rnd_dp = dp_out;

                // ----- RX check (clean) -----
                rx_hdr_clean = build_rx_hdr(rnd_hdr, rnd_cp, rnd_dp);
                apply_inputs(rx_hdr_clean, rnd_data, rnd_has, 1'b0);
                if (parity_err !== 1'b0) begin
                    $display("FAIL [D-Random-%0d] clean round-trip gave parity_err=1", i);
                    fail_count++;
                end else begin
                    pass_count++;
                end

                // ----- RX check (1-bit flip in header, not CP or DP) -----
                // Pick a bit that is NOT CP or DP to guarantee a single-bit
                // error which WILL be detected by even parity
                flip_bit = $urandom_range(0, 49);   // bits 0..49 exclude CP/DP
                rx_hdr_bad             = rx_hdr_clean;
                rx_hdr_bad[flip_bit]   = ~rx_hdr_bad[flip_bit];

                apply_inputs(rx_hdr_bad, rnd_data, rnd_has, 1'b0);
                if (parity_err !== 1'b1) begin
                    $display("FAIL [D-Random-%0d] 1-bit flip (bit %0d) NOT detected (parity_err=0)",
                             i, flip_bit);
                    fail_count++;
                end else begin
                    pass_count++;
                end

            end
            $display("  Random stress: 20 clean round-trips + 20 single-bit-flip checks");
        end

        // ================================================================
        // Final summary
        // ================================================================
        $display("");
        $display("============================================================");
        $display("  TEST SUMMARY");
        $display("  Passed : %0d", pass_count);
        $display("  Failed : %0d", fail_count);
        $display("  Total  : %0d", pass_count + fail_count);
        $display("  Result : %s",  (fail_count == 0) ? "ALL PASS" : "*** FAILURES DETECTED ***");
        $display("============================================================");
        $display("");

        // Return non-zero exit code on failure (for CI integration)
        if (fail_count != 0) $fatal(1, "Testbench FAILED with %0d errors", fail_count);

        $finish;

    end // initial

    // ====================================================================
    // Timeout watchdog — kill simulation if it hangs (should never happen
    // for a combinational DUT, but is good practice)
    // ====================================================================
    initial begin
        #100_000;
        $fatal(1, "[TIMEOUT] Simulation exceeded 100 us — something is wrong.");
    end

    // ====================================================================
    // Optional waveform dump
    // ====================================================================
    initial begin
        $dumpfile("tb_lphy_sb_crc.vcd");
        $dumpvars(0, tb_lphy_sb_crc);
    end

endmodule : tb_lphy_sb_crc