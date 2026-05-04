`timescale 1ns / 1ps

module tb_lphy_sb_pkt_enc();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    
    logic req_valid;
    logic req_ready;
    
    logic [4:0]  opcode;
    logic [2:0]  srcid;
    logic [2:0]  dstid;
    logic        ep;
    logic        cr;
    logic [63:0] payload_in;
    
    logic [4:0]  tag;
    logic [7:0]  be;
    logic [23:0] addr;
    logic [2:0]  cp_status;
    
    logic [7:0]  msgcode;
    logic [7:0]  msgsubcode;
    logic [15:0] msginfo;
    
    logic        pkt_valid;
    logic [63:0] pkt_header;
    logic [63:0] pkt_data;
    logic        pkt_has_data;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_sb_pkt_enc dut (
        .* // Auto-connect all signals
    );

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
        $display("Starting Verification: lphy_sb_pkt_enc");
        $display("==========================================================");

        // Initialization
        rst_n = 0;
        req_valid = 0;
        opcode = 0; srcid = 0; dstid = 0; ep = 0; cr = 0; payload_in = 0;
        tag = 0; be = 0; addr = 0; cp_status = 0;
        msgcode = 0; msgsubcode = 0; msginfo = 0;
        
        @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // =====================================================================
        // TEST 1: Register Access Request (e.g., 32b Mem Write)
        // =====================================================================
        req_valid  = 1'b1;
        opcode     = 5'b00001; // 32b Mem Write (Has Data)
        srcid      = 3'b101;
        dstid      = 3'b010;
        ep         = 1'b0;
        cr         = 1'b1;
        tag        = 5'b11001;
        be         = 8'hFF;
        addr       = 24'hABCDEF;
        payload_in = 64'h1122334455667788;
        
        @(posedge clk); // RTL samples inputs on this edge
        #1;             // Move slightly past the edge to read the pipelined output safely
        
        if (!pkt_valid) begin
            $error("TEST 1 FAILED: pkt_valid did not assert.");
            error_count++;
        end
        if (!pkt_has_data) begin
            $error("TEST 1 FAILED: Opcode 00001 should assert pkt_has_data.");
            error_count++;
        end
        // Expected Phase 0: 101_00_11001_11111111_00000000_0_00001 -> 32'hA67FC001
        if (pkt_header[31:0] !== 32'hA67FC001) begin
            $error("TEST 1 FAILED: Phase 0 encoding mismatch. Got %h", pkt_header[31:0]);
            error_count++;
        end
        
        req_valid = 1'b0; // Clear for next test
        @(posedge clk);

        // =====================================================================
        // TEST 2: Register Access Completion (e.g., Cpl without Data)
        // =====================================================================
        req_valid  = 1'b1;
        opcode     = 5'b10000; // Cpl without Data
        srcid      = 3'b111;
        dstid      = 3'b001;
        ep         = 1'b1;
        cr         = 1'b0;
        tag        = 5'b00011;
        be         = 8'h0F;
        cp_status  = 3'b000; // Success
        payload_in = 64'h0;
        
        @(posedge clk); 
        #1;

        if (pkt_has_data) begin
            $error("TEST 2 FAILED: Opcode 10000 should NOT assert pkt_has_data.");
            error_count++;
        end
        // Expected Phase 0: 111_00_00011_00001111_00000000_1_10000 -> 32'hE0C3C030
        if (pkt_header[31:0] !== 32'hE0C3C030) begin
            $error("TEST 2 FAILED: Phase 0 encoding mismatch. Got %h", pkt_header[31:0]);
            error_count++;
        end

        req_valid = 1'b0;
        @(posedge clk);

        // =====================================================================
        // TEST 3: Message (e.g., LinkMgmt / PM)
        // =====================================================================
        req_valid  = 1'b1;
        opcode     = 5'b10010; // Message without Data
        srcid      = 3'b000;
        dstid      = 3'b000;
        msgcode    = 8'hAA;
        msgsubcode = 8'hBB;
        msginfo    = 16'h1234;
        
        @(posedge clk);
        #1;

        if (pkt_has_data) begin
            $error("TEST 3 FAILED: Opcode 10010 should NOT assert pkt_has_data.");
            error_count++;
        end
        // Expected Phase 0: 000_0000000_10101010_000000000_10010 -> 32'h002A8012
        if (pkt_header[31:0] !== 32'h002A8012) begin
            $error("TEST 3 FAILED: Phase 0 encoding mismatch. Got %h", pkt_header[31:0]);
            error_count++;
        end
        // Check Phase 1 Packing (Excluding parity bits which are handled by CRC block)
        if (pkt_header[61:32] !== {3'b000, 3'b000, 16'h1234, 8'hBB}) begin
            $error("TEST 3 FAILED: Phase 1 encoding mismatch. Got %h", pkt_header[61:32]);
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_sb_pkt_enc passed all formatting constraints.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule