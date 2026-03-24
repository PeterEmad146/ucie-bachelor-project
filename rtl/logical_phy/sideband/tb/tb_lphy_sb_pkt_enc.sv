// ============================================================================
// Testbench : tb_lphy_sb_pkt_enc
// DUT       : lphy_sb_pkt_enc
// File      : tb_lphy_sb_pkt_enc.sv
//
// ============================================================================
// PURPOSE
// -------
// Verifies the UCIe sideband packet encoder through directed and random tests.
//
// Test groups:
//   A — Opcode decode: two_frame_pkt for all 13 valid opcodes
//   B — Register access packets: field packing and parity
//   C — Completion packets: status convention and data
//   D — Message packets: msginfo/msgcode/msgsubcode layout
//   E — Data passthrough and gating
//   F — Parity cross-check against independent reference model
//   G — Random stress: 100 packets, 5 checks each
//
// ============================================================================
// IVERILOG COMPATIBILITY NOTES
// ----------------------------
//   - No unpacked structs (not supported)
//   - No 59'h0 etc. in concatenation — use full-width constants or {N{1'b0}}
//   - All local variables declared at module level or inside automatic tasks
//   - Static variable initialisation inside initial done with assignments
//
// ============================================================================
// HOW TO RUN
// ----------
//   iverilog -g2012 -Wall -o sim.out tb_lphy_sb_pkt_enc.sv \
//            lphy_sb_pkt_enc.sv lphy_sb_crc.sv
//   vvp sim.out
//
// ============================================================================
// REVISION HISTORY
// ----------------
//   Rev   Date        Author       Description
//   1.0   2026-03-23  UCIe LPHY    Initial implementation
//   1.1   2026-03-23  UCIe LPHY    Fixed for iverilog compatibility
// ============================================================================

`timescale 1ns / 1ps

module tb_lphy_sb_pkt_enc;

    // ====================================================================
    // DUT ports
    // ====================================================================

    logic [4:0]  opcode;
    logic [2:0]  srcid;
    logic [2:0]  dstid;
    logic        cr;
    logic        ep;
    logic [4:0]  tag;
    logic [26:0] addr;
    logic [7:0]  be;
    logic [15:0] msginfo;
    logic [7:0]  msgcode;
    logic [7:0]  msgsubcode;
    logic [63:0] data_in;

    logic [63:0] hdr_out;
    logic [63:0] data_out;
    logic        two_frame_pkt;
    logic        enc_cp_out;
    logic        enc_dp_out;

    // ====================================================================
    // Constants
    // ====================================================================

    localparam logic [63:0] CP_MASK           = 64'h0010_0000_0000_0000;
    localparam logic [63:0] DP_MASK           = 64'h0008_0000_0000_0000;
    localparam logic [63:0] PARITY_CLEAR_MASK = 64'hFFE7_FFFF_FFFF_FFFF;

    // ====================================================================
    // Test bookkeeping
    // ====================================================================

    int pass_count;
    int fail_count;

    // ====================================================================
    // DUT
    // ====================================================================

    lphy_sb_pkt_enc u_dut (
        .opcode      (opcode),
        .srcid       (srcid),
        .dstid       (dstid),
        .cr          (cr),
        .ep          (ep),
        .tag         (tag),
        .addr        (addr),
        .be          (be),
        .msginfo     (msginfo),
        .msgcode     (msgcode),
        .msgsubcode  (msgsubcode),
        .data_in     (data_in),
        .hdr_out     (hdr_out),
        .data_out    (data_out),
        .two_frame_pkt(two_frame_pkt),
        .enc_cp_out  (enc_cp_out),
        .enc_dp_out  (enc_dp_out)
    );

    // ====================================================================
    // Reference model (independent from DUT)
    // ====================================================================

    function automatic logic ref_cp (input logic [63:0] h);
        // Strip CP and DP, XOR-reduce the remaining 62 data bits
        return ^(h & PARITY_CLEAR_MASK);
    endfunction

    function automatic logic ref_dp (input logic [63:0] d, input logic hd);
        return hd ? (^d) : 1'b0;
    endfunction

    // Header field extractors — literal constants only (no localparam indices)
    function automatic logic [4:0]  ext_opcode(input logic [63:0] h); return h[63:59]; endfunction
    function automatic logic [2:0]  ext_srcid (input logic [63:0] h); return h[58:56]; endfunction
    function automatic logic [2:0]  ext_dstid (input logic [63:0] h); return h[55:53]; endfunction
    function automatic logic        ext_cp    (input logic [63:0] h); return h[52];     endfunction
    function automatic logic        ext_dp    (input logic [63:0] h); return h[51];     endfunction
    function automatic logic        ext_cr    (input logic [63:0] h); return h[50];     endfunction
    function automatic logic        ext_ep    (input logic [63:0] h); return h[49];     endfunction
    function automatic logic [4:0]  ext_tag   (input logic [63:0] h); return h[48:44]; endfunction
    function automatic logic [26:0] ext_addr  (input logic [63:0] h); return h[43:17]; endfunction
    function automatic logic [7:0]  ext_be    (input logic [63:0] h); return h[16:9];  endfunction
    function automatic logic [15:0] ext_msginfo(input logic [63:0] h); return h[43:28]; endfunction
    function automatic logic [7:0]  ext_msgcode(input logic [63:0] h); return h[27:20]; endfunction
    function automatic logic [7:0]  ext_msgsub (input logic [63:0] h); return h[19:12]; endfunction

    // ====================================================================
    // Helpers
    // ====================================================================

    task automatic apply_all (
        input logic [4:0]  op,
        input logic [2:0]  si, di,
        input logic        c_r, ep_i,
        input logic [4:0]  tg,
        input logic [26:0] ad,
        input logic [7:0]  b,
        input logic [15:0] mi,
        input logic [7:0]  mc, ms,
        input logic [63:0] dat
    );
        opcode=op; srcid=si; dstid=di; cr=c_r; ep=ep_i;
        tag=tg; addr=ad; be=b; msginfo=mi; msgcode=mc; msgsubcode=ms;
        data_in=dat;
        #1;
    endtask

    task automatic chk1 (input string lbl, input logic got, input logic exp);
        if (got !== exp) begin
            $display("  FAIL [%s] got=%b expected=%b", lbl, got, exp);
            fail_count++;
        end else
            pass_count++;
    endtask

    // Compare two 64-bit values masked to 'width' LSBs
    task automatic chkN (
        input string       lbl,
        input logic [63:0] got, exp,
        input int          width
    );
        logic [63:0] mask;
        mask = (width >= 64) ? 64'hFFFF_FFFF_FFFF_FFFF
                             : ((64'h1 << width) - 64'h1);
        if ((got & mask) !== (exp & mask)) begin
            $display("  FAIL [%s] got=0x%0h exp=0x%0h (w=%0d)",
                     lbl, got & mask, exp & mask, width);
            fail_count++;
        end else
            pass_count++;
    endtask

    // Verify CP and DP against reference model (common pattern)
    task automatic chk_parity (
        input string       lbl,
        input logic [63:0] h,
        input logic [63:0] d,
        input logic        hd
    );
        logic exp_c, exp_d;
        exp_c = ref_cp(h);
        exp_d = ref_dp(d, hd);
        chk1({lbl, "-CP"}, ext_cp(h), exp_c);
        chk1({lbl, "-DP"}, ext_dp(h), exp_d);
    endtask

    // ====================================================================
    // Module-level temporaries (iverilog requires these at module scope
    // rather than inside named begin..end blocks in some contexts)
    // ====================================================================

    logic [63:0] tmp_raw;
    logic        tmp_cp, tmp_dp;
    int          fc_snap;   // fail_count snapshot for per-group PASS/FAIL

    // ====================================================================
    // MAIN TEST SEQUENCE
    // ====================================================================

    initial begin
        // Initialise
        pass_count=0; fail_count=0;
        opcode=0; srcid=0; dstid=0; cr=0; ep=0; tag=0;
        addr=0; be=0; msginfo=0; msgcode=0; msgsubcode=0; data_in=0;
        #2;

        $display("");
        $display("==============================================================");
        $display("  lphy_sb_pkt_enc Testbench — UCIe §6.1.1 / §6.1.2");
        $display("==============================================================");

        // ==================================================================
        // GROUP A — Opcode decode: two_frame_pkt for all 13 valid opcodes
        // ==================================================================
        $display("");
        $display("--- Group A : Opcode decode (two_frame_pkt) ---");

        // Reg access — no data
        apply_all(5'b00000,3'b001,3'b110,0,0,0,0,8'hFF,0,0,0,64'h0); chk1("A-32bMemR",  two_frame_pkt, 0); chkN("A-32bMemR-op",  {59'h0,ext_opcode(hdr_out)}, {59'h0,5'b00000}, 5);
        apply_all(5'b00100,3'b001,3'b110,0,0,0,0,8'hFF,0,0,0,64'h0); chk1("A-32bCfgR",  two_frame_pkt, 0); chkN("A-32bCfgR-op",  {59'h0,ext_opcode(hdr_out)}, {59'h0,5'b00100}, 5);
        apply_all(5'b01000,3'b001,3'b110,0,0,0,0,8'hFF,0,0,0,64'h0); chk1("A-64bMemR",  two_frame_pkt, 0); chkN("A-64bMemR-op",  {59'h0,ext_opcode(hdr_out)}, {59'h0,5'b01000}, 5);
        apply_all(5'b01100,3'b001,3'b110,0,0,0,0,8'hFF,0,0,0,64'h0); chk1("A-64bCfgR",  two_frame_pkt, 0); chkN("A-64bCfgR-op",  {59'h0,ext_opcode(hdr_out)}, {59'h0,5'b01100}, 5);
        // Reg access — with data
        apply_all(5'b00001,3'b001,3'b110,0,0,0,0,8'hFF,0,0,0,64'h1); chk1("A-32bMemW",  two_frame_pkt, 1); chkN("A-32bMemW-op",  {59'h0,ext_opcode(hdr_out)}, {59'h0,5'b00001}, 5);
        apply_all(5'b00101,3'b001,3'b110,0,0,0,0,8'hFF,0,0,0,64'h1); chk1("A-32bCfgW",  two_frame_pkt, 1); chkN("A-32bCfgW-op",  {59'h0,ext_opcode(hdr_out)}, {59'h0,5'b00101}, 5);
        apply_all(5'b01001,3'b001,3'b110,0,0,0,0,8'hFF,0,0,0,64'h1); chk1("A-64bMemW",  two_frame_pkt, 1); chkN("A-64bMemW-op",  {59'h0,ext_opcode(hdr_out)}, {59'h0,5'b01001}, 5);
        apply_all(5'b01101,3'b001,3'b110,0,0,0,0,8'hFF,0,0,0,64'h1); chk1("A-64bCfgW",  two_frame_pkt, 1); chkN("A-64bCfgW-op",  {59'h0,ext_opcode(hdr_out)}, {59'h0,5'b01101}, 5);
        // Completions
        apply_all(5'b10000,3'b001,3'b101,0,0,0,0,8'hFF,0,0,0,64'h0); chk1("A-CplNoD",   two_frame_pkt, 0); chkN("A-CplNoD-op",   {59'h0,ext_opcode(hdr_out)}, {59'h0,5'b10000}, 5);
        apply_all(5'b10001,3'b001,3'b101,0,0,0,0,8'hFF,0,0,0,64'h1); chk1("A-Cpl32b",   two_frame_pkt, 1); chkN("A-Cpl32b-op",   {59'h0,ext_opcode(hdr_out)}, {59'h0,5'b10001}, 5);
        apply_all(5'b11001,3'b001,3'b101,0,0,0,0,8'hFF,0,0,0,64'h1); chk1("A-Cpl64b",   two_frame_pkt, 1); chkN("A-Cpl64b-op",   {59'h0,ext_opcode(hdr_out)}, {59'h0,5'b11001}, 5);
        // Messages
        apply_all(5'b10010,3'b010,3'b101,0,0,0,0,8'h00,0,8'h95,8'h01,64'h0); chk1("A-MsgNoD", two_frame_pkt, 0); chkN("A-MsgNoD-op", {59'h0,ext_opcode(hdr_out)},{59'h0,5'b10010},5);
        apply_all(5'b11011,3'b001,3'b101,0,0,0,0,8'h00,0,8'h01,8'h00,64'h3F);chk1("A-Msg64b", two_frame_pkt, 1); chkN("A-Msg64b-op", {59'h0,ext_opcode(hdr_out)},{59'h0,5'b11011},5);
        $display("  Group A: all 13 opcodes checked (%0d assertions so far)", pass_count+fail_count);

        // ==================================================================
        // GROUP B — Register access packets
        // ==================================================================
        $display("");
        $display("--- Group B : Register access field packing ---");

        // B1 : 32b Memory Read — check all reg-access fields
        fc_snap = fail_count;
        apply_all(5'b00000, 3'b001, 3'b110, 1'b0, 1'b0,
                  5'd7, 27'h0001_F80, 8'hFF,
                  16'h0, 8'h0, 8'h0, 64'h0);
        chkN("B1-srcid", ext_srcid(hdr_out), 3'b001, 3);
        chkN("B1-dstid", ext_dstid(hdr_out), 3'b110, 3);
        chkN("B1-tag",   ext_tag(hdr_out),   5'd7,   5);
        chkN("B1-addr",  ext_addr(hdr_out),  27'h0001_F80, 27);
        chkN("B1-be",    ext_be(hdr_out),    8'hFF,  8);
        chk1("B1-ep",    ext_ep(hdr_out), 1'b0);
        chk1("B1-cr",    ext_cr(hdr_out), 1'b0);
        chk1("B1-nod",   two_frame_pkt,   1'b0);
        chk1("B1-dout0", |data_out,       1'b0);
        chk_parity("B1", hdr_out, data_out, two_frame_pkt);
        $display("  B1 32bMemRead  hdr=0x%016h  [%s]",
                 hdr_out, (fail_count==fc_snap)?"PASS":"FAIL");

        // B2 : 64b Memory Write — EP, tag, addr, data, parity
        fc_snap = fail_count;
        apply_all(5'b01001, 3'b001, 3'b110, 1'b0, 1'b1,
                  5'd15, 27'h3FF_FFFE, 8'hFF,
                  16'h0, 8'h0, 8'h0,
                  64'hDEAD_BEEF_CAFE_F00D);
        chkN("B2-tag",  ext_tag(hdr_out),  5'd15, 5);
        chkN("B2-addr", ext_addr(hdr_out), 27'h3FF_FFFE, 27);
        chk1("B2-ep",   ext_ep(hdr_out), 1'b1);
        chk1("B2-2frm", two_frame_pkt,   1'b1);
        chkN("B2-data", data_out, 64'hDEAD_BEEF_CAFE_F00D, 64);
        chk_parity("B2", hdr_out, data_out, two_frame_pkt);
        $display("  B2 64bMemWrite hdr=0x%016h data=0x%016h  [%s]",
                 hdr_out, data_out, (fail_count==fc_snap)?"PASS":"FAIL");

        // B3 : Cr flag set
        fc_snap = fail_count;
        apply_all(5'b00100, 3'b001, 3'b101, 1'b1, 1'b0,
                  5'd3, 27'h000_0100, 8'h0F,
                  16'h0, 8'h0, 8'h0, 64'h0);
        chk1("B3-cr",  ext_cr(hdr_out), 1'b1);
        chk1("B3-nod", two_frame_pkt,   1'b0);
        chk_parity("B3", hdr_out, data_out, two_frame_pkt);
        $display("  B3 CrFlag      hdr=0x%016h  [%s]",
                 hdr_out, (fail_count==fc_snap)?"PASS":"FAIL");

        // ==================================================================
        // GROUP C — Completion packets
        // ==================================================================
        $display("");
        $display("--- Group C : Completion packets ---");

        // C1 : Cpl-NoData with SC status (addr[2:0]=000)
        fc_snap = fail_count;
        apply_all(5'b10000, 3'b001, 3'b101, 1'b0, 1'b0,
                  5'd7, 27'h0, 8'hFF,
                  16'h0, 8'h0, 8'h0, 64'h0);
        chkN("C1-tag",    ext_tag(hdr_out), 5'd7, 5);
        chkN("C1-be",     ext_be(hdr_out),  8'hFF, 8);
        chkN("C1-status", {61'h0, hdr_out[19:17]}, 3'b000, 3);
        chk1("C1-nod",    two_frame_pkt, 1'b0);
        chk_parity("C1",  hdr_out, data_out, two_frame_pkt);
        $display("  C1 CplNoData(SC) hdr=0x%016h  [%s]",
                 hdr_out, (fail_count==fc_snap)?"PASS":"FAIL");

        // C2 : Cpl-64b with UR status (addr[2:0]=001) + data = original hdr
        fc_snap = fail_count;
        apply_all(5'b11001, 3'b001, 3'b101, 1'b0, 1'b0,
                  5'd12, 27'h0000001, 8'hFF,
                  16'h0, 8'h0, 8'h0,
                  64'hABCD_1234_5678_9ABC);
        chkN("C2-tag",    ext_tag(hdr_out), 5'd12, 5);
        chkN("C2-status", {61'h0, hdr_out[19:17]}, 3'b001, 3);
        chk1("C2-2frm",   two_frame_pkt, 1'b1);
        chkN("C2-data",   data_out, 64'hABCD_1234_5678_9ABC, 64);
        chk_parity("C2",  hdr_out, data_out, two_frame_pkt);
        $display("  C2 Cpl64b(UR)   hdr=0x%016h  [%s]",
                 hdr_out, (fail_count==fc_snap)?"PASS":"FAIL");

        // C3 : Stall completion (Status=111b, addr[2:0]=111)
        fc_snap = fail_count;
        apply_all(5'b10000, 3'b001, 3'b101, 1'b0, 1'b0,
                  5'd5, 27'h0000007, 8'h0F,   // addr[2:0]=111=Stall
                  16'h0, 8'h0, 8'h0, 64'h0);
        chkN("C3-status", {61'h0, hdr_out[19:17]}, 3'b111, 3);
        chk_parity("C3",  hdr_out, data_out, two_frame_pkt);
        $display("  C3 Cpl(Stall)   hdr=0x%016h  [%s]",
                 hdr_out, (fail_count==fc_snap)?"PASS":"FAIL");

        // ==================================================================
        // GROUP D — Message packets
        // ==================================================================
        $display("");
        $display("--- Group D : Message packets ---");

        // D1 : {SBINIT done req} — MsgCode=95h Sub=01h Info=0000h (no data)
        fc_snap = fail_count;
        apply_all(5'b10010, 3'b010, 3'b101, 1'b0, 1'b0,
                  5'h0, 27'h0, 8'h0,
                  16'h0000, 8'h95, 8'h01, 64'h0);
        chkN("D1-msginfo", ext_msginfo(hdr_out), 16'h0000, 16);
        chkN("D1-msgcode", ext_msgcode(hdr_out), 8'h95,     8);
        chkN("D1-msgsub",  ext_msgsub(hdr_out),  8'h01,     8);
        chk1("D1-nod",     two_frame_pkt, 1'b0);
        chk_parity("D1",   hdr_out, data_out, two_frame_pkt);
        $display("  D1 SBINITdoneReq hdr=0x%016h  [%s]",
                 hdr_out, (fail_count==fc_snap)?"PASS":"FAIL");

        // D2 : {AdvCap.Adapter} — MsgCode=01h Sub=00h Info=0000h (64b data)
        fc_snap = fail_count;
        apply_all(5'b11011, 3'b001, 3'b101, 1'b0, 1'b0,
                  5'h0, 27'h0, 8'h0,
                  16'h0000, 8'h01, 8'h00,
                  64'h0000_0000_0000_003F);
        chkN("D2-msgcode", ext_msgcode(hdr_out), 8'h01, 8);
        chkN("D2-msgsub",  ext_msgsub(hdr_out),  8'h00, 8);
        chk1("D2-2frm",    two_frame_pkt, 1'b1);
        chkN("D2-data",    data_out, 64'h0000_0000_0000_003F, 64);
        chk_parity("D2",   hdr_out, data_out, two_frame_pkt);
        $display("  D2 AdvCap.Adapt  hdr=0x%016h  [%s]",
                 hdr_out, (fail_count==fc_snap)?"PASS":"FAIL");

        // D3 : Stall encoding — MsgInfo=FFFFh (Retimer, Table 53)
        fc_snap = fail_count;
        apply_all(5'b10010, 3'b001, 3'b101, 1'b0, 1'b0,
                  5'h0, 27'h0, 8'h0,
                  16'hFFFF, 8'h04, 8'h01, 64'h0);
        chkN("D3-msginfo", ext_msginfo(hdr_out), 16'hFFFF, 16);
        chk_parity("D3",   hdr_out, data_out, two_frame_pkt);
        $display("  D3 Stall FFFFh   hdr=0x%016h  [%s]",
                 hdr_out, (fail_count==fc_snap)?"PASS":"FAIL");

        // D4 : MBINIT.PARAM configuration req (MsgCode=A5h Sub=00h)
        //      With 64b data: negotiated speed & parameters (Table 56)
        fc_snap = fail_count;
        apply_all(5'b11011, 3'b010, 3'b101, 1'b0, 1'b0,
                  5'h0, 27'h0, 8'h0,
                  16'h0000, 8'hA5, 8'h00,
                  64'h0000_0000_0001_0310);  // example PARAM config
        chkN("D4-msgcode", ext_msgcode(hdr_out), 8'hA5, 8);
        chkN("D4-data",    data_out, 64'h0000_0000_0001_0310, 64);
        chk_parity("D4",   hdr_out, data_out, two_frame_pkt);
        $display("  D4 MBINIT.PARAM  hdr=0x%016h  [%s]",
                 hdr_out, (fail_count==fc_snap)?"PASS":"FAIL");

        // ==================================================================
        // GROUP E — Data passthrough and gating
        // ==================================================================
        $display("");
        $display("--- Group E : Data passthrough / gating ---");

        // E1 : 32b write, zero-padded payload
        fc_snap = fail_count;
        apply_all(5'b00001, 3'b001, 3'b110, 0, 0, 5'd1,
                  27'h4, 8'h0F, 16'h0, 8'h0, 8'h0,
                  64'h0000_0000_CAFE_BABE);
        chkN("E1-data", data_out, 64'h0000_0000_CAFE_BABE, 64);
        chk1("E1-2frm", two_frame_pkt, 1'b1);
        $display("  E1 32b passthru: 0x%016h  [%s]",
                 data_out, (fail_count==fc_snap)?"PASS":"FAIL");

        // E2 : No-data packet — data_out must be 64'h0
        fc_snap = fail_count;
        apply_all(5'b00000, 3'b001, 3'b110, 0, 0, 5'd0,
                  27'h0, 8'hFF, 16'h0, 8'h0, 8'h0,
                  64'hDEAD_BEEF_DEAD_BEEF);
        chkN("E2-gated", data_out, 64'h0, 64);
        chk1("E2-nod",   two_frame_pkt, 1'b0);
        $display("  E2 No-data gate: 0x%016h  [%s]",
                 data_out, (fail_count==fc_snap)?"PASS":"FAIL");

        // E3 : All-ones payload → DP = 0 (even count)
        fc_snap = fail_count;
        apply_all(5'b01001, 3'b001, 3'b110, 0, 0, 5'd0,
                  27'h0, 8'hFF, 16'h0, 8'h0, 8'h0,
                  64'hFFFF_FFFF_FFFF_FFFF);
        chk1("E3-DP-allones", ext_dp(hdr_out), 1'b0);
        $display("  E3 All-ones DP=%b (want 0)  [%s]",
                 ext_dp(hdr_out), (fail_count==fc_snap)?"PASS":"FAIL");

        // E4 : Single bit payload → DP = 1
        fc_snap = fail_count;
        apply_all(5'b01001, 3'b001, 3'b110, 0, 0, 5'd0,
                  27'h0, 8'hFF, 16'h0, 8'h0, 8'h0,
                  64'h0000_0000_0000_0001);
        chk1("E4-DP-bit0", ext_dp(hdr_out), 1'b1);
        $display("  E4 Single-bit DP=%b (want 1)  [%s]",
                 ext_dp(hdr_out), (fail_count==fc_snap)?"PASS":"FAIL");

        // ==================================================================
        // GROUP F — Parity cross-check: 8 packets vs. reference model
        // ==================================================================
        $display("");
        $display("--- Group F : Parity reference cross-check (8 packets) ---");

        fc_snap = fail_count;

        apply_all(5'b00000,3'b001,3'b110,0,0,5'd0, 27'h0,8'hFF,16'h0,8'h0,8'h0,64'h0);
        chk_parity("F0", hdr_out, data_out, two_frame_pkt);

        apply_all(5'b00001,3'b001,3'b110,0,0,5'd3, 27'hAAA,8'h0F,16'h0,8'h0,8'h0,64'hDEAD_BEEF_0000_0000);
        chk_parity("F1", hdr_out, data_out, two_frame_pkt);

        apply_all(5'b01001,3'b001,3'b110,0,0,5'd15,27'h7FF_FFFF,8'hFF,16'h0,8'h0,8'h0,64'hFFFF_FFFF_FFFF_FFFF);
        chk_parity("F2", hdr_out, data_out, two_frame_pkt);

        apply_all(5'b10000,3'b001,3'b101,0,0,5'd7, 27'h0,8'hFF,16'h0,8'h0,8'h0,64'h0);
        chk_parity("F3", hdr_out, data_out, two_frame_pkt);

        apply_all(5'b11001,3'b001,3'b101,0,0,5'd12,27'h1,8'hFF,16'h0,8'h0,8'h0,64'hABCD_1234_5678_9ABC);
        chk_parity("F4", hdr_out, data_out, two_frame_pkt);

        apply_all(5'b10010,3'b010,3'b101,0,0,5'd0, 27'h0,8'h0,16'h0000,8'h95,8'h01,64'h0);
        chk_parity("F5", hdr_out, data_out, two_frame_pkt);

        apply_all(5'b11011,3'b001,3'b101,0,0,5'd0, 27'h0,8'h0,16'h0000,8'h01,8'h00,64'h3F);
        chk_parity("F6", hdr_out, data_out, two_frame_pkt);

        apply_all(5'b10010,3'b001,3'b101,0,0,5'd0, 27'h0,8'h0,16'hFFFF,8'h04,8'h01,64'h0);
        chk_parity("F7", hdr_out, data_out, two_frame_pkt);

        $display("  Group F: 8 packets × 2 parity checks  [%s]",
                 (fail_count==fc_snap)?"ALL PASS":"FAILURES");

        // ==================================================================
        // GROUP G — Random stress: 100 packets, 5 checks each = 500
        // ==================================================================
        $display("");
        $display("--- Group G : Random stress (100 packets × 5 checks) ---");

        begin : blk_g
            // All valid opcodes for random selection
            logic [4:0] valid_ops[13];
            logic [4:0]  r_op;
            logic [2:0]  r_si, r_di;
            logic [4:0]  r_tg;
            logic [26:0] r_ad;
            logic [7:0]  r_be;
            logic [15:0] r_mi;
            logic [7:0]  r_mc, r_ms;
            logic [63:0] r_dat;
            logic        exp_hd;
            int          idx;

            valid_ops[0]  = 5'b00000; valid_ops[1]  = 5'b00001;
            valid_ops[2]  = 5'b00100; valid_ops[3]  = 5'b00101;
            valid_ops[4]  = 5'b01000; valid_ops[5]  = 5'b01001;
            valid_ops[6]  = 5'b01100; valid_ops[7]  = 5'b01101;
            valid_ops[8]  = 5'b10000; valid_ops[9]  = 5'b10001;
            valid_ops[10] = 5'b11001; valid_ops[11] = 5'b10010;
            valid_ops[12] = 5'b11011;

            fc_snap = fail_count;

            for (int i = 0; i < 100; i++) begin
                idx   = $urandom_range(0, 12);
                r_op  = valid_ops[idx];
                r_si  = $urandom & 3'h7;
                r_di  = $urandom & 3'h7;
                r_tg  = $urandom & 5'h1F;
                r_ad  = {$random} & 27'h7FF_FFFF;
                r_be  = $urandom & 8'hFF;
                r_mi  = {$random} & 16'hFFFF;
                r_mc  = $urandom & 8'hFF;
                r_ms  = $urandom & 8'hFF;
                r_dat = {$random, $random};

                apply_all(r_op, r_si, r_di, 1'b0, 1'b0,
                          r_tg, r_ad, r_be, r_mi, r_mc, r_ms, r_dat);

                exp_hd = r_op[0];

                // Check 1: two_frame_pkt == opcode[0]
                chk1($sformatf("G%0d-2frm", i), two_frame_pkt, exp_hd);

                // Check 2: opcode passes through to header[63:59]
                chkN($sformatf("G%0d-op",   i),
                     ext_opcode(hdr_out), {59'h0, r_op}, 5);

                // Check 3: data_out = data_in when has_data, else 0
                if (exp_hd) begin
                    chkN($sformatf("G%0d-dat", i), data_out, r_dat, 64);
                end else begin
                    chkN($sformatf("G%0d-gat", i), data_out, 64'h0, 64);
                end

                // Check 4 & 5: CP and DP via reference model
                chk_parity($sformatf("G%0d", i),
                           hdr_out, data_out, two_frame_pkt);
            end

            $display("  Group G: 100 random packets  [%s]",
                     (fail_count==fc_snap)?"ALL PASS":"FAILURES");
        end

        // ==================================================================
        // SUMMARY
        // ==================================================================
        $display("");
        $display("==============================================================");
        $display("  TEST SUMMARY");
        $display("  Passed : %0d", pass_count);
        $display("  Failed : %0d", fail_count);
        $display("  Total  : %0d", pass_count + fail_count);
        $display("  Result : %s",
                 (fail_count==0) ? "*** ALL PASS ***"
                                 : "!!! FAILURES DETECTED !!!");
        $display("==============================================================");
        $display("");

        if (fail_count != 0)
            $fatal(1, "Testbench FAILED with %0d error(s)", fail_count);
        $finish;
    end

    initial begin #2_000_000; $fatal(1, "[WATCHDOG] timeout"); end

    initial begin
        $dumpfile("tb_lphy_sb_pkt_enc.vcd");
        $dumpvars(0, tb_lphy_sb_pkt_enc);
    end

endmodule : tb_lphy_sb_pkt_enc