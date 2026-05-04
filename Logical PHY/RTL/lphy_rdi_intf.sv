`timescale 1ps / 1ps

module lphy_rdi_intf (
    input  logic lclk,
    input  logic rst_n,

    // =========================================================================
    // 1. RDI Formal Interface (Exposed to D2D Adapter)
    // =========================================================================
    
    // State and Status Management
    input  logic [3:0] lp_state_req,
    output logic [3:0] pl_state_sts,
    output logic       pl_inband_pres,
    
    // Error Management
    input  logic       lp_linkerror,
    output logic       pl_error,
    output logic       pl_cerror,
    output logic       pl_nferror,
    output logic       pl_trainerror,
    output logic       pl_phyinrecenter,

    // Stall Handshake
    output logic       pl_stallreq,
    input  logic       lp_stallack,

    // Clock Gating Handshakes
    output logic       pl_clk_req,
    input  logic       lp_clk_ack,
    input  logic       lp_wake_req,
    output logic       pl_wake_ack,

    // Configuration
    output logic [2:0] pl_speedmode,
    output logic [2:0] pl_lnk_cfg,

    // =========================================================================
    // 2. Internal PHY Connections (Wired to LTSSM & Datapath)
    // =========================================================================
    
    input  logic [3:0] internal_pl_state_sts,
    input  logic       internal_pl_inband_pres,
    output logic [3:0] internal_lp_state_req,
    output logic       internal_lp_linkerror,
    
    // FIXED: Synthesized trigger to wake up the LTSSM
    output logic       internal_start_link_training, 

    input  logic       internal_stallreq,
    output logic       internal_stallack,
    input  logic       internal_phyinrecenter,
    
    input  logic       internal_error,
    input  logic       internal_cerror,
    input  logic       internal_nferror,
    input  logic       internal_trainerror,

    input  logic [2:0] internal_speedmode,
    input  logic [2:0] internal_lnk_cfg
);

    // -------------------------------------------------------------------------
    // Direct Passthrough Assignments
    // -------------------------------------------------------------------------
    assign internal_lp_state_req = lp_state_req;
    assign internal_lp_linkerror = lp_linkerror;
    assign pl_state_sts          = internal_pl_state_sts;
    assign pl_inband_pres        = internal_pl_inband_pres;
    assign pl_speedmode          = internal_speedmode;
    assign pl_lnk_cfg            = internal_lnk_cfg;

    assign pl_error              = internal_error;
    assign pl_cerror             = internal_cerror;
    assign pl_nferror            = internal_nferror;
    assign pl_trainerror         = internal_trainerror;
    assign pl_phyinrecenter      = internal_phyinrecenter;

    // -------------------------------------------------------------------------
    // Link Training Trigger Synthesis
    // -------------------------------------------------------------------------
    // If we are currently in Reset (0000), and the Adapter requests Active (0001), 
    // we fire the start_link_training flag to wake up the Master LTSSM.
    assign internal_start_link_training = (internal_pl_state_sts == 4'b0000) && (lp_state_req == 4'b0001);

    // -------------------------------------------------------------------------
    // Clock Gating Handshakes (UCIe Spec Section 8.1.3)
    // -------------------------------------------------------------------------
    // Rule: If dynamic clock gating is not supported by the PHY, it must stage
    // lp_wake_req internally for one or more clock cycles and turn it around as pl_wake_ack.
    logic wake_req_q1, wake_req_q2;
    always_ff @(posedge lclk or negedge rst_n) begin
        if (!rst_n) begin
            wake_req_q1 <= 1'b0;
            wake_req_q2 <= 1'b0;
        end else begin
            wake_req_q1 <= lp_wake_req;
            wake_req_q2 <= wake_req_q1;
        end
    end
    assign pl_wake_ack = wake_req_q2;

    // By tying this high, we constantly request the Adapter to keep its clocks running
    // when we are out of reset, bypassing dynamic clock gating complexity on our side.
    assign pl_clk_req = 1'b1; 

    // -------------------------------------------------------------------------
    // Stall Handshake (UCIe Spec Section 8.3.1)
    // -------------------------------------------------------------------------
    // Rule: The logic path between pl_stallreq and lp_stallack must contain at 
    // least one flop to prevent a combinatorial loop.
    logic stallreq_q;
    logic stallack_q;

    always_ff @(posedge lclk or negedge rst_n) begin
        if (!rst_n) begin
            stallreq_q <= 1'b0;
            stallack_q <= 1'b0;
        end else begin
            // Forward internal stall request to RDI Adapter boundary
            stallreq_q <= internal_stallreq;
            
            // Capture RDI stall ack from Adapter and route to internal LTSSM
            stallack_q <= lp_stallack;
        end
    end

    assign pl_stallreq       = stallreq_q;
    assign internal_stallack = stallack_q;

endmodule