`timescale 1ps / 1ps

module lphy_d2c_cal #(
    parameter int NUM_LANES = 64,
    parameter int PI_PHASE_MAX = 63,        // 64 total PI phase steps
    parameter int SETTLE_CYCLES = 32,       // Wait time for Analog PI to lock & pipeline to flush
    parameter int TEST_CYCLES = 128         // Number of UI to test per phase
)(
    input logic clk, 
    input logic rst_n, 
    
    // Control from LTSSM (e.g., MBTRAIN.DATATRAINCENTER state)
    input logic start_cal, 
    input logic [15:0] error_threshold,     // Max allowed errors to consider a phase "passing"
    
    // Data stream from RX Mainband (Parallel 8-bit Arrays)
    input logic [7:0] rx_data [NUM_LANES-1:0], 
    input logic [7:0] expected_data [NUM_LANES-1:0], 
    
    // Calibration Outputs to Analog Front End (AFE) and LTSSM
    output logic [5:0] pi_phase,            // Controls the physical Phase Interpolator
    output logic cal_done, 
    output logic cal_error                  // High if no open eye was found
);

    typedef enum logic [2:0] {
        ST_IDLE         = 3'b000, 
        ST_SET_PHASE    = 3'b001, 
        ST_WAIT_SETTLE  = 3'b010,           // ADDED: Crucial Analog/Pipeline Buffer
        ST_ACCUMULATE   = 3'b011, 
        ST_EVALUATE     = 3'b100, 
        ST_CALC_CENTER  = 3'b101, 
        ST_DONE         = 3'b110
    } state_t;

    state_t state, next_state;
    
    logic [5:0] current_phase;
    logic [15:0] cycle_cnt;
    logic [15:0] error_cnt;
    
    // Eye tracking register
    logic [5:0] left_edge;
    logic [5:0] right_edge;
    logic in_eye;
    logic eye_found;
    
    // Combinatorial mismatch detector for the 2D arrays
    logic cycle_has_error;
    always_comb begin
        cycle_has_error = 1'b0;
        for (int i = 0; i < NUM_LANES; i++) begin
            if (rx_data[i] !== expected_data[i]) begin
                cycle_has_error = 1'b1;
            end
        end
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            current_phase <= '0;
            cycle_cnt <= '0;
            error_cnt <= '0;
            left_edge <= '0;
            right_edge <= '0;
            in_eye <= 1'b0;
            eye_found <= 1'b0;
            pi_phase <= '0;
        end else begin
            state <= next_state;
            
            case (state)
                ST_IDLE: begin
                    current_phase <= '0;
                    left_edge <= '0;
                    right_edge <= '0;
                    in_eye <= 1'b0;
                    eye_found <= 1'b0;
                end
                
                ST_SET_PHASE: begin
                    pi_phase <= current_phase;      // Drive physical AFE pins
                    cycle_cnt <= '0;
                    error_cnt <= '0;
                end
                
                ST_WAIT_SETTLE: begin
                    // Let the AFE lock the new phase and the RX pipeline push clean data
                    cycle_cnt <= cycle_cnt + 1'b1;
                end
                
                ST_ACCUMULATE: begin
                    cycle_cnt <= cycle_cnt + 1'b1;
                    if (cycle_has_error) begin
                        error_cnt <= error_cnt + 1'b1;
                    end
                end
                
                ST_EVALUATE: begin
                    if (error_cnt <= error_threshold) begin
                        // Phase passed
                        if (!in_eye) begin
                            left_edge <= current_phase;
                            in_eye <= 1'b1;
                        end
                        right_edge <= current_phase;    
                        eye_found <= 1'b1;
                    end else begin
                        // Phase failed
                        if (in_eye) begin
                            in_eye <= 1'b0;             
                        end
                    end
                    
                    current_phase <= current_phase + 1'b1;
                end
                
                ST_CALC_CENTER: begin
                    if (eye_found) begin
                        // Note: A robust design would check if the eye wraps around 63 to 0.
                        // Assuming a contiguous eye for standard implementation:
                        pi_phase <= left_edge + ((right_edge - left_edge) >> 1);
                    end
                end
            endcase
        end
    end
    
    always_comb begin
        next_state = state;
        cal_done = 1'b0;
        cal_error = 1'b0;
        
        case (state)
            ST_IDLE: begin
                if (start_cal) next_state = ST_SET_PHASE;
            end
            
            ST_SET_PHASE: begin
                next_state = ST_WAIT_SETTLE;
            end
            
            ST_WAIT_SETTLE: begin
                if (cycle_cnt == SETTLE_CYCLES - 1) begin
                    next_state = ST_ACCUMULATE;
                end
            end
            
            ST_ACCUMULATE: begin
                // Need to offset by SETTLE_CYCLES because cycle_cnt didn't reset
                if (cycle_cnt == (SETTLE_CYCLES + TEST_CYCLES - 1)) begin
                    next_state = ST_EVALUATE;
                end
            end
            
            ST_EVALUATE: begin
                if (current_phase == PI_PHASE_MAX) next_state = ST_CALC_CENTER;
                else next_state = ST_SET_PHASE;
            end
            
            ST_CALC_CENTER: begin
                next_state = ST_DONE;
            end
            
            ST_DONE: begin
                cal_done = 1'b1;
                if (!eye_found) cal_error = 1'b1; 
                if (!start_cal) next_state = ST_IDLE;
            end 
        endcase
    end
endmodule