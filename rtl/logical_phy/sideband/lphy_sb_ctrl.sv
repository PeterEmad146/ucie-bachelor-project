// Sideband Controller (Top-Level Orchestrator)
//
// The central arbitration and sequencing engine for all sideband activity.
// It interfaces upward to the LTSSM (for training messages) and to the RDI interface
// (for adapter/protocol layer register accesses), downward to the TX serializer
// and RX deserializer.
//
// Key behaviors:
//      1. Completions (always, no credit check)
//      2. Link Management / Training messages from LTSSM
//      3. Register access requests from RDI/FDI
//      4. Credit return (Nop.Crd)
//
// RX dispatch:
//      - if dstid = PHY -> process locally (training messages, register accesses
//                          to PHY registers)
//      - if dstid = Adapter -> forward to RDI interface (pl_cfg)
//      - Completions -> match to outstanding Tag and return to requester
//
// Timeout management: 8ms timer per outstanding request; reset on Stall response
// 
// SBINIT pattern generation:
//      - Before sideband is functional: transmit "64 UI clock pattern + 32 UI low"
//                                       continously on both TXDATASB and TXDATASBRD
module lphy_sb_ctrl (
    // LTSSM -> SB Controller: request to send a training message
    input  logic        ltssm_msg_req,
    input  logic [7:0]  ltssm_msgcode, 
    input  logic [7:0]  ltssm_msgsubcode, 
    input  logic [15:0] ltssm_msginfo, 
    input  logic [63:0] ltssm_msgdata,
    input  logic        ltssm_has_data, 
    output logic        ltssm_msg_ack,

    // SB Controller -> LTSSM: received training message
    output logic        ltssm_rx_valid, 
    output logic [7:0]  ltssm_rx_msgcode,
    output logic [7:0]  ltssm_rx_msgsubcode, 
    output logic [15:0] ltssm_rx_msginfo, 
    output logic [63:0] ltssm_rx_data
);