`timescale 1ns / 1ps

module tb_lphy_sb_ctrl();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic lclk;
    logic rst_n;
    logic rdi_in_reset;
    
    // TX Interface
    logic        tx_req_valid;
    logic        tx_req_ready;
    logic [4:0]  tx_opcode;
    logic [2:0]  tx_srcid, tx_dstid;
    logic        tx_ep, tx_cr;
    logic [63:0] tx_payload;
    logic [4:0]  tx_tag;
    logic [7:0]  tx_be;
    logic [23:0] tx_addr;
    logic [2:0]  tx_cp_status;
    logic [7:0]  tx_msgcode, tx_msgsubcode;
    logic [15:0] tx_msginfo;
    logic        tx_local_crd_ret;
    
    // RX Interface
    logic        rx_req_valid;
    logic [4:0]  rx_opcode;
    logic [2:0]  rx_srcid, rx_dstid;
    logic        rx_ep, rx_cr;
    logic [63:0] rx_payload;
    logic [4:0]  rx_tag;
    logic [7:0]  rx_be;
    logic [23:0] rx_addr;
    logic [2:0]  rx_cp_status;
    logic [7:0]  rx_msgcode, rx_msgsubcode;
    logic [15:0] rx_msginfo;
    logic        rx_parity_err;
    
    // AFE Boundary
    logic        afe_tx_valid;
    logic [63:0] afe_tx_data;
    logic        afe_tx_ready;

    logic        afe_rx_valid;
    logic [63:0] afe_rx_data;
    logic        afe_rx_en;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_sb_ctrl dut (.*);

    // -------------------------------------------------------------------------
    // Clock Generation & Loopback
    // -------------------------------------------------------------------------
    initial begin
        lclk = 0;
        forever #5 lclk = ~lclk; 
    end

    // Loopback physical AFE wires to test end-to-end functionality
    assign afe_rx_valid = afe_tx_valid;
    assign afe_rx_data  = afe_tx_data;
    assign afe_tx_ready = 1'b1; // Simulate AFE always ready to accept

    int error_count = 0;

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Full System Verification: lphy_sb_ctrl");
        $display("==========================================================");

        // Reset Sequence
        rst_n = 0; rdi_in_reset = 1; tx_req_valid = 0;
        @(negedge lclk);
        rst_n = 1; rdi_in_reset = 0;
        @(negedge lclk);

        // =====================================================================
        // TEST 1: Full Pipeline (Reg Request With Data)
        // =====================================================================
        $display("Sending 64-bit Memory Write Packet...");
        
        tx_req_valid = 1'b1;
        tx_opcode    = 5'b01001;    // 64-bit Mem Write (Requires Data)
        tx_srcid     = 3'b101;
        tx_dstid     = 3'b010;
        tx_addr      = 24'hDEADBF;
        tx_payload   = 64'hCAFEBABE_12345678;
        
        // Wait for controller to accept it
        wait(tx_req_ready == 1'b1);
        @(negedge lclk);
        tx_req_valid = 1'b0;

        // Monitor AFE Bus for Header Phase
        @(negedge lclk);
        if (!afe_tx_valid) begin
            $error("TEST 1 FAILED: TX Sequencer did not output Header.");
            error_count++;
        end
        
        // Monitor AFE Bus for Data Phase
        @(negedge lclk);
        if (!afe_tx_valid || afe_tx_data !== 64'hCAFEBABE_12345678) begin
            $error("TEST 1 FAILED: TX Sequencer did not output Data Payload.");
            error_count++;
        end

        // Wait for the RX Sequencer to re-assemble and Decode
        wait(rx_req_valid == 1'b1);
        
        if (rx_opcode !== 5'b01001 || rx_addr !== 24'hDEADBF || rx_payload !== 64'hCAFEBABE_12345678) begin
            $error("TEST 1 FAILED: Loopback decode mismatch.");
            error_count++;
        end

        // =====================================================================
        // TEST 2: Header-Only Packet (Message)
        // =====================================================================
        @(negedge lclk);
        $display("Sending Header-Only Message Packet...");
        
        tx_req_valid = 1'b1;
        tx_opcode    = 5'b10010; // Message (No Data)
        tx_msginfo   = 16'h9999;
        
        wait(tx_req_ready == 1'b1);
        @(negedge lclk);
        tx_req_valid = 1'b0;

        // Monitor AFE Bus
        @(negedge lclk);
        if (!afe_tx_valid) begin
            $error("TEST 2 FAILED: TX Sequencer did not output Header.");
            error_count++;
        end
        
        // In the next cycle, valid should drop because there is no data payload!
        @(negedge lclk);
        if (afe_tx_valid) begin
            $error("TEST 2 FAILED: TX Sequencer output ghost data payload.");
            error_count++;
        end

        wait(rx_req_valid == 1'b1);
        if (rx_opcode !== 5'b10010 || rx_msginfo !== 16'h9999) begin
            $error("TEST 2 FAILED: Message loopback decode mismatch.");
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_sb_ctrl integrated perfectly. SerDes bypassed successfully.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end
endmodule