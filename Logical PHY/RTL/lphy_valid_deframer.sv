`timescale 1ps / 1ps

module lphy_valid_deframer (
    input logic clk, 
    input logic rst_n, 
    
    // 8-bit Parallel Input from the Deserializer
    // (Bit 0 was received first on the wire)
    input logic [7:0] valid_frame_in,
    
    // Extracted Ouptuts
    output logic lane_valid,        // High if data is valid for this 8-UI block
    output logic credit_return,     // High if a Retimer credit is released
    output logic framing_err        // High if an illegal frame is received
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lane_valid <= 1'b0;
            credit_return <= 1'b0;
            framing_err <= 1'b0;
        end else begin
            // Default: no error
            framing_err <= 1'b0;
            
            // Decode the 8-UI Valid frame (Table 17 of the UCIe Spec)
            case (valid_frame_in)
                8'b1111_1111: begin
                    lane_valid <= 1'b1;
                    credit_return <= 1'b1;
                end
                8'b0000_1111: begin
                    // Asserts for the first 4 UI, de-asserts for the last 4 UI
                    lane_valid <= 1'b1;
                    credit_return <= 1'b0;
                end
                8'b1111_0000: begin
                    // De-asserts for the first 4 UI, asserts for the last 4 UI
                    lane_valid <= 1'b0;
                    credit_return <= 1'b1;
                end
                8'b0000_0000: begin
                    lane_valid <= 1'b0;
                    credit_return <= 1'b0;
                end
                default: begin
                    // Any other bit pattern implies a bit flip / Channel error
                    lane_valid <= 1'b0;
                    credit_return <= 1'b0;
                    framing_err <= 1'b1;
                end
            endcase
        end
    end

endmodule