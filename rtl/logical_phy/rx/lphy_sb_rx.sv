// Sideband Deserializer
//
// Sample RXDATASB on the negative edge of RXCKSB and reconstruct a 64-bit 
// parallel word, detecting packet boundaries via the 32 UI low gap.
//
// Key behaviors per spec:
//      - Sample on negative edge of incoming RXCKSB
//      - Detect start of packet: transition from 32 UI low to active data
//      - Deserialize 64 bits into rx_pkt[63:0]
//      - Assert rx_valid one cycle after 64th bit received
//      - For Advanced Package: support selecting which of the 4 clock/data 
//        combinations is functional (SBINIT repair result)
//      - Parity check: verify CP and DP fields; assert rx_parity err on mismatch
//
// SBINIT redundancy detection: The RX must support simultaneously sampling:
//      - RXDATASB with RXCKSB      -> Result[0]
//      - RXDATASB with RXCKSBRD    -> Result[1]
//      - RXDATASBRD with RXCKSB    -> Result[2]
//      - RXDATASBRD with RXCKSBRD  -> Result[3]
//
// This requires 4 parallel deserialization paths active during SBINIT.

module lphy_sb_rx (
    input  logic        clk_800m,
    input  logic        rst_n,
    input  logic        RXDATASB,
    input  logic        RXCKSB,
    input  logic        RXDATASBRD,
    input  logic        RXCKSBRD,
    input  logic [1:0]  sb_sel,             // 00=SB/CK, 01=SB/CKRD, 10=SBRD/CK, 11=SBRD/CKRD
    output logic [63:0] rx_pkt,
    output logic        rx_valid,
    output logic        rx_parity_err,
    output logic [3:0]  sbinit_det_result   // SBINIT detection results
);