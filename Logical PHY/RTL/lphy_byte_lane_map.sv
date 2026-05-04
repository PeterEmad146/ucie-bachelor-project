`timescale 1ps / 1ps

module lphy_byte_lane_map (
    input logic clk,
    input logic rst_n, 
    
    // Configuration
    input logic [1:0] link_width,       // 2'b00: x16, 2'b01: x32, 2'b10: x64
    
    // Interface from D2D Adapeter (64 Bytes per transfer)
    input logic lp_valid,
    input logic lp_irdy, 
    output logic pl_trdy, 
    input logic [511:0] lp_data,
    
    // Output to Physical Lanes (up to 64 active lanes, 1 Byte per lane)
    output logic lane_valid, 
    output logic [7:0] lane_data [63:0]
);

    logic [511:0] buffer;
    logic [2:0] chunk_cnt;
    logic busy;
    
    // The PHY is ready to accept a new 64-Byte payload chunk when it's not busy multiplexing
    assign pl_trdy = !busy;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer <= '0;
            chunk_cnt <= '0;
            busy <= 1'b0;
            lane_valid <= 1'b0;
            for (int i = 0; i < 64; i++) 
                lane_data[i] <= '0;
        end else begin
            // 1. PHASE 0: New Data Acceptance
            if (!busy && lp_valid && pl_trdy && lp_irdy) begin
                lane_valid <= 1'b1;
                buffer <= lp_data;      // Capture full payload
                
                case (link_width)
                    2'b10: begin    // x64
                        for (int i = 0; i < 64; i++) lane_data[i] <= lp_data[i*8 +: 8];
                        busy <= 1'b0;
                    end
                    2'b01: begin    // x32
                        for (int i = 0; i < 32; i++) lane_data[i] <= lp_data[i*8 +: 8];
                        busy <= 1'b1;
                        chunk_cnt <= 1;
                    end 
                    default: begin  // x16
                        for (int i = 0; i < 16; i++) lane_data[i] <= lp_data[i*8 +: 8];
                        busy <= 1'b1;
                        chunk_cnt <= 1;
                    end
                endcase
            end
            
            // 2. PHASES 1-3: Sequential Mapping
            else if (busy) begin
                lane_valid <= 1'b1;
                if (link_width == 2'b01 ) begin // x32 Finish
                    for (int i = 0; i < 32; i++) lane_data[i] <= buffer[(i+32)*8 +: 8];
                    busy <= 1'b0;
                end else begin  // x16 Continue
                    for (int i = 0; i < 16; i++) lane_data[i] <= buffer[(i + chunk_cnt*16)*8 +: 8];
                    if (chunk_cnt == 3) busy <= 1'b0;
                    else chunk_cnt <= chunk_cnt + 1;
                end
            end
            
            // 3. IDLE: Just clear valid, don't wipe the data lanes (Optional for power, good for debug)
            else begin
                lane_valid <= 1'b0;
            end
        end
    end

endmodule  