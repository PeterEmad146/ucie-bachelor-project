module lphy_sb_tx (
    input  logic        clk_800m,   // 800 MHz always-on
    input  logic        rst_n,
    input  logic [63:0] tx_pkt,     // parallel 64b packet
    input  logic        tx_valid,   // controller asserts when pkt ready
    output logic        tx_ready,   // serializer ready for new packet
    output logic        TXDATASB,
    output logic        TXCKSB,
    output logic        TXDATASBRD, // Advanced pkg redundant
    output logic        TXCKSBRD
);