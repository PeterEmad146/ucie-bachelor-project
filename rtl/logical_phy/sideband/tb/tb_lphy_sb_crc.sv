// ============================================================================
// Testbench : tb_lphy_sb_crc
// DUT       : lphy_sb_crc
// File      : tb_lphy_sb_crc.sv
//
// ============================================================================
// PURPOSE
// -------
// Verifies the UCIe sideband Control Parity (CP) and Data Parity (DP) module
// through a structured set of directed and random test cases.
//
// Test Groups:
//   A — TX / Encode mode: correct CP and DP computation
//   B — RX / Check mode: clean (uncorrupted) packets → parity_err = 0
//   C — RX / Check mode: corrupted packets → parity_err = 1
//   D — Mask integrity: TX-with-CP-set-in-header (safety-net test)
//   E — Random stress: 50 random TX→RX round-trips + single-bit flip
//
// ============================================================================
// TIMING DIAGRAM (combinational DUT — no clocks required)
// ---------------------------------------------------------
// Inputs change; after #1 ns propagation delay, outputs are sampled.
//
//   t(ns)  0    1    2    3    4    5    6    7    8    9   10 ...
//          |    |    |    |    |    |    |    |    |    |    |
// hdr_in   <-A1------><-A2------><-A3------><-A4------><-A5-->
// data_in  <-0  ------><-D2-----><-D3------><-0  ------><-0 ->
// has_data ____00000______11111______11111______00000______0___
// mode_tx  ____11111______11111______11111______11111______1___
//
// cp_out   <  cA1  >  <  cA2  >  <  cA3  >  <   0  >  <  1 >
// dp_out   <   0   >  <  dA2  >  <  dA3  >  <   0  >  <  0 >
// parity_err          0             0             0          0
//
// (Each input vector held for 1 ns; outputs sampled after #1 settle time.)
//
// ============================================================================
// HOW TO RUN (iverilog)
// ---------------------
//   iverilog -g2012 -o sim.out tb_lphy_sb_crc.sv lphy_sb_crc.sv
//   vvp sim.out
//   gtkwave tb_lphy_sb_crc.vcd   (optional waveform view)
//
// ============================================================================

`timescale 1ns / 1ps

module tb_lphy_sb_crc;

    // ====================================================================
    // DUT port connections
    // ====================================================================

    logic [63:0] hdr_in;
    logic [63:0] data_in;
    logic        has_data;
    logic        mode_tx;

    logic        cp_out;
    logic        dp_out;
    logic        parity_err;

    // ====================================================================
    // Bit-position constants — must match lphy_sb_crc.sv localparam values
    // ====================================================================

    localparam int unsigned CP_BIT = 52;
    localparam int unsigned DP_BIT = 51;

    // Convenience masks for building and inspecting headers
    localparam logic [63:0] CP_MASK          = 64'h0010_0000_0000_0000;
    localparam logic [63:0] DP_MASK          = 64'h0008_0000_0000_0000;
    localparam logic [63:0] PARITY_CLEAR_MASK = 64'hFFE7_FFFF_FFFF_FFFF;

    // ====================================================================
    // Test bookkeeping
    // ====================================================================

    int pass_count = 0;
    int fail_count = 0;

    // ====================================================================
    // DUT instantiation
    // ====================================================================

    lphy_sb_crc u_dut (
        .hdr_in    (hdr_in),
        .data_in   (data_in),
        .has_data  (has_data),
        .mode_tx   (mode_tx),
        .cp_out    (cp_out),
        .dp_out    (dp_out),
        .parity_err(parity_err)
    );

    // ====================================================================
    // Reference model (independent reimplementation in the testbench)
    //
    // This is the "golden" expected-output computation.  It is intentionally
    // written differently from the DUT (uses a function, not assigns) so that
    // a common coding mistake in one would not appear in the other.
    // ====================================================================

    function automatic logic ref_cp (
        input logic [63:0] h,
        input logic [63:0] d,
        input logic        has_d
    );
        // Mirror the DUT: mask bits 52 and 51 before XOR-reducing
        logic [63:0] hm;
        hm       = h & PARITY_CLEAR_MASK;
        return ^hm;
    endfunction

    function automatic logic ref_dp (
        input logic [63:0] d,
        input logic        has_d
    );
        return has_d ? (^d) : 1'b0;
    endfunction

    // ====================================================================
    // Helper: apply inputs and wait for combinational settling
    // ====================================================================

    task automatic apply (
        input logic [63:0] h,
        input logic [63:0] d,
        input logic        hd,
        input logic        tx
    );
        hdr_in   = h;
        data_in  = d;
        has_data = hd;
        mode_tx  = tx;
        #1;   // 1 ns settle for combinational logic
    endtask

    // ====================================================================
    // Helper: check TX-mode outputs against reference model
    // ====================================================================

    task automatic check_tx (
        input string       name,
        input logic [63:0] h,
        input logic [63:0] d,
        input logic        hd
    );
        logic exp_cp, exp_dp;
        exp_cp = ref_cp(h, d, hd);
        exp_dp = ref_dp(d, hd);

        // parity_err must be 0 in TX mode
        if (parity_err !== 1'b0) begin
            $display("  FAIL [%s] parity_err=%b in TX mode (must be 0)", name, parity_err);
            fail_count++;
        end else pass_count++;

        // cp_out must match reference
        if (cp_out !== exp_cp) begin
            $display("  FAIL [%s] cp_out=%b expected=%b  hdr=0x%016h",
                     name, cp_out, exp_cp, h);
            fail_count++;
        end else pass_count++;

        // dp_out must match reference
        if (dp_out !== exp_dp) begin
            $display("  FAIL [%s] dp_out=%b expected=%b  data=0x%016h has_data=%b",
                     name, dp_out, exp_dp, d, hd);
            fail_count++;
        end else pass_count++;

        $display("  TX [%s] hdr=0x%016h data=0x%016h has_data=%b → cp=%b dp=%b err=%b  [%s]",
                 name, h, d, hd, cp_out, dp_out, parity_err,
                 (fail_count==0 ||
                  (cp_out===exp_cp && dp_out===exp_dp && parity_err===1'b0))
                   ? "PASS" : "FAIL");
    endtask

    // ====================================================================
    // Helper: build RX header by inserting computed CP and DP
    // ====================================================================

    function automatic logic [63:0] make_rx_hdr (
        input logic [63:0] base_hdr,  // header with CP=0, DP=0
        input logic        cp_val,
        input logic        dp_val
    );
        logic [63:0] r;
        r = base_hdr & PARITY_CLEAR_MASK;  // ensure bits 52/51 are clean
        if (cp_val) r = r | CP_MASK;       // set CP if needed
        if (dp_val) r = r | DP_MASK;       // set DP if needed
        return r;
    endfunction

    // ====================================================================
    // Helper: check RX-mode clean packet (expect parity_err = 0)
    // ====================================================================

    task automatic check_rx_ok (
        input string       name,
        input logic [63:0] h,
        input logic [63:0] d,
        input logic        hd
    );
        if (parity_err !== 1'b0) begin
            $display("  FAIL [%s] parity_err=1 for valid packet  hdr=0x%016h", name, h);
            fail_count++;
        end else pass_count++;

        $display("  RX [%s] hdr=0x%016h data=0x%016h → err=%b  [%s]",
                 name, h, d, parity_err, (parity_err===1'b0) ? "PASS" : "FAIL");
    endtask

    // ====================================================================
    // Helper: check RX-mode corrupted packet (expect parity_err = 1)
    // ====================================================================

    task automatic check_rx_err (
        input string       name,
        input logic [63:0] h,
        input logic [63:0] d,
        input logic        hd
    );
        if (parity_err !== 1'b1) begin
            $display("  FAIL [%s] parity_err=0 for corrupted packet (should be 1)  hdr=0x%016h",
                     name, h);
            fail_count++;
        end else pass_count++;

        $display("  RX [%s] hdr=0x%016h data=0x%016h → err=%b  [%s]",
                 name, h, d, parity_err, (parity_err===1'b1) ? "PASS" : "FAIL");
    endtask

    // ====================================================================
    // Variables to share TX results across test groups
    // ====================================================================

    logic [63:0] hdr_a1, hdr_a2, hdr_a3;
    logic [63:0] dat_a2,  dat_a3;
    logic        cp_a1, dp_a1;
    logic        cp_a2, dp_a2;
    logic        cp_a3, dp_a3;

    // ====================================================================
    // MAIN TEST SEQUENCE
    // ====================================================================

    initial begin

        // Initialise all inputs
        hdr_in = '0; data_in = '0; has_data = 0; mode_tx = 1;
        #2;

        $display("");
        $display("=============================================================");
        $display("  lphy_sb_crc Testbench — UCIe §6.1.2 / §6.1.3.2");
        $display("=============================================================");

        // ================================================================
        // GROUP A — TX / Encode
        // ================================================================
        $display("");
        $display("--- Group A : TX / Encode mode ---");

        // ----------------------------------------------------------------
        // A1 : Message without payload (opcode=10010b, srcid=010, dstid=101)
        //      MsgCode=A5h (MBINIT.REPAIRCLK init req, Table 54)
        //      CP[52]=0, DP[51]=0 pre-zeroed by caller as required
        // ----------------------------------------------------------------
        begin
            hdr_a1 = 64'h0;
            hdr_a1[63:59] = 5'b10010;   // message without data
            hdr_a1[58:56] = 3'b010;     // srcid: Physical Layer
            hdr_a1[55:53] = 3'b101;     // dstid: remote, Adapter
            // bits 52 and 51 remain 0
            hdr_a1[27:20] = 8'hA5;      // MsgCode
            hdr_a1[19:12] = 8'h03;      // MsgSubcode
            apply(hdr_a1, 64'h0, 1'b0, 1'b1);
            check_tx("A1-NoPayload", hdr_a1, 64'h0, 1'b0);
            cp_a1 = cp_out;  dp_a1 = dp_out;
        end

        // ----------------------------------------------------------------
        // A2 : 32-bit Memory Write (opcode=00001b) with 32-bit payload
        //      srcid=001 (Adapter), Tag=5, Addr=27'h0001000, BE=8'h0F
        //      data = 32'hDEAD_BEEF zero-padded to 64 bits
        // ----------------------------------------------------------------
        begin
            hdr_a2 = 64'h0;
            hdr_a2[63:59] = 5'b00001;           // 32b memory write
            hdr_a2[58:56] = 3'b001;             // srcid: D2D Adapter
            hdr_a2[55:53] = 3'b110;             // dstid: remote PHY
            hdr_a2[48:44] = 5'b00101;           // Tag = 5
            hdr_a2[43:17] = 27'h000_1000;       // Addr
            hdr_a2[16: 9] = 8'h0F;              // BE: lower 4 bytes
            dat_a2 = 64'h0000_0000_DEAD_BEEF;   // 32b payload, zero-padded
            apply(hdr_a2, dat_a2, 1'b1, 1'b1);
            check_tx("A2-MemWrite32", hdr_a2, dat_a2, 1'b1);
            cp_a2 = cp_out;  dp_a2 = dp_out;
        end

        // ----------------------------------------------------------------
        // A3 : Message with 64-bit payload ({AdvCap.Adapter}, Table 55)
        //      opcode=11011b, srcid=001, dstid=101
        //      MsgCode=01h, capabilities = Raw|68B|PCIe|Streaming|Retry
        // ----------------------------------------------------------------
        begin
            hdr_a3 = 64'h0;
            hdr_a3[63:59] = 5'b11011;           // message with 64b data
            hdr_a3[58:56] = 3'b001;             // srcid: D2D Adapter
            hdr_a3[55:53] = 3'b101;             // dstid: remote Adapter
            hdr_a3[27:20] = 8'h01;              // MsgCode: AdvCap.Adapter
            hdr_a3[19:12] = 8'h00;              // MsgSubcode: 00h
            dat_a3 = 64'h0000_0000_0000_003F;   // capability bits [5:0]
            apply(hdr_a3, dat_a3, 1'b1, 1'b1);
            check_tx("A3-AdvCapAdapter", hdr_a3, dat_a3, 1'b1);
            cp_a3 = cp_out;  dp_a3 = dp_out;
        end

        // ----------------------------------------------------------------
        // A4 : All-zero header — XOR of 64 zeros = 0 → cp=0, dp=0
        // ----------------------------------------------------------------
        apply(64'h0, 64'h0, 1'b0, 1'b1);
        check_tx("A4-AllZero", 64'h0, 64'h0, 1'b0);

        // ----------------------------------------------------------------
        // A5 : All header bits set except CP[52] and DP[51] (=0 as required)
        //      62 ones → even count → XOR = 0 → cp_out = 0
        //      64 ones in data (has_data=1) → even count → dp_out = 0
        // ----------------------------------------------------------------
        begin : blk_a5
            logic [63:0] h5;
            h5 = 64'hFFFF_FFFF_FFFF_FFFF & PARITY_CLEAR_MASK;
            apply(h5, 64'hFFFF_FFFF_FFFF_FFFF, 1'b1, 1'b1);
            check_tx("A5-AllOnes-ExceptParity", h5, 64'hFFFF_FFFF_FFFF_FFFF, 1'b1);
        end

        // ----------------------------------------------------------------
        // A6 : Single bit set in header (bit 0 only) — cp=1, dp=0
        // ----------------------------------------------------------------
        apply(64'h0000_0000_0000_0001, 64'h0, 1'b0, 1'b1);
        check_tx("A6-SingleBitHdr", 64'h0000_0000_0000_0001, 64'h0, 1'b0);

        // ----------------------------------------------------------------
        // A7 : Single bit set in payload (bit 0) — cp=0, dp=1
        // ----------------------------------------------------------------
        apply(64'h0, 64'h0000_0000_0000_0001, 1'b1, 1'b1);
        check_tx("A7-SingleBitData", 64'h0, 64'h0000_0000_0000_0001, 1'b1);

        // ================================================================
        // GROUP B — RX clean round-trips
        // ================================================================
        $display("");
        $display("--- Group B : RX / Check mode (valid packets — expect err=0) ---");

        begin : blk_b1
            logic [63:0] rh;
            rh = make_rx_hdr(hdr_a1, cp_a1, dp_a1);
            apply(rh, 64'h0, 1'b0, 1'b0);
            check_rx_ok("B1-RoundTrip-A1", rh, 64'h0, 1'b0);
        end

        begin : blk_b2
            logic [63:0] rh;
            rh = make_rx_hdr(hdr_a2, cp_a2, dp_a2);
            apply(rh, dat_a2, 1'b1, 1'b0);
            check_rx_ok("B2-RoundTrip-A2", rh, dat_a2, 1'b1);
        end

        begin : blk_b3
            logic [63:0] rh;
            rh = make_rx_hdr(hdr_a3, cp_a3, dp_a3);
            apply(rh, dat_a3, 1'b1, 1'b0);
            check_rx_ok("B3-RoundTrip-A3", rh, dat_a3, 1'b1);
        end

        // ================================================================
        // GROUP C — RX corrupted packets (expect err=1)
        // ================================================================
        $display("");
        $display("--- Group C : RX / Check mode (corrupted — expect err=1) ---");

        // ----------------------------------------------------------------
        // C1 : Single bit flip in opcode field (bit 63)
        // ----------------------------------------------------------------
        begin : blk_c1
            logic [63:0] rh;
            rh = make_rx_hdr(hdr_a2, cp_a2, dp_a2);
            rh[63] = ~rh[63];            // corrupt opcode MSB
            apply(rh, dat_a2, 1'b1, 1'b0);
            check_rx_err("C1-OpcodeFlip", rh, dat_a2, 1'b1);
        end

        // ----------------------------------------------------------------
        // C2 : CP bit itself flipped in the received header
        // ----------------------------------------------------------------
        begin : blk_c2
            logic [63:0] rh;
            rh = make_rx_hdr(hdr_a2, cp_a2, dp_a2);
            rh = rh ^ CP_MASK;           // flip bit 52
            apply(rh, dat_a2, 1'b1, 1'b0);
            check_rx_err("C2-CPBitFlip", rh, dat_a2, 1'b1);
        end

        // ----------------------------------------------------------------
        // C3 : DP bit itself flipped in the received header
        // ----------------------------------------------------------------
        begin : blk_c3
            logic [63:0] rh;
            rh = make_rx_hdr(hdr_a2, cp_a2, dp_a2);
            rh = rh ^ DP_MASK;           // flip bit 51
            apply(rh, dat_a2, 1'b1, 1'b0);
            check_rx_err("C3-DPBitFlip", rh, dat_a2, 1'b1);
        end

        // ----------------------------------------------------------------
        // C4 : Single bit flip in data payload (bit 0)
        //      Header valid; only DP should fail
        // ----------------------------------------------------------------
        begin : blk_c4
            logic [63:0] rh, rd;
            rh = make_rx_hdr(hdr_a2, cp_a2, dp_a2);
            rd = dat_a2 ^ 64'h1;         // flip payload bit 0
            apply(rh, rd, 1'b1, 1'b0);
            check_rx_err("C4-DataPayloadFlip", rh, rd, 1'b1);
        end

        // ----------------------------------------------------------------
        // C5 : Bit flip in bit 0 of header (low-order, not CP or DP)
        // ----------------------------------------------------------------
        begin : blk_c5
            logic [63:0] rh;
            rh = make_rx_hdr(hdr_a2, cp_a2, dp_a2);
            rh[0] = ~rh[0];              // flip bit 0 (single odd flip → detected)
            apply(rh, dat_a2, 1'b1, 1'b0);
            check_rx_err("C5-Bit0Flip", rh, dat_a2, 1'b1);
        end

        // ----------------------------------------------------------------
        // C6 : Two-bit flip in header (even count — UNDETECTABLE by design)
        //      Even parity cannot detect an even number of bit errors.
        //      This is a known fundamental limitation of single-bit parity.
        //      We verify err = 0 here to document the expected blind spot.
        // ----------------------------------------------------------------
        begin : blk_c6
            logic [63:0] rh;
            rh    = make_rx_hdr(hdr_a2, cp_a2, dp_a2);
            rh[0] = ~rh[0];   // flip bit 0
            rh[1] = ~rh[1];   // flip bit 1 → even count, XOR net = 0

            apply(rh, dat_a2, 1'b1, 1'b0);
            if (parity_err !== 1'b0) begin
                $display("  FAIL [C6-EvenFlip] expected err=0 (even parity limit), got err=1");
                fail_count++;
            end else begin
                $display("  RX [C6-EvenFlip] Double-bit flip correctly UNDETECTED (err=0) — known even-parity limitation  [PASS]");
                pass_count++;
            end
        end

        // ----------------------------------------------------------------
        // C7 : Payload corrupted when has_data=0 — must NOT raise error
        //      When no data is expected, DP is always 0; the payload
        //      content is irrelevant and must be silently ignored.
        // ----------------------------------------------------------------
        begin : blk_c7
            logic [63:0] rh;
            rh = make_rx_hdr(hdr_a1, cp_a1, dp_a1);   // no-data message
            // dp_a1 = 0 because A1 had no payload
            apply(rh, 64'hDEAD_BEEF_CAFE_1234, 1'b0, 1'b0);
            if (parity_err !== 1'b0) begin
                $display("  FAIL [C7-IgnoredPayload] err=1 but has_data=0 (payload must be ignored)");
                fail_count++;
            end else begin
                $display("  RX [C7-IgnoredPayload] Garbage data ignored correctly (err=0)  [PASS]");
                pass_count++;
            end
        end

        // ================================================================
        // GROUP D — Mask integrity tests
        //
        // These tests prove that the PARITY_CLEAR_MASK correctly strips
        // CP and DP before the XOR reduction.  The scenario: a header where
        // the caller ACCIDENTALLY left CP=1 or DP=1 set.  The mask must
        // remove those bits so the computed parity is still correct.
        //
        // This is the critical regression test for the iverilog-v1.0 bug
        // where the masking could have been silently skipped.
        // ================================================================
        $display("");
        $display("--- Group D : Mask integrity (CP/DP pre-set in hdr_in) ---");

        // ----------------------------------------------------------------
        // D1 : TX mode with CP[52]=1 accidentally left in hdr_in
        //      The mask must clear bit 52 before XOR-reduction.
        //      Expected: cp_out = ref_cp(hdr_with_CP_cleared, ...)
        //      i.e. cp_out == the correct parity of the DATA fields only.
        //
        //      Without the mask, bit 52 = 1 would corrupt the XOR.
        //      With the mask:   bit 52 = 0 → correct parity computed.
        // ----------------------------------------------------------------
        begin : blk_d1
            logic [63:0] h_dirty, h_clean;
            logic        exp_cp_clean, exp_cp_dirty;

            // Build a header with only data fields set (no CP/DP)
            h_clean = 64'h0;
            h_clean[63:59] = 5'b10010;
            h_clean[58:56] = 3'b010;
            h_clean[27:20] = 8'hA5;

            // Now "accidentally" set bit 52 (CP=1 in the input)
            h_dirty = h_clean | CP_MASK;   // bit 52 = 1

            // Expected CP: based on clean header (mask removes the dirty bit)
            exp_cp_clean = ref_cp(h_clean, 64'h0, 1'b0);   // what DUT should compute
            exp_cp_dirty = ^h_dirty;                        // what DUT would compute WITHOUT mask

            apply(h_dirty, 64'h0, 1'b0, 1'b1);

            $display("  D1 Setup: h_clean=0x%016h cp_if_no_mask=%b cp_with_mask=%b",
                     h_clean, exp_cp_dirty, exp_cp_clean);

            // The DUT masks bit 52 before XOR; result must equal exp_cp_clean
            if (cp_out !== exp_cp_clean) begin
                $display("  FAIL [D1-MaskCP] cp_out=%b expected=%b (mask did not clear CP bit)",
                         cp_out, exp_cp_clean);
                fail_count++;
            end else begin
                $display("  TX [D1-MaskCP] cp_out=%b correctly computed despite dirty bit 52  [PASS]",
                         cp_out);
                pass_count++;
            end
            // Also confirm it differs from the unmasked value (otherwise the
            // test would trivially pass even without the mask)
            if (exp_cp_clean === exp_cp_dirty) begin
                $display("  NOTE [D1] exp_cp_clean == exp_cp_dirty (%b) — test is not discriminating for this vector", exp_cp_clean);
            end else begin
                $display("  NOTE [D1] Discriminating: mask changes cp from %b to %b  [GOOD]",
                         exp_cp_dirty, exp_cp_clean);
                pass_count++;  // extra credit for discrimination
            end
        end

        // ----------------------------------------------------------------
        // D2 : TX mode with DP[51]=1 accidentally left in hdr_in
        //      Same scenario for the DP position.
        // ----------------------------------------------------------------
        begin : blk_d2
            logic [63:0] h_dirty, h_clean;
            logic        exp_cp_clean, exp_cp_dirty;

            h_clean = 64'h0;
            h_clean[63:59] = 5'b00001;
            h_clean[58:56] = 3'b001;
            h_clean[48:44] = 5'b00111;

            h_dirty = h_clean | DP_MASK;   // bit 51 = 1 (dirty)

            exp_cp_clean = ref_cp(h_clean, 64'h0, 1'b0);
            exp_cp_dirty = ^h_dirty;

            apply(h_dirty, 64'h0, 1'b0, 1'b1);

            if (cp_out !== exp_cp_clean) begin
                $display("  FAIL [D2-MaskDP] cp_out=%b expected=%b (mask did not clear DP bit)",
                         cp_out, exp_cp_clean);
                fail_count++;
            end else begin
                $display("  TX [D2-MaskDP] cp_out=%b correctly computed despite dirty bit 51  [PASS]",
                         cp_out);
                pass_count++;
            end
        end

        // ----------------------------------------------------------------
        // D3 : TX mode with BOTH CP[52]=1 and DP[51]=1 set in hdr_in
        //      Both bits must be cleared before XOR-reduction.
        // ----------------------------------------------------------------
        begin : blk_d3
            logic [63:0] h_dirty, h_clean;
            logic        exp_cp;

            h_clean = 64'h0;
            h_clean[63:59] = 5'b11011;
            h_clean[58:56] = 3'b001;
            h_clean[27:20] = 8'h02;

            h_dirty = h_clean | CP_MASK | DP_MASK;   // both bits 52 and 51 set

            exp_cp = ref_cp(h_clean, 64'h0, 1'b0);

            apply(h_dirty, 64'h0, 1'b0, 1'b1);

            if (cp_out !== exp_cp) begin
                $display("  FAIL [D3-MaskBoth] cp_out=%b expected=%b (mask did not clear both bits)",
                         cp_out, exp_cp);
                fail_count++;
            end else begin
                $display("  TX [D3-MaskBoth] cp_out=%b correct with both bits 52+51 pre-set  [PASS]",
                         cp_out);
                pass_count++;
            end
        end

        // ================================================================
        // GROUP E — Random stress: 50 TX→RX round-trips + single-bit flips
        // ================================================================
        $display("");
        $display("--- Group E : Random stress (50 vectors × 2 checks = 100) ---");

        begin : blk_random
            logic [63:0] rnd_h, rnd_d, rx_h, rx_h_bad;
            logic        rnd_hd, rnd_cp, rnd_dp;
            int          flip_bit, i;

            for (i = 0; i < 50; i++) begin

                // Random header with CP and DP pre-zeroed (correct caller behaviour)
                rnd_h = {$random, $random} & PARITY_CLEAR_MASK;
                rnd_d = {$random, $random};
                rnd_hd = $random;

                // ---- TX encode ----
                apply(rnd_h, rnd_d, rnd_hd, 1'b1);
                rnd_cp = cp_out;
                rnd_dp = dp_out;

                // ---- RX check — clean ----
                rx_h = make_rx_hdr(rnd_h, rnd_cp, rnd_dp);
                apply(rx_h, rnd_d, rnd_hd, 1'b0);
                if (parity_err !== 1'b0) begin
                    $display("  FAIL [E-clean-%0d] parity_err=1 on clean round-trip", i);
                    fail_count++;
                end else pass_count++;

                // ---- RX check — one-bit flip (bits 0..49 exclude CP/DP) ----
                flip_bit   = $urandom_range(0, 49);
                rx_h_bad   = rx_h;
                rx_h_bad[0 +: 1] = rx_h_bad[0 +: 1] ^ 1'b1;  // flip bit 0 always works
                // Flip a specific bit using XOR with a shifted mask
                rx_h_bad = rx_h ^ (64'h1 << flip_bit);
                apply(rx_h_bad, rnd_d, rnd_hd, 1'b0);
                if (parity_err !== 1'b1) begin
                    $display("  FAIL [E-flip-%0d] bit %0d flip not detected (parity_err=0)",
                             i, flip_bit);
                    fail_count++;
                end else pass_count++;

            end
            $display("  Random stress complete: %0d vectors tested", 50);
        end

        // ================================================================
        // FINAL SUMMARY
        // ================================================================
        $display("");
        $display("=============================================================");
        $display("  TEST SUMMARY");
        $display("  Passed : %0d", pass_count);
        $display("  Failed : %0d", fail_count);
        $display("  Total  : %0d", pass_count + fail_count);
        $display("  Result : %s",
                 (fail_count == 0) ? "*** ALL PASS ***"
                                   : "!!! FAILURES DETECTED !!!");
        $display("=============================================================");
        $display("");

        if (fail_count != 0)
            $fatal(1, "Testbench FAILED with %0d error(s)", fail_count);

        $finish;

    end // initial

    // ====================================================================
    // Watchdog: kill simulation if it hangs (safety net)
    // ====================================================================

    initial begin
        #500_000;
        $fatal(1, "[WATCHDOG] Simulation exceeded 500 us — aborting.");
    end

    // ====================================================================
    // Waveform dump (open with gtkwave tb_lphy_sb_crc.vcd)
    // ====================================================================

    initial begin
        $dumpfile("tb_lphy_sb_crc.vcd");
        $dumpvars(0, tb_lphy_sb_crc);
    end

endmodule : tb_lphy_sb_crc