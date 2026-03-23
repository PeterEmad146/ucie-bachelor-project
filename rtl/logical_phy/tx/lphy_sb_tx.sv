// Sideband Serializer
//
// Accept a 64-bit parallel word from the sideband controller and serialize it
// at 800 MT/s onto TXDATASB, with TXCKSB strobing active dring transmission.
//
// Key behaviors per spec:
//      - Clock: 800 MHz always-on domain
//      - Data is edge-aligned with strobe
//      - Transmit 64 UI of data, then hold TXDATASB low for 32 UI (inter-packet
//        gap per Figure 47 in Specification file)
//      - When transmitting, TXCKSB toggles; when idle, TXCKSB is gated low.
//      - For Advanced Package: simulataneously drive TXDATASBRD / TXCKSBRD with 
//        same data (used during SBINIT repair detection)
//      - Backpressure: sb_tx_ready signal to controller indicating serializer is
//        idle.
//
// Internal state machine:
//      IDLE -> TRANSMIT (64 cycles) -> GAP (32 cycles) -> IDLE

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