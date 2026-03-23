// RDI Interface Slave
//
// Implement the sideband portion of the RDI interface. Specifically handle pl_cfg / lp_cfg
// parallel sideband buses at 8/16/32-bit widths, assembly of multi-phase packets, and 
// credit management for this interface.
//
// Key behaviors:
//      - Interface width: compile-time parameter NC ∈ {8,16,32} bits
//      - lp_cfg[NC-1:0] + lp_cfg_vld: adapter -> PHY
//      - pl_cfg[NC-1:0] + pl_cfg_vld: PHY -> adapter
//      - pl_cfg_crd / lp_cfg_crd: credit returns for this interface
//      - Packet reassembly: multiple lp_cfg_vld cycles needed for 64b or 128b packet
//                           (e.g., 4 cycles at 32b width for 128b payload)
//      - lp_cfg_vld must be asserted on consecutive cycles for phrases of the same packet
//      - May be asserted non-consecutively for phases of different packets.
//      - Clock: same domain as RDI (lclk)
//      - Clock gating rule: Adapter must complete pl_clk_req/lp_clk_ack handshake before
//                           driving lp_cfg

module lphy_rdi_intf #(
    parameter NC = 32   // 8, 16, or 32
) (
    input  logic            lclk, 
    input  logic            rst_n,
    // RDI sideband from adapter
    input  logic [NC-1:0]   lp_cfg,
    input  logic            lp_cfg_vld, 
    output logic            lp_cfg_crd,
    // RDI sideband to adapter
    output logic [NC-1:0]   pl_cfg, 
    output logic            pl_cfg_vld, 
    input  logic            pl_cfg_crd, 
    // Internal interface to sb_ctrl
    output logic [63:0]     rdi_rx_hdr, 
    output logic [63:0]     rdi_rx_data, 
    output logic            rdi_rx_valid,
    input  logic [63:0]     rdi_tx_hdr,
    input  logic [63:0]     rdi_tx_data,
    input  logic            rdi_tx_valid, 
    input  logic            rdi_tx_has_data, 
    output logic            rdi_tx_ready
);
    
endmodule