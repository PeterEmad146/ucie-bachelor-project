`timescale 1ps / 1ps

module lphy_width_degrade #(
    parameter int NUM_LANES = 64
)(
    // Control signal from Data Repair Controller / LTSSM
    input logic [1:0] lane_map, // 2'b11: Full, 2'b01: Lower Half, 2'b10: Upper Half, 2'b00: Fail
    
    // TX Data Path (8-bit Parallel Bytes)
    input  logic [7:0] tx_logical_data [NUM_LANES-1:0], 
    output logic [7:0] tx_physical_data [NUM_LANES-1:0], 
    
    // RX Data Path (8-bit Parallel Bytes)
    input  logic [7:0] rx_physical_data [NUM_LANES-1:0], 
    output logic [7:0] rx_logical_data [NUM_LANES-1:0] 
);

    localparam int HALF_LANES = NUM_LANES / 2;

    // -----------------------------------------------------------------
    // TX Width Degradation Multiplexing
    // -----------------------------------------------------------------
    always_comb begin
        // Default: Park all physical transmit lanes at 0 to save power
        for (int i = 0; i < NUM_LANES; i++) begin
            tx_physical_data[i] = 8'h00; 
        end
        
        if (lane_map == 2'b11) begin
            // Full width (1:1 Mapping)
            for (int i = 0; i < NUM_LANES; i++) begin
                tx_physical_data[i] = tx_logical_data[i];
            end
        end
        else if (lane_map == 2'b01) begin
            // Degrade to Lower Half (Logical 0 -> Physical 0)
            for (int i = 0; i < HALF_LANES; i++) begin
                tx_physical_data[i] = tx_logical_data[i];
            end
        end
        else if (lane_map == 2'b10) begin
            // Degrade to Upper Half (Logical 0 -> Physical HALF)
            for (int i = 0; i < HALF_LANES; i++) begin
                tx_physical_data[i + HALF_LANES] = tx_logical_data[i];
            end
        end    
    end
    
    // -----------------------------------------------------------------
    // RX Width Degradation Multiplexing
    // -----------------------------------------------------------------
    always_comb begin
        // Default: Zero out all logical receive lanes
        for (int i = 0; i < NUM_LANES; i++) begin
            rx_logical_data[i] = 8'h00; 
        end
        
        if (lane_map == 2'b11) begin
            // Full width (1:1 Mapping)
            for (int i = 0; i < NUM_LANES; i++) begin
                rx_logical_data[i] = rx_physical_data[i];
            end
        end
        else if (lane_map == 2'b01) begin
            // Degraded to Lower Half (Physical 0 -> Logical 0)
            for (int i = 0; i < HALF_LANES; i++) begin
                rx_logical_data[i] = rx_physical_data[i];
            end
        end
        else if (lane_map == 2'b10) begin
            // Degrade to Upper Half (Physical HALF -> Logical 0)
            for (int i = 0; i < HALF_LANES; i++) begin
                rx_logical_data[i] = rx_physical_data[i + HALF_LANES];
            end
        end 
    end
endmodule