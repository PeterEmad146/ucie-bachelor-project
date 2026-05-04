`timescale 1ns / 1ps

module tb_lphy_rdi_intf();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic lclk, rst_n;
    
    logic [3:0] lp_state_req, pl_state_sts;
    logic pl_inband_pres, lp_linkerror;
    logic pl_error, pl_cerror, pl_nferror, pl_trainerror, pl_phyinrecenter;
    logic pl_stallreq, lp_stallack, pl_clk_req, lp_clk_ack;
    logic lp_wake_req, pl_wake_ack;
    logic [2:0] pl_speedmode, pl_lnk_cfg;
    
    logic [3:0] internal_pl_state_sts, internal_lp_state_req;
    logic internal_pl_inband_pres, internal_lp_linkerror, internal_start_link_training;
    logic internal_stallreq, internal_stallack, internal_phyinrecenter;
    logic internal_error, internal_cerror, internal_nferror, internal_trainerror;
    logic [2:0] internal_speedmode, internal_lnk_cfg;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    lphy_rdi_intf dut (.*);

    initial begin
        lclk = 0;
        forever #5 lclk = ~lclk; 
    end

    int error_count = 0;

    // -------------------------------------------------------------------------
    // Verification Sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("STARTING RDI INTERFACE VERIFICATION");
        $display("==========================================================");

        rst_n = 0;
        lp_state_req = 0; lp_linkerror = 0; lp_stallack = 0; lp_clk_ack = 0; lp_wake_req = 0;
        internal_pl_state_sts = 0; internal_pl_inband_pres = 0; internal_stallreq = 0;
        internal_phyinrecenter = 0; internal_error = 0; internal_cerror = 0;
        internal_nferror = 0; internal_trainerror = 0; internal_speedmode = 3'b111; internal_lnk_cfg = 3'b101;
        
        @(negedge lclk);
        rst_n = 1;
        @(negedge lclk);

        // --- TEST 1: The Start Link Training Synthesizer ---
        $display("TEST 1: Start Link Training Triggers...");
        
        // Initial state: PHY is in Reset
        internal_pl_state_sts = 4'b0000;
        
        // Adapter requests Active
        lp_state_req = 4'b0001;
        #1;
        
        if (!internal_start_link_training) begin 
            $error("TEST 1 FAILED: Did not synthesize start_link_training."); 
            error_count++; 
        end
        
        // Simulate PHY waking up and entering SBINIT/MBINIT (state != 0000)
        @(negedge lclk);
        internal_pl_state_sts = 4'b0001; 
        #1;
        if (internal_start_link_training) begin 
            $error("TEST 1 FAILED: Did not drop start_link_training once PHY left reset."); 
            error_count++; 
        end
        
        // --- TEST 2: Stall Handshake Delay (Anti-Loop Rule) ---
        $display("TEST 2: Stall Handshake Synchronizers...");
        
        // LTSSM requests a stall
        internal_stallreq = 1'b1;
        #1;
        
        // Combinatorially, pl_stallreq should NOT be high yet
        if (pl_stallreq) begin 
            $error("TEST 2 FAILED: Combinatorial loop detected! pl_stallreq bypassed the flop."); 
            error_count++; 
        end
        
        @(negedge lclk); // Let the clock tick
        #1;
        if (!pl_stallreq) begin 
            $error("TEST 2 FAILED: pl_stallreq did not assert after clock edge."); 
            error_count++; 
        end
        
        // --- TEST 3: Dummy Wake Handshake Pipeline ---
        $display("TEST 3: Wake Ack Pipeline Delay...");
        lp_wake_req = 1'b1;
        
        @(negedge lclk); // Flop 1
        if (pl_wake_ack) begin $error("TEST 3 FAILED: Wake Ack was too fast."); error_count++; end
        
        @(negedge lclk); // Flop 2
        if (!pl_wake_ack) begin $error("TEST 3 FAILED: Wake Ack did not propagate."); error_count++; end

        $display("==========================================================");
        if (error_count == 0) $display("SUCCESS: lphy_rdi_intf passed all synchronizer and translation tests.");
        else $display("FAILED: %0d errors detected.", error_count);
        $display("==========================================================");
        $finish;
    end
endmodule