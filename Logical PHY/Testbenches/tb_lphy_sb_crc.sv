`timescale 1ns / 1ps

module tb_lphy_sb_crc();

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic [63:0] tx_header_in;
    logic [63:0] tx_data_in;
    logic        tx_has_data;
    logic [63:0] tx_header_out;
    
    logic [63:0] rx_header_in;
    logic [63:0] rx_data_in;
    logic        rx_has_data;
    logic        rx_cp_err;
    logic        rx_dp_err;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    lphy_sb_crc dut (
        .tx_header_in(tx_header_in),
        .tx_data_in(tx_data_in),
        .tx_has_data(tx_has_data),
        .tx_header_out(tx_header_out),
        
        .rx_header_in(rx_header_in),
        .rx_data_in(rx_data_in),
        .rx_has_data(rx_has_data),
        .rx_cp_err(rx_cp_err),
        .rx_dp_err(rx_dp_err)
    );

    // -------------------------------------------------------------------------
    // Helper Variables
    // -------------------------------------------------------------------------
    int error_count = 0;
    logic expected_cp;
    logic expected_dp;
    logic [63:0] rand_header;
    logic [63:0] rand_data;

    // -------------------------------------------------------------------------
    // Main Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================");
        $display("Starting Verification: lphy_sb_crc");
        $display("==========================================================");

        // =====================================================================
        // TEST 1: TX Parity Generation (All 0s and All 1s)
        // =====================================================================
        tx_header_in = 64'h0;
        tx_data_in   = 64'h0;
        tx_has_data  = 1'b1;
        #1;
        if (tx_header_out[62] !== 1'b0 || tx_header_out[63] !== 1'b0) begin
            $error("TEST 1A FAILED: All zeros should yield 0 parity.");
            error_count++;
        end

        // 62 bits of 1s (Bits 0-61). 62 is an EVEN number, so parity should be 0.
        tx_header_in = {2'b00, 62'h3FFF_FFFF_FFFF_FFFF}; 
        // 64 bits of 1s. 64 is an EVEN number, so parity should be 0.
        tx_data_in   = 64'hFFFF_FFFF_FFFF_FFFF; 
        #1;
        if (tx_header_out[62] !== 1'b0 || tx_header_out[63] !== 1'b0) begin
            $error("TEST 1B FAILED: Even number of 1s should yield 0 parity.");
            error_count++;
        end

        // Change data to 63 ones (ODD number) -> DP should be 1
        tx_data_in = 64'h7FFF_FFFF_FFFF_FFFF;
        // Change header to 61 ones (ODD number) -> CP should be 1
        tx_header_in = {2'b00, 62'h1FFF_FFFF_FFFF_FFFF};
        #1;
        if (tx_header_out[62] !== 1'b1 || tx_header_out[63] !== 1'b1) begin
            $error("TEST 1C FAILED: Odd number of 1s should yield 1 parity.");
            error_count++;
        end

        // =====================================================================
        // TEST 2: TX No Data Scenario
        // =====================================================================
        tx_has_data = 1'b0;
        tx_data_in  = 64'hFFFF_FFFF_FFFF_FFFF; // Try to trick it with odd/even ones
        #1;
        if (tx_header_out[63] !== 1'b0) begin
            $error("TEST 2 FAILED: DP must be strictly 0 when tx_has_data is 0.");
            error_count++;
        end

        // =====================================================================
        // TEST 3: RX Loopback (Happy Path)
        // =====================================================================
        // Generate 1000 random loopback tests
        for (int i = 0; i < 1000; i++) begin
            // Generate random 64-bit values
            rand_header = {$urandom(), $urandom()};
            rand_data   = {$urandom(), $urandom()};
            
            // Apply to TX
            tx_header_in = rand_header;
            tx_data_in   = rand_data;
            tx_has_data  = i[0]; // Toggle data presence randomly
            #1;
            
            // Loopback TX output into RX input
            rx_header_in = tx_header_out;
            rx_data_in   = tx_data_in;
            rx_has_data  = tx_has_data;
            #1;
            
            if (rx_cp_err || rx_dp_err) begin
                $error("TEST 3 FAILED: False positive error in loopback iteration %0d", i);
                error_count++;
            end
        end

        // =====================================================================
        // TEST 4: RX Fault Injection
        // =====================================================================
        // Setup a baseline healthy packet
        tx_header_in = {$urandom(), $urandom()};
        tx_data_in   = {$urandom(), $urandom()};
        tx_has_data  = 1'b1;
        #1;
        
        // 4A: Inject a single bit-flip in the Header payload
        rx_header_in = tx_header_out ^ 64'h0000_0000_0000_0008; // Flip bit 3
        rx_data_in   = tx_data_in;
        rx_has_data  = 1'b1;
        #1;
        if (!rx_cp_err || rx_dp_err) begin
            $error("TEST 4A FAILED: Failed to detect Header bit-flip.");
            error_count++;
        end

        // 4B: Inject a single bit-flip in the Data payload
        rx_header_in = tx_header_out;
        rx_data_in   = tx_data_in ^ 64'h8000_0000_0000_0000; // Flip MSB
        rx_has_data  = 1'b1;
        #1;
        if (rx_cp_err || !rx_dp_err) begin
            $error("TEST 4B FAILED: Failed to detect Data bit-flip.");
            error_count++;
        end

        // 4C: Corrupt the CP parity bit itself
        rx_header_in = tx_header_out ^ 64'h4000_0000_0000_0000; // Flip bit 62 (CP)
        rx_data_in   = tx_data_in;
        rx_has_data  = 1'b1;
        #1;
        if (!rx_cp_err || rx_dp_err) begin
            $error("TEST 4C FAILED: Failed to detect corrupted CP bit.");
            error_count++;
        end

        // =====================================================================
        // CONCLUSION
        // =====================================================================
        $display("==========================================================");
        if (error_count == 0) begin
            $display("SUCCESS: lphy_sb_crc passed all test vectors.");
        end else begin
            $display("FAILED: %0d errors detected.", error_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule