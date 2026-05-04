`timescale 1ps / 1ps

module lphy_tx_top #(
    parameter int NUM_LANES = 16        // 16 for Standard Package, 64 for Advanced Package
)(
    // Byte-rate clock: one cycle = 8 UIs = one byte per lane
    input logic clk,
    input logic rst_n,
    
    // Configuration
    input logic [1:0] link_width,       // 2'b00: x16, 2'b01: x32, 2'b10: x64
    input logic free_run_mode,          // 1: Clock never gates, 0: Dynamic clock gating enabled
    input logic select_valtrain,        // 0: Send per-lane ID pattern (MBINIT/SBINIT), 1: Send VALTRAIN pattern (MBTRAIN ValTrain substates)
    input logic txtrk_en,               // 1: TXTRK carries Phase-1 replica
    
    // Scrambling Control from LTSSM (MBINIT state)
    input logic scrambler_en,           // High during MBTRAIN and ACTIVE
    input logic load_seed,              // Pulled high to load initial seeds
    input logic [22:0] lane_seeds [63:0], 
    
    // Repair Control from LTSSM (MBINIT state)
    input logic repair_en,              // 1: Redundancy routing active
    input logic [63:0] ext_lane_failed_map, 
    
    input logic tx_training_en,         // 1: Send training pattern, 0: Send adapter data
    
    // Interface from D2D Adapter (RDI)
    input logic lp_valid, 
    input logic lp_irdy, 
    output logic pl_trdy, 
    input logic [511:0] lp_data, 
    input logic credit_return,          // From Flow Control for Retimer E2E Credits
    
    // =========================================================================
    // PARALLEL AFE BOUNDARY (Analog Front End Interface)
    // =========================================================================
    output logic [7:0] TXDATA [NUM_LANES-1:0], // 8-bit parallel data per lane
    output logic [7:0] TXVLD,                  // 8-bit parallel valid frame
    output logic [7:0] TXRD [3:0],             // 8-bit parallel redundant data
    
    // AFE Control Flags (Digital to Analog)
    output logic       tx_clock_en,            // Tells AFE to drive forwarded clock (includes postamble)
    output logic       tx_track_en             // Tells AFE to drive the track clock
);

    // Internal Signals
    logic [7:0] mapped_lane_data [63:0];    
    logic mapped_lane_valid;
    logic [7:0] tx_valid_frame;
    logic gated_tx_clk_en;  
    
    logic [7:0] scrambled_lane_data [63:0];
    logic [7:0] repaired_lane_data [63:0];
    logic [7:0] repaired_txrd_data [3:0];
    
    // 1. BYTE-TO-LANE MAPPER 
    lphy_byte_lane_map byte_mapper_int (
        .clk(clk), 
        .rst_n(rst_n), 
        .link_width(link_width), 
        .lp_valid(lp_valid), 
        .lp_irdy(lp_irdy), 
        .pl_trdy(pl_trdy), 
        .lp_data(lp_data), 
        .lane_valid(mapped_lane_valid), 
        .lane_data(mapped_lane_data)
    );
    
    // =========================================================================
    // PIPELINE ALIGNMENT STAGE
    // The valid framer has 1 cycle of sequential latency. We must delay the 
    // datapath and scrambler enable by 1 cycle to maintain exact alignment.
    // =========================================================================
    logic [7:0] mapped_lane_data_q [63:0];
    logic mapped_lane_valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mapped_lane_valid_q <= 1'b0;
            for (int i = 0; i < 64; i++) mapped_lane_data_q[i] <= 8'h00;
        end else begin
            mapped_lane_valid_q <= mapped_lane_valid;
            for (int i = 0; i < 64; i++) mapped_lane_data_q[i] <= mapped_lane_data[i];
        end
    end
    
    // 2. VALID FRAMER
    lphy_valid_framer valid_framer_inst (
        .clk(clk), 
        .rst_n(rst_n),
        .lane_valid(mapped_lane_valid), 
        .credit_return(credit_return),
        .valid_frame_out(tx_valid_frame)
    );
    
//    // 3. TX DYNAMIC CLOCK GATER (Enable Generation for AFE)
//    logic gated_tx_clk_internal;
//    lphy_clkgate_tx clkgate_inst (
//        .clk(clk), 
//        .rst_n(rst_n), 
//        .free_run_mode(free_run_mode), 
//        .valid_in(mapped_lane_valid),
//        .gated_clk(gated_tx_clk_internal)
//    );
    
//    // Extract the logical clock enable to hand over to the AFE's analog clock driver
//    always_ff @(posedge clk or negedge rst_n) begin
//        if (!rst_n)
//            gated_tx_clk_en <= 1'b0;
//        else
//            gated_tx_clk_en <= gated_tx_clk_internal;
//    end 
    
    // =========================================================================
    // TRAINING PATTERN GENERATOR ARRAY & MULTIPLEXER
    // Each lane gets its own lphy_pattern_gen instance wired to its lane index.
    // This ensures each lane transmits the correct per-lane-ID training pattern
    // as defined in UCIe Spec Tables 23 & 24.
    // select_valtrain (from LTSSM) switches between:
    //   0 -> Per-Lane ID pattern  (used during SBINIT / MBINIT calibration)
    //   1 -> VALTRAIN pattern     (used during MBTRAIN ValTrainCenter / ValTrainVref)
    // =========================================================================
    logic [15:0] training_pattern_out [NUM_LANES-1:0];
    logic [7:0]  pre_scramble_data    [63:0];

    genvar pg;
    generate
        for (pg = 0; pg < NUM_LANES; pg++) begin : gen_pattern_gens
            lphy_pattern_gen pattern_gen_inst (
                .lane_id       (8'(pg)),           // Each lane gets its own unique ID
                .select_valtrain(select_valtrain), // Controlled externally by LTSSM
                .pattern_out   (training_pattern_out[pg])
            );
        end
    endgenerate

    always_comb begin
        for (int j = 0; j < NUM_LANES; j++) begin
            if (tx_training_en) begin
                // Lower byte of the 16-bit pattern is sent first (LSB-first per UCIe spec)
                pre_scramble_data[j] = training_pattern_out[j][7:0];
            end else begin
                pre_scramble_data[j] = mapped_lane_data_q[j];
            end
        end
        // Unused lanes (indices >= NUM_LANES up to 63) default to 0
        for (int j = NUM_LANES; j < 64; j++) begin
            pre_scramble_data[j] = 8'h00;
        end
    end
    
    // 4. SCRAMBLER Array
    genvar i;
    generate
        for (i = 0; i < NUM_LANES; i++) begin : gen_scramblers
            lphy_scrambler scrambler_inst (
                .clk(clk), 
                .rst_n(rst_n), 
                .enable(scrambler_en & mapped_lane_valid_q), // FIXED
                .load_seed(load_seed), 
                .seed_in(lane_seeds[i]), 
                .data_in(pre_scramble_data[i]), 
                .data_out(scrambled_lane_data[i])
            );
        end
    endgenerate
    
    // 5. TX REPAIR MULTIPLEXER
    logic [63:0] tx_lane_failed_map;
    always_comb begin
        tx_lane_failed_map = repair_en ? ext_lane_failed_map : 64'h0;    
    end 
    
    lphy_repair_tx tx_repair_inst (
        .tx_logical_data(scrambled_lane_data), 
        .lane_failed(tx_lane_failed_map), 
        .tx_physical_data(repaired_lane_data), 
        .tx_redundant_data(repaired_txrd_data)
    );
    
    // =========================================================================
    // 6. PIPELINE TO AFE (Replaces Serializer)
    // =========================================================================
    // Instead of serializing, we register the parallel byte outputs to ensure
    // perfectly clean timing boundaries before the signals enter the AFE macro.
    logic [3:0] postamble_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            TXVLD <= 8'h00;
            for (int i = 0; i < NUM_LANES; i++) TXDATA[i] <= 8'h00;
            for (int i = 0; i < 4; i++)         TXRD[i]   <= 8'h00;
            
            tx_clock_en <= 1'b0;
            tx_track_en <= 1'b0;
            postamble_cnt <= 4'd2;
        end else begin
            TXVLD <= tx_valid_frame;
            for (int i = 0; i < NUM_LANES; i++) TXDATA[i] <= repaired_lane_data[i];
            for (int i = 0; i < 4; i++)         TXRD[i]   <= repaired_txrd_data[i];
            
            tx_track_en <= txtrk_en;
            
            // Generate AFE Logical Envelope (with exactly 2 cycle postamble)
            if (mapped_lane_valid_q) begin
                postamble_cnt <= 4'd0;
                tx_clock_en <= 1'b1;
            end else if (postamble_cnt < 4'd2) begin
                postamble_cnt <= postamble_cnt + 1'b1;
                tx_clock_en <= 1'b1;
            end else begin
                tx_clock_en <= free_run_mode;
            end
        end
    end
    
endmodule