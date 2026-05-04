`timescale 1ps / 1ps

module lphy_rx_top #(
    parameter int NUM_LANES = 16    // 16 for Standard Package, 64 for Advanced Package
)(
    input logic clk, 
    input logic rst_n, 
    
    // Configuration 
    input logic free_run_mode,  
    
    // Control Signals from LTSSM
    input logic en_reversal_check, 
    output logic reversal_detected, 
    output logic reversal_check_done, 
    output logic framing_err, 
    
    output logic [63:0] detected_lane_failures,
    output logic check_done,
    
    // Descrambling Control from LTSSM
    input logic descrambler_en, 
    input logic load_seed, 
    input logic [22:0] lane_seeds [63:0], 
    
    // Repair Control from LTSSM
    input logic repair_en, 
    input logic en_lane_check, 
    
    // Interface to D2D Adapter (RDI)
    output logic pl_valid, 
    output logic [7:0] pl_data [NUM_LANES - 1 : 0], 
    output logic credit_return,
    output logic rx_gated_clk,      
    
    // =========================================================================
    // PARALLEL AFE BOUNDARY (Analog Front End Interface)
    // =========================================================================
    input logic [7:0] RXDATA [NUM_LANES-1:0],   // 8-bit parallel data from AFE
    input logic [7:0] RXVLD,                    // 8-bit parallel valid frame
    input logic [7:0] RXRD [3:0],               // 8-bit parallel redundant data
    input logic       RXTRK,                    // Unused in RTL (Drives AFE CDR)
    output logic      rx_en                     // Tells AFE to power up Receivers
);

    // Power up AFE receivers automatically when out of reset
    assign rx_en = 1'b1; 
    
    // Internal pipeline signals
    logic [7:0] rx_lane_data_64 [63:0]; 
    logic [7:0] rx_lane_data_NUM [NUM_LANES-1:0];
    logic [7:0] rx_txrd_data_raw [3:0];
    logic [7:0] rx_valid_frame;
    
    logic internal_lane_valid;
    logic internal_lane_valid_q;    // 1-cycle delayed: aligns with rx_lane_data_NUM (which is already 1 FF deep)
    logic internal_credit_return;
    
    // Pipeline alignment: rx_lane_data_NUM is latched once (AFE latch).
    // internal_lane_valid is latched twice (AFE latch + valid_deframer FF).
    // Delay internal_lane_valid by 1 more cycle so lane_id_detect sees aligned data + valid.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) internal_lane_valid_q <= 1'b0;
        else        internal_lane_valid_q <= internal_lane_valid;
    end
    
    // =========================================================================
    // 1. AFE PIPELINE LATCH 
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_valid_frame <= 8'h00;
            for (int i = 0; i < 64; i++)        rx_lane_data_64[i] <= 8'h00;
            for (int i = 0; i < NUM_LANES; i++) rx_lane_data_NUM[i] <= 8'h00;
            for (int i = 0; i < 4; i++)         rx_txrd_data_raw[i] <= 8'h00;
        end else begin
            rx_valid_frame <= RXVLD;
            
            // Latch exactly NUM_LANES for the normal datapath
            for (int i = 0; i < NUM_LANES; i++) begin
                rx_lane_data_NUM[i] <= RXDATA[i];
                rx_lane_data_64[i]  <= RXDATA[i];
            end
            
            // Safely pad the upper lanes with 0 to prevent [VRFC 10-323] array crashes in Repair Mux
            for (int i = NUM_LANES; i < 64; i++) begin
                rx_lane_data_64[i] <= 8'h00;
            end
            
            for (int i = 0; i < 4; i++) rx_txrd_data_raw[i] <= RXRD[i];
        end
    end
    
    // =========================================================================
    // 2. LANE ID DETECTION
    // =========================================================================
    // Use an intermediate NUM_LANES-wide wire so the port connection is type-correct,
    // then zero-extend to 64 bits for the top-level output. Without this, bits
    // [63:NUM_LANES] of detected_lane_failures are never driven when NUM_LANES < 64.
    logic [NUM_LANES-1:0] lane_failed_narrow;

    lphy_lane_id_detect #(
        .NUM_LANES(NUM_LANES)
    ) lphy_id_detect_inst (
        .clk(clk), 
        .rst_n(rst_n), 
        .rx_lane_data_in(rx_lane_data_NUM), 
        .rx_lane_valid(internal_lane_valid_q),  // Use delayed valid to match data pipeline depth
        .en_lane_check(en_lane_check), 
        .is_reversed(reversal_detected), 
        .lane_failed(lane_failed_narrow), 
        .check_done(check_done)
    );

    // Zero-extend to the full 64-bit output width; upper bits are hardwired to 0
    // (no redundant lanes failed above NUM_LANES in a correctly-configured link)
    assign detected_lane_failures = {{(64-NUM_LANES){1'b0}}, lane_failed_narrow};
    
    // Suppress lint warnings for unused analog clock pins
    logic _unused;
    assign _unused = ^{RXTRK};
    
    // =========================================================================
    // 3. RX REPAIR MULTIPLEXER
    // =========================================================================
    logic [7:0] rx_repaired_data_64 [63:0];
    logic [63:0] rx_lane_failed_map;
    
    always_comb begin
        rx_lane_failed_map = repair_en ? detected_lane_failures : 64'h0;
    end
    
    lphy_repair_rx rx_repair_inst (
        .rx_physical_data(rx_lane_data_64), 
        .rx_redundant_data(rx_txrd_data_raw), 
        .lane_failed(rx_lane_failed_map), 
        .rx_logical_data(rx_repaired_data_64)
    );
    
    // =========================================================================
    // 4. PIPELINE ALIGNMENT BUFFER
    // =========================================================================
    logic [7:0] rx_lane_data_q [NUM_LANES-1:0];
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_LANES; i++) rx_lane_data_q[i] <= 8'h00;
        end else begin
            // Truncate safely back down to NUM_LANES
            for (int i = 0; i < NUM_LANES; i++) rx_lane_data_q[i] <= rx_repaired_data_64[i];
        end
    end
    
    // =========================================================================
    // 5. VALID DEFRAMER
    // =========================================================================
    lphy_valid_deframer valid_deframer_inst (
        .clk(clk), 
        .rst_n(rst_n), 
        .valid_frame_in(rx_valid_frame), 
        .lane_valid(internal_lane_valid), 
        .credit_return(internal_credit_return), 
        .framing_err(framing_err)
    );
    
    // ALIGNMENT FIX: The Derotator below has a flip-flop. We MUST delay the valid 
    // and credit flags by 1 cycle so they hit the Adapter at the same time as the data!
    logic pl_valid_reg;
    logic pl_credit_return_reg;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pl_valid_reg <= 1'b0;
            pl_credit_return_reg <= 1'b0;
        end else begin
            pl_valid_reg <= internal_lane_valid;
            pl_credit_return_reg <= internal_credit_return;
        end
    end
    
    assign pl_valid = pl_valid_reg;
    assign credit_return = pl_credit_return_reg;
    
    // =========================================================================
    // 6. LANE DEROTATOR & DESKEW
    // =========================================================================
    logic [7:0] derotated_data [NUM_LANES-1:0];
    
    lphy_lane_derotate #(
        .NUM_LANES(NUM_LANES)
    ) lane_derotate_inst (
        .clk(clk), 
        .rst_n(rst_n), 
        .rx_lane_data_in(rx_lane_data_q), 
        .rx_lane_valid(internal_lane_valid), 
        .en_reversal_check(en_reversal_check), 
        .reversal_detected(reversal_detected), 
        .reversal_check_done(reversal_check_done), 
        .rx_lane_data_out(derotated_data)  
    );
    
    // =========================================================================
    // 7. DESCRAMBLER ARRAY
    // =========================================================================
    genvar i; 
    generate
        for (i = 0; i < NUM_LANES; i++) begin : gen_descramblers
            lphy_descrambler descrambler_inst (
                .clk(clk), 
                .rst_n(rst_n), 
                .enable(descrambler_en & pl_valid_reg), // Use aligned valid
                .load_seed(load_seed), 
                .seed_in(lane_seeds[i]), 
                .data_in(derotated_data[i]), 
                .data_out(pl_data[i])
            );
        end
    endgenerate
    
    // =========================================================================
    // 8. RX CLOCK GATER
    // =========================================================================
    lphy_clkgate_rx clkgate_rx_inst (
        .clk(clk),
        .rst_n(rst_n), 
        .free_run_mode(free_run_mode), 
        .valid_in(internal_lane_valid), 
        .gated_clk(rx_gated_clk)
    );

endmodule