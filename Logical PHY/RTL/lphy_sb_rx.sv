`timescale 1ns / 1ps

module lphy_sb_rx (
    input logic rst_n,
    
    // Physical Sideband Pins from Remote Die
    input logic RXDATASB,
    input logic RXCKSB,        // Gated 800 MHz strobe from TX
    
    // Interface to Sideband Packet Decoder
    output logic pkt_valid,
    output logic [63:0] pkt_header,
    output logic [63:0] pkt_data,
    
    // Recovery clock domain for the synchronous downstream logic
    input logic local_clk
);

    logic [63:0] shift_reg;
    logic [6:0] bit_cnt;
    logic expecting_data;

    logic [63:0] latched_hdr;
    logic [63:0] latched_data;
    logic req_toggle;

        
    // Sample data on the falling edge of the forwarded strobe
    always_ff @(negedge RXCKSB or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg      <= '0;
            bit_cnt        <= '0;
            expecting_data <= 1'b0;
            latched_hdr    <= '0;
            latched_data   <= '0;
            req_toggle <= 1'b0;
        end else begin
            // Shift in MSB
            shift_reg <= {RXDATASB, shift_reg[63:1]};
            
            if (bit_cnt == 63) begin
                bit_cnt <= '0;
                if (!expecting_data) begin
                    latched_hdr <= {RXDATASB, shift_reg[63:1]};
                    
                    // Use the incoming bit and shift register to check opcode
                    if (shift_reg[5:1] == 5'b00001 || 
                        shift_reg[5:1] == 5'b00101 || 
                        shift_reg[5:1] == 5'b01001 || 
                        shift_reg[5:1] == 5'b01101 ||
                        shift_reg[5:1] == 5'b10001 || 
                        shift_reg[5:1] == 5'b11001 || 
                        shift_reg[5:1] == 5'b11011) begin
                        expecting_data <= 1'b1;
                    end else begin
                        latched_data <= '0;
                        req_toggle <= ~req_toggle;
                    end
                end else begin
                    // Received the data phase
                    latched_data   <= {RXDATASB, shift_reg[63:1]};
                    expecting_data <= 1'b0;
                    req_toggle <= ~req_toggle;
                end 
            end else begin
                bit_cnt <= bit_cnt + 1'b1;
            end 
        end
    end
    
    // Clock domain crossing (CDC) from RXCKSB domain to local_clk domain
    // A simple 2-flop synchronizer is used to flag when the full packet is ready.
    logic req_sync1, req_sync2;
    
    always_ff @(posedge local_clk or negedge rst_n) begin
        if (!rst_n) begin
            req_sync1 <= 1'b0;
            req_sync2 <= 1'b0;
            pkt_valid <= 1'b0;
            pkt_header <= '0;
            pkt_data <= '0;
        end else begin
            req_sync1 <= req_toggle;
            req_sync2 <= req_sync1;
            
            // Detect edge on the toggle signal
            if (req_sync1 != req_sync2) begin
                pkt_valid <= 1'b1;
                pkt_header <= latched_hdr;
                pkt_data <= latched_data;
            end else begin
                pkt_valid <= 1'b0;
            end
        end
    end
    
endmodule