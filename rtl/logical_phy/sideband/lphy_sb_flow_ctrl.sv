// Flow Control Manager
//
// Manage the credit-based flow control for sideband transactions across both
// both FDI/RDI internal interfaces and the physica UCIe link.
//
// Key behaviors:
//      - Maintain separate TX credit counter and RX credit counter
//      - TX credit counter: initialized to 'N' (design-time parameter, max 32) at reset
//      - Decrement TX credits on every sent request/message (not completions)
//      - Increment TX credits on receiving 'Nop.Crd' message or credit-return signal
//      - RX side: return credits to remote after processing a request, via 'Nop.Crd' message or 'pl_cfg_crd'/'lp_cfg_crd'
//      - E2E credits for register access: initialized to 4 at RDI Reset state
//      - Stall logic: block TX when credits = 0; assert 'tx_stall' to controller
//      - Timeout counter: 8ms per request; reset on receiving Stall response.
//
// Credit return encoding ('Nop.Crd' MsgInfo, Table 53):
//      MsgInfo[3:0]: 0001b=1 credit, 0002b=2 credits, 0003b=3, 0004b=4

module lphy_sb_flow_ctrl (
    input  logic        clk,
    input  logic        rst_n, 
    input  logic        tx_req_sent,        // pulse: request/msg transmitted
    input  logic        tx_cpl_sent,        // pulse: completion transmitted (no credit deduct)
    input  logic        rx_crd_return,      // pulse: received Nop.Crd from remote
    input  logic [2:0]  rx_crd_count,       // count from Nop.Crd MsgInfo
    input  logic        rx_req_accepted,    // pulse: request accepted from RX, trigger credit return
    output logic         
);