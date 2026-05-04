`timescale 1ns / 1ps

module tb_lphy_sb_serdes;
    
    logic clk;  // 800 MHz TX clock
    logic rst_n;
    
    // TX Side
    logic tx_pkt_valid;
    logic [63:0] tx_pkt_header;
    logic [63:0] tx_pkt_data;
    logic tx_pkt_has_data;
    logic tx_req_ready;
    
    // Serial Wire
    logic wire_datasb;
    logic wire_cksb;
    
    // RX Side
    logic local_clk;    // Local processing clock for RX output
    logic rx_pkt_valid;
    logic [63:0] rx_pkt_header;
    logic [63:0] rx_pkt_data;
    
    // Instantiate TX
    lphy_sb_tx tx_inst (
        .clk(clk),
        .rst_n(rst_n),
        .pkt_valid(tx_pkt_valid),
        .pkt_header(tx_pkt_header),
        .pkt_data(tx_pkt_data),
        .pkt_has_data(tx_pkt_has_data),
        .tx_req_ready(tx_req_ready),
        .tx_datasb(wire_datasb),
        .tx_cksb(wire_cksb)
    );
    
    // Instantiate RX
    lphy_sb_rx rx_inst (
        .rst_n(rst_n),
        .rx_datasb(wire_datasb),
        .rx_cksb(wire_cksb),
        .pkt_valid(rx_pkt_valid),
        .pkt_header(rx_pkt_header),
        .pkt_data(rx_pkt_data),
        .local_clk(local_clk)
    );
    
    // Clocks 
    initial begin
        clk = 0;
        forever #0.625 clk = ~clk;  // 800 MHz (1.25 ns period)
    end
    
    initial begin
        local_clk = 0;
        forever #5.0 local_clk = ~local_clk;    // Slower downstream processing clock
    end
    
    // Test Sequence
    initial begin
        $display("Starting Sideband SerDes Simulation...");
        rst_n = 0;
        tx_pkt_valid = 0;
        #20 rst_n = 1;
        
        // Wait for TX to be ready
        @(posedge clk iff tx_req_ready == 1'b1);
        
        // Test 1: Message Without Data (10010b) - Header only
        @(posedge clk);
        tx_pkt_valid <= 1;
        tx_pkt_header <= 64'h44000001_60004012;
        tx_pkt_has_data <= 0;
        @(posedge clk);
        tx_pkt_valid <= 0;
        
        // Wait for RX to assert Valid
        @(posedge local_clk iff rx_pkt_valid == 1'b1);
        if (rx_pkt_header === 64'h44000001_60004012)
            $display("Test 1 Passed: SerDes recovered Header %h.", rx_pkt_header);
        else
            $error("Test 1 Failed! Got Header: %h", rx_pkt_header);
        
        // Wait for 32-UI gap to finish
        @(posedge clk iff tx_req_ready == 1'b1);
        
        // Test 2: Message With Data (11011b) - Header + Data
        @(posedge clk);
        tx_pkt_valid <= 1;
        tx_pkt_header <= 64'hC71234AA_E03FC01B;
        tx_pkt_data <= 64'hFEEDFACE_CAFEBEEF;
        tx_pkt_has_data <= 1;
        @(posedge clk);
        tx_pkt_valid <= 0;
        
        @(posedge local_clk iff rx_pkt_valid == 1'b1);
        if (rx_pkt_header === 64'hC71234AA_E03FC01B && rx_pkt_data === 64'hFEEDFACE_CAFEBEEF)
            $display("Test 2 Passed: SerDes recovered Header %h and Data %h.",rx_pkt_header, rx_pkt_data);
        else    
            $error("Test 2 Failed! Header: %h, Data: %h", rx_pkt_header, rx_pkt_data);
        
        #20;
        $display("Sideband SerDes simulations completed successfully.");
        $finish;
    end
    
endmodule