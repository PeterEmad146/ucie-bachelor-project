`timescale 1ps / 1ps

module lphy_valid_framer(
    input logic clk,
    input logic rst_n,
    
    // Inputs from TX Byte-to-Lane Mapper and Flow Control
    input logic lane_valid,     // High if data is currently being transmitted
    input logic credit_return,  // High if a Retimer credit needs to be released
    
    // 8-bit Parallel Output to the Serializer
    // (Bit 0 is transmitted first on the wire)
    output logic [7:0] valid_frame_out
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_frame_out <= 8'b0000_0000;
        end else begin
            // Implement Table 17: Valid framing for Retimers
            case ({credit_return, lane_valid})
                2'b11:  valid_frame_out <= 8'b1111_1111;    // Data Valid + 1 Credit
                2'b01:  valid_frame_out <= 8'b0000_1111;    // Data Valid + No Credit
                2'b10:  valid_frame_out <= 8'b1111_0000;    // No Data + 1 Credit
                2'b00:  valid_frame_out <= 8'b0000_0000;    // No Data + No Credit
            endcase
        end
    end

endmodule
