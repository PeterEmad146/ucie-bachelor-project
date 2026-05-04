`timescale 1ps / 1ps

module lphy_ltssm #(
    parameter int RESET_TIMER_CYCLES  = 400000,  // 4ms for lphy_ltssm_reset
    parameter int SBINIT_TIMEOUT      = 800000,  // 8ms for lphy_ltssm_sbinit
    parameter int MBINIT_TIMEOUT      = 800000,  // 8ms for lphy_ltssm_mbinit
    parameter int MBTRAIN_TIMEOUT     = 800000,  // 8ms for lphy_ltssm_mbtrain
    parameter int LINKINIT_TIMEOUT    = 800000,  // 8ms for lphy_ltssm_linkinit
    parameter int PHYRETRAIN_TIMEOUT  = 800000,  // 8ms for lphy_ltssm_phyretrain
    parameter int TRAINERROR_TIMEOUT  = 800000   // 8ms for lphy_ltssm_trainerror
) (
    input  logic clk,
    input  logic rst_n,
    
    // =========================================================================
    // 1. ADAPTER INTERFACE (RDI)
    // =========================================================================
    input  logic       start_link_training,
    input  logic [3:0] lp_state_req,
    input  logic       lp_linkerror,
    input  logic       lp_stallack,
    
    output logic [3:0] pl_state_sts,
    output logic       pl_inband_pres,
    output logic       pl_stallreq,
    output logic       rdi_to_retrain,
    output logic       phy_in_retrain,
    
    // =========================================================================
    // 2. GLOBAL HARDWARE STATUS
    // =========================================================================
    input  logic       power_stable,
    input  logic       sb_clk_stable,
    input  logic       mb_clk_stable,
    input  logic       mb_clk_slow,
    input  logic       soc_reset_n,
    input  logic       package_type,      // 0: Advanced, 1: Standard
    
    // =========================================================================
    // 3. SIDEBAND RX (Inputs from Sideband Network)
    // =========================================================================
    input  logic [3:0] rx_pattern_detected,
    input  logic       rx_msg_out_of_reset,
    input  logic       rx_msg_done_req,
    input  logic       rx_msg_done_resp,
    
    input  logic       rx_req_active,      input logic rx_rsp_active,
    input  logic       rx_req_l1,          input logic rx_rsp_l1,
    input  logic       rx_req_l2,          input logic rx_rsp_l2,
    input  logic       rx_req_linkreset,   input logic rx_rsp_linkreset,
    input  logic       rx_req_disable,     input logic rx_rsp_disable,
    input  logic       rx_req_retrain,     input logic rx_rsp_retrain,
    
    input  logic       rx_req_linkerror,
    input  logic       rx_trainerror_req,  input logic rx_trainerror_resp,
    
    input  logic       rx_retrain_init_req,  input logic rx_retrain_init_resp,
    input  logic       rx_retrain_start_req, input logic rx_retrain_start_resp,
    input  logic [2:0] rx_retrain_enc,
    
    // =========================================================================
    // 4. SIDEBAND TX (Outputs to Sideband Network)
    // =========================================================================
    output logic       tx_send_pattern,
    output logic       tx_msg_out_of_reset,
    output logic       tx_msg_done_req,
    output logic       tx_msg_done_resp,
    output logic [2:0] sb_repair_sel,
    
    output logic       tx_req_active,      output logic tx_rsp_active,
    output logic       tx_req_l1,          output logic tx_rsp_l1,
    output logic       tx_req_l2,          output logic tx_rsp_l2,
    output logic       tx_req_linkreset,   output logic tx_rsp_linkreset,
    output logic       tx_req_disable,     output logic tx_rsp_disable,
    output logic       tx_req_retrain,     output logic tx_rsp_retrain,
    
    output logic       tx_req_linkerror,
    output logic       tx_trainerror_req,  output logic tx_trainerror_resp,
    
    output logic       tx_retrain_init_req,  output logic tx_retrain_init_resp,
    output logic       tx_retrain_start_req, output logic tx_retrain_start_resp,
    output logic [2:0] tx_retrain_enc,
    
    // =========================================================================
    // 5. INTERNAL REPAIR & CALIBRATION STATUS (Inputs)
    // =========================================================================
    input  logic param_done, cal_done, repairclk_done, repairval_done, 
    input  logic reversal_done, repairmb_done,
    input  logic valvref_done, datavref_done, speedidle_done, txselfcal_done, 
    input  logic rxclkcal_done, valtraincenter_done, valtrainvref_done, 
    input  logic datatraincenter1_done, datatrainvref_done, rxdeskew_done, 
    input  logic datatraincenter2_done,
    input  logic linkspeed_done, linkspeed_error, needs_repair, needs_speed_degrade, 
    input  logic repair_done,
    
    input  logic cal_error, is_unrepairable, 
    input  logic internal_retrain_req, internal_error_req,
    input  logic [2:0] local_retrain_enc,   // PHYRETRAIN encoding: 001=TXSELFCAL, 010=SPEEDIDLE, 100=REPAIR
    
    // =========================================================================
    // 6. DATAPATH & AFE CONTROLS (Outputs)
    // =========================================================================
    output logic phy_reset_active,
    output logic lfsr_reset,
    output logic clear_start_training,
    output logic tx_training_en,
    output logic scrambler_en,
    output logic descrambler_en,
    output logic repair_en,
    
    output logic en_param, en_cal, en_repairclk, en_repairval, en_reversal, en_repairmb,
    output logic en_valvref, en_datavref, en_speedidle, en_txselfcal, en_rxclkcal, 
    output logic en_valtraincenter, en_valtrainvref, en_datatraincenter1, en_datatrainvref, 
    output logic en_rxdeskew, en_datatraincenter2, en_linkspeed, en_repair_state
);

    // =========================================================================
    // INTERNAL NERVOUS SYSTEM (FSM Enables and Exits)
    // =========================================================================
    logic en_reset, en_sbinit, en_mbinit, en_mbtrain, en_linkinit;
    logic en_active, en_l1, en_l2, en_phyretrain, en_trainerror;

    logic rst_exit_sbinit;
    logic sb_exit_mbinit, sb_exit_error;
    logic mb_exit_mbtrain, mb_exit_error;
    logic trn_exit_linkinit, trn_exit_error;
    logic lnk_exit_active, lnk_exit_error;
    
    logic act_exit_l1, act_exit_l2, act_exit_linkreset;
    logic act_exit_disable, act_exit_retrain, act_exit_error;
    
    logic pm_exit_speedidle, pm_exit_reset;
    
    logic ret_exit_txselfcal, ret_exit_speedidle, ret_exit_repair, ret_exit_error;
    logic err_exit_reset;

    // RDI Multiplexing signals
    logic [3:0] active_pl_state_sts;
    logic [3:0] pm_pl_state_sts;
    
    // Internal Sideband Multiplexing Wires
    logic linkinit_tx_req_active, linkinit_tx_rsp_active;
    logic pm_tx_req_active, pm_tx_rsp_active;
    
    // Sticky latch for RDI LinkError status
    // lp_linkerror is a 1-cycle pulse from the adapter, but the TRAINERROR
    // sub-module needs a level signal to hold in ST_WAIT_RDI.
    logic rdi_linkerror_latch;

    // =========================================================================
    // SUB-MODULE INSTANTIATIONS
    // =========================================================================

    lphy_ltssm_reset #(.CLK_CYCLES_4MS(RESET_TIMER_CYCLES)) u_reset (
        .clk(clk), .rst_n(rst_n),
        .power_stable(power_stable), .sb_clk_stable(sb_clk_stable),
        .mb_clk_stable(mb_clk_stable), .mb_clk_slow(mb_clk_slow),
        .soc_reset_n(soc_reset_n), .start_link_training(start_link_training),
        .en_reset(en_reset),
        .exit_to_sbinit(rst_exit_sbinit), .phy_reset_active(phy_reset_active)
    );

    lphy_ltssm_sbinit #(.TIMEOUT_CYCLES(SBINIT_TIMEOUT)) u_sbinit (
        .clk(clk), .rst_n(rst_n),
        .en_sbinit(en_sbinit), .package_type(package_type),
        .rx_pattern_detected(rx_pattern_detected), .rx_msg_out_of_reset(rx_msg_out_of_reset),
        .rx_msg_done_req(rx_msg_done_req), .rx_msg_done_resp(rx_msg_done_resp),
        .tx_send_pattern(tx_send_pattern), .tx_msg_out_of_reset(tx_msg_out_of_reset),
        .tx_msg_done_req(tx_msg_done_req), .tx_msg_done_resp(tx_msg_done_resp),
        .sb_repair_sel(sb_repair_sel),
        .exit_to_mbinit(sb_exit_mbinit), .exit_to_trainerror(sb_exit_error)
    );

    lphy_ltssm_mbinit #(.TIMEOUT_CYCLES(MBINIT_TIMEOUT)) u_mbinit (
        .clk(clk), .rst_n(rst_n),
        .en_mbinit(en_mbinit), .package_type(package_type),
        .param_done(param_done), .cal_done(cal_done), .repairclk_done(repairclk_done),
        .repairval_done(repairval_done), .reversal_done(reversal_done), .repairmb_done(repairmb_done),
        .substate_error(is_unrepairable),
        .en_param(en_param), .en_cal(en_cal), .en_repairclk(en_repairclk),
        .en_repairval(en_repairval), .en_reversal(en_reversal), .en_repairmb(en_repairmb),
        .exit_to_mbtrain(mb_exit_mbtrain), .exit_to_trainerror(mb_exit_error)
    );

    lphy_ltssm_mbtrain #(.TIMEOUT_CYCLES(MBTRAIN_TIMEOUT)) u_mbtrain (
        .clk(clk), .rst_n(rst_n),
        .en_mbtrain(en_mbtrain), .package_type(package_type),
        .valvref_done(valvref_done), .datavref_done(datavref_done), .speedidle_done(speedidle_done),
        .txselfcal_done(txselfcal_done), .rxclkcal_done(rxclkcal_done), .valtraincenter_done(valtraincenter_done),
        .valtrainvref_done(valtrainvref_done), .datatraincenter1_done(datatraincenter1_done),
        .datatrainvref_done(datatrainvref_done), .rxdeskew_done(rxdeskew_done), .datatraincenter2_done(datatraincenter2_done),
        .linkspeed_done(linkspeed_done), .linkspeed_error(linkspeed_error), .needs_repair(needs_repair),
        .needs_speed_degrade(needs_speed_degrade), .repair_done(repair_done), .substate_error(cal_error),
        .en_valvref(en_valvref), .en_datavref(en_datavref), .en_speedidle(en_speedidle),
        .en_txselfcal(en_txselfcal), .en_rxclkcal(en_rxclkcal), .en_valtraincenter(en_valtraincenter),
        .en_valtrainvref(en_valtrainvref), .en_datatraincenter1(en_datatraincenter1), .en_datatrainvref(en_datatrainvref),
        .en_rxdeskew(en_rxdeskew), .en_datatraincenter2(en_datatraincenter2), .en_linkspeed(en_linkspeed),
        .en_repair(en_repair_state),
        .exit_to_linkinit(trn_exit_linkinit), .exit_to_trainerror(trn_exit_error)
    );

    lphy_ltssm_linkinit #(.TIMEOUT_CYCLES(LINKINIT_TIMEOUT)) u_linkinit (
        .clk(clk), .rst_n(rst_n),
        .en_linkinit(en_linkinit), .lp_state_req(lp_state_req),
        .rx_req_active(rx_req_active), .rx_rsp_active(rx_rsp_active),
        
        // FIXED: Map to internal wires instead of top-level port
        .tx_req_active(linkinit_tx_req_active), 
        .tx_rsp_active(linkinit_tx_rsp_active),
        
        .lfsr_reset(lfsr_reset), .clear_start_training(clear_start_training),
        .exit_to_active(lnk_exit_active), .exit_to_trainerror(lnk_exit_error)
    );

    lphy_ltssm_active u_active (
        .clk(clk), .rst_n(rst_n),
        .en_active(en_active), .lp_state_req(lp_state_req), .lp_linkerror(lp_linkerror),
        .pl_state_sts(active_pl_state_sts),
        .rx_req_l1(rx_req_l1), .rx_rsp_l1(rx_rsp_l1),
        .rx_req_l2(rx_req_l2), .rx_rsp_l2(rx_rsp_l2),
        .rx_req_linkreset(rx_req_linkreset), .rx_rsp_linkreset(rx_rsp_linkreset),
        .rx_req_disable(rx_req_disable), .rx_rsp_disable(rx_rsp_disable),
        .rx_req_retrain(rx_req_retrain), .rx_rsp_retrain(rx_rsp_retrain),
        .rx_req_linkerror(rx_req_linkerror),
        .tx_req_l1(tx_req_l1), .tx_rsp_l1(tx_rsp_l1),
        .tx_req_l2(tx_req_l2), .tx_rsp_l2(tx_rsp_l2),
        .tx_req_linkreset(tx_req_linkreset), .tx_rsp_linkreset(tx_rsp_linkreset),
        .tx_req_disable(tx_req_disable), .tx_rsp_disable(tx_rsp_disable),
        .tx_req_retrain(tx_req_retrain), .tx_rsp_retrain(tx_rsp_retrain),
        .tx_req_linkerror(tx_req_linkerror),
        .internal_retrain_req(internal_retrain_req), .internal_error_req(internal_error_req),
        .scrambling_en(scrambler_en),
        .exit_to_l1(act_exit_l1), .exit_to_l2(act_exit_l2), .exit_to_linkreset(act_exit_linkreset),
        .exit_to_disable(act_exit_disable), .exit_to_retrain(act_exit_retrain), .exit_to_trainerror(act_exit_error)
    );

    lphy_ltssm_pm u_pm (
        .clk(clk), .rst_n(rst_n),
        .en_l1(en_l1), .en_l2(en_l2),
        .lp_state_req(lp_state_req), .pl_state_sts(pm_pl_state_sts),
        .rx_req_active(rx_req_active), .rx_rsp_active(rx_rsp_active),
        
        // FIXED: Map to internal wires instead of top-level port
        .tx_req_active(pm_tx_req_active), 
        .tx_rsp_active(pm_tx_rsp_active),
        
        .exit_to_speedidle(pm_exit_speedidle), .exit_to_reset(pm_exit_reset)
    );

    lphy_ltssm_phyretrain #(.TIMEOUT_CYCLES(PHYRETRAIN_TIMEOUT)) u_phyretrain (
        .clk(clk), .rst_n(rst_n),
        .en_phyretrain(en_phyretrain),
        .local_retrain_trigger(internal_retrain_req), .local_retrain_enc(local_retrain_enc), 
        .pl_stallreq(pl_stallreq), .lp_stallack(lp_stallack),
        .rx_retrain_init_req(rx_retrain_init_req), .rx_retrain_init_resp(rx_retrain_init_resp),
        .rx_retrain_start_req(rx_retrain_start_req), .rx_retrain_enc(rx_retrain_enc), .rx_retrain_start_resp(rx_retrain_start_resp),
        .tx_retrain_init_req(tx_retrain_init_req), .tx_retrain_init_resp(tx_retrain_init_resp),
        .tx_retrain_start_req(tx_retrain_start_req), .tx_retrain_start_resp(tx_retrain_start_resp),
        .tx_retrain_enc(tx_retrain_enc),
        .rdi_to_retrain(rdi_to_retrain), .phy_in_retrain(phy_in_retrain),
        .exit_to_txselfcal(ret_exit_txselfcal), .exit_to_speedidle(ret_exit_speedidle),
        .exit_to_repair(ret_exit_repair), .exit_to_trainerror(ret_exit_error)
    );

    lphy_ltssm_trainerror #(.TIMEOUT_CYCLES(TRAINERROR_TIMEOUT)) u_trainerror (
        .clk(clk), .rst_n(rst_n),
        .en_trainerror(en_trainerror),
        .rx_trainerror_req(rx_trainerror_req), .rx_trainerror_resp(rx_trainerror_resp),
        .rdi_in_linkerror(lp_linkerror), // Directly use the RDI signal level
        .tx_trainerror_req(tx_trainerror_req), .tx_trainerror_resp(tx_trainerror_resp),
        .exit_to_reset(err_exit_reset)
    );

    // =========================================================================
    // MASTER FSM ORCHESTRATOR
    // =========================================================================
    typedef enum logic [3:0] {
        ST_RESET       = 4'h0,
        ST_SBINIT      = 4'h1,
        ST_MBINIT      = 4'h2,
        ST_MBTRAIN     = 4'h3,
        ST_LINKINIT    = 4'h4,
        ST_ACTIVE      = 4'h5,
        ST_L1          = 4'h6,
        ST_L2          = 4'h7,
        ST_PHYRETRAIN  = 4'h8,
        ST_TRAINERROR  = 4'h9,
        ST_LINKRESET   = 4'hA,
        ST_DISABLED    = 4'hB
    } ltssm_state_t;

    ltssm_state_t state, next_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= ST_RESET;
        else        state <= next_state;
    end

    always_comb begin
        next_state    = state;
        en_reset      = 1'b0;
        en_sbinit     = 1'b0;
        en_mbinit     = 1'b0;
        en_mbtrain    = 1'b0;
        en_linkinit   = 1'b0;
        en_active     = 1'b0;
        en_l1         = 1'b0;
        en_l2         = 1'b0;
        en_phyretrain = 1'b0;
        en_trainerror = 1'b0;
        
        pl_inband_pres = 1'b0;
        pl_state_sts   = 4'b0000;
        
        case (state)
            ST_RESET: begin
                en_reset = 1'b1;
                pl_state_sts = 4'b0000;
                if (rst_exit_sbinit) next_state = ST_SBINIT;
            end
            
            ST_SBINIT: begin
                en_sbinit = 1'b1;
                pl_state_sts = 4'b0000; 
                if (sb_exit_mbinit) next_state = ST_MBINIT;
                else if (sb_exit_error) next_state = ST_TRAINERROR;
            end
            
            ST_MBINIT: begin
                en_mbinit = 1'b1;
                pl_state_sts = 4'b0000; 
                if (mb_exit_mbtrain) next_state = ST_MBTRAIN;
                else if (mb_exit_error) next_state = ST_TRAINERROR;
            end
            
            ST_MBTRAIN: begin
                en_mbtrain = 1'b1;
                pl_state_sts = 4'b0000;
                if (trn_exit_linkinit) next_state = ST_LINKINIT;
                else if (trn_exit_error) next_state = ST_TRAINERROR;
            end
            
            ST_LINKINIT: begin
                en_linkinit = 1'b1;
                pl_state_sts = 4'b0000;
                pl_inband_pres = 1'b1; 
                if (lnk_exit_active) next_state = ST_ACTIVE;
                else if (lnk_exit_error) next_state = ST_TRAINERROR;
            end
            
            ST_ACTIVE: begin
                en_active = 1'b1;
                pl_state_sts = active_pl_state_sts; // Driven by active sub-module
                pl_inband_pres = 1'b1;
                
                if (act_exit_error) next_state = ST_TRAINERROR;
                else if (act_exit_disable) next_state = ST_DISABLED;
                else if (act_exit_linkreset) next_state = ST_LINKRESET;
                else if (act_exit_retrain) next_state = ST_PHYRETRAIN;
                else if (act_exit_l1) next_state = ST_L1;
                else if (act_exit_l2) next_state = ST_L2;
            end
            
            ST_L1: begin
                en_l1 = 1'b1;
                pl_state_sts = pm_pl_state_sts; // Driven by PM sub-module
                pl_inband_pres = 1'b1;
                if (pm_exit_speedidle) next_state = ST_MBTRAIN;
            end
            
            ST_L2: begin
                en_l2 = 1'b1;
                pl_state_sts = pm_pl_state_sts;
                pl_inband_pres = 1'b1;
                if (pm_exit_reset) next_state = ST_RESET; 
            end
            
            ST_PHYRETRAIN: begin
                en_phyretrain = 1'b1;
                pl_state_sts = 4'b1011;
                pl_inband_pres = 1'b1;
                if (ret_exit_txselfcal || ret_exit_speedidle || ret_exit_repair) next_state = ST_MBTRAIN;
                else if (ret_exit_error) next_state = ST_TRAINERROR;
            end
            
            ST_TRAINERROR: begin
                en_trainerror = 1'b1;
                pl_state_sts = 4'b1010; 
                if (err_exit_reset) next_state = ST_RESET;
            end
            
            ST_LINKRESET: begin
                pl_state_sts = 4'b1001; 
                if (lp_state_req == 4'b0001) next_state = ST_RESET; 
            end
            
            ST_DISABLED: begin
                pl_state_sts = 4'b1100; 
                if (lp_state_req == 4'b0001) next_state = ST_RESET; 
            end
            
            default: next_state = ST_RESET;
        endcase
    end
    
    // =========================================================================
    // DATAPATH STATIC ROUTING
    // =========================================================================
    assign descrambler_en = scrambler_en;
    
    assign tx_training_en = (state == ST_SBINIT)  || 
                            (state == ST_MBINIT)  || 
                            (state == ST_MBTRAIN) || 
                            (state == ST_LINKINIT)|| 
                            (state == ST_PHYRETRAIN);

    // Lock in repair map once initialization finishes
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            repair_en <= 1'b0;
        end else if (state == ST_RESET) begin
            repair_en <= 1'b0;          
        end else if (mb_exit_mbtrain) begin
            repair_en <= 1'b1;          
        end
    end
    
    // Removed rdi_linkerror_latch to prevent deadlock.
    // The RDI specification requires lp_linkerror to be held as a level signal
    // until the adapter is ready to transition to Reset.
    
    // =========================================================================
    // MULTIPLEXED OUTPUT ROUTING
    // =========================================================================
    
    // OR together shared sideband TX signals
    assign tx_req_active = linkinit_tx_req_active | pm_tx_req_active;
    assign tx_rsp_active = linkinit_tx_rsp_active | pm_tx_rsp_active;
endmodule