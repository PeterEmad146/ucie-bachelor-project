`timescale 1ns / 1ps

module tb_lphy_sb_pkt_dec();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    
    logic        pkt_valid;
    logic [63:0] pkt_header;
    logic [63:0] pkt_data;
    
    logic        req_valid;
    logic [4:0]  opcode;
    logic [2:0]  srcid;
    logic [2:0]  dstid;
    logic        ep;
    logic        cr;
    logic [63:0] payload_out;
    
    logic [4:0]  tag;
    logic [7:0]  be;
    logic [23:0] addr;
    logic [2:0]  cp_status;
    
    logic [7:0]  msgcode;
    logic [7:0]  msgsubcode;
    logic [15:0] msginfo;
    logic        parity_err;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_sb_pkt_dec dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz Test Clock
    end

    // -------------------------------------------------------------------------
    // Helper Variables
    // -------------------------------------------------------------------------
    int error_count = 0;

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_sb_pkt_dec");
        $display("==========================================================");

        rst_n = 0;
        pkt_valid = 0;
        pkt_header = 0;
        pkt_data = 0;
        
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // =====================================================================
        // TEST 1: Unpack Register Access Request (32b Mem Write)
        // =====================================================================
        // Header Phase 0: 32'hA67FC001 (srcid=5, tag=25, be=FF, ep=0, op=1)
        // Header Phase 1: 32'h62ABCDEF (cr=1, dstid=2, addr=ABCDEF, CP=1)
        pkt_valid  = 1'b1;
        pkt_header = {32'h62ABCDEF, 32'hA67FC001}; 
        pkt_data   = 64'h1122334455667788;
        
        @(negedge clk); // Wait for the posedge to process, check on the next negedge
        pkt_valid = 1'b0; // Clear it so it doesn't process twice

        if (!req_valid) begin $error("TEST 1 FAILED: req_valid did not assert."); error_count++; end
        if (parity_err) begin $error("TEST 1 FAILED: False parity error detected."); error_count++; end
        if (opcode !== 5'b00001) begin $error("TEST 1 FAILED: Opcode mismatch."); error_count++; end
        if (srcid !== 3'b101) begin $error("TEST 1 FAILED: srcid mismatch."); error_count++; end
        if (dstid !== 3'b010) begin $error("TEST 1 FAILED: dstid mismatch."); error_count++; end
        if (cr !== 1'b1) begin $error("TEST 1 FAILED: cr mismatch. (Did you fix the cr <= phase1[29] bug?)"); error_count++; end
        if (addr !== 24'hABCDEF) begin $error("TEST 1 FAILED: addr mismatch."); error_count++; end
        if (tag !== 5'd25) begin $error("TEST 1 FAILED: tag mismatch."); error_count++; end
        if (be !== 8'hFF) begin $error("TEST 1 FAILED: be mismatch."); error_count++; end
        if (payload_out !== 64'h1122334455667788) begin $error("TEST 1 FAILED: payload mismatch."); error_count++; end
        
        // Ensure unused fields are zeroed
        if (msgcode !== 0 || msginfo !== 0 || cp_status !== 0) begin
            $error("TEST 1 FAILED: Unused fields were not properly zeroed out.");
            error_count++;
        end

        @(negedge clk);

        // =====================================================================
        // TEST 2: Unpack Message Packet
        // =====================================================================
        // Phase 0: 32'h002A8012 (srcid=0, msgcode=AA, op=10010)
        // Phase 1: 32'h001234BB (dstid=0, msginfo=1234, msgsubcode=BB)
        pkt_valid  = 1'b1;
        pkt_header = {32'h001234BB, 32'h002A8012}; 
        pkt_data   = 64'h0;
        
        @(negedge clk);
        pkt_valid = 1'b0;

        if (opcode !== 5'b10010) begin $error("TEST 2 FAILED: Opcode mismatch."); error_count++; end
        if (msgcode !== 8'hAA) begin $error("TEST 2 FAILED: msgcode mismatch."); error_count++; end
        if (msgsubcode !== 8'hBB) begin $error("TEST 2 FAILED: msgsubcode mismatch."); error_count++; end
        if (msginfo !== 16'h1234) begin $error("TEST 2 FAILED: msginfo mismatch."); error_count++; end
        if (addr !== 0 || tag !== 0) begin $error("TEST 2 FAILED: Register fields not zeroed during Message decode."); error_count++; end

        @(negedge clk);

        // =====================================================================
        // TEST 3: Parity Error Detection Flagging
        // =====================================================================
        // We must start with a mathematically perfect packet!
        // The payload has 17 ones (odd), so it requires CP=1 (Bit 62) to be valid.
        // Valid header: {32'h401234BB, 32'h002A8012}.
        // We corrupt it by flipping bit 3 to artificially make the parity even.
        pkt_valid  = 1'b1;
        pkt_header = {32'h401234BB, 32'h002A8012} ^ 64'h0000_0000_0000_0008; 
        pkt_data   = 64'h0;
        
        @(negedge clk);
        pkt_valid = 1'b0;

        if (!parity_err) begin
            $error("TEST 3 FAILED: The decoder failed to assert parity_err on corrupted header.");
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_sb_pkt_dec passed all formatting and parity constraints.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule