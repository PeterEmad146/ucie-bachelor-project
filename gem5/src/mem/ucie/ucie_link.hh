// ================================================================================
//  UcieLink.hh - UCIe Die-to-Die link Model for gem5
// 
//  Sepecification References:
//      [UCIe-SPEC] Universal Chiplet Interconnect Express (UCIe) Specification
//                  Version 1.1, 2023
//      [REF-PAPER] "Efficient Die-to-Die Communication: UCIe Link Simulation
//                   and Optimization in a Chiplet-Based System"
//      [GEM5]      "The gem5 Simulator: Version 20.0" - gem5.org
// 
//  Architecture Modelled (UCIe stack, top-down):
//  --> Protocol Layer:             PCIe / CXL / Streaming TLPs
//  --> Die-to-Die (D2D) Adapter:   Flit packing, CRC, ACK/NAK, credit-based flow
//                                  control
//  --> Logical PHY:                Lane width, data-rate, encoding
//  --> Physical PHY:               (out of scope of behavioral model)
//
//  Key UCIe Flit Parameters:
//      * Flit Size         : 256 bytes (fixed, spec-mandated)
//      * Flit header       :   8 bytes 
//      * CRC field         :  23 bytes (CRC-32 per 64B CRC group)
//      * Usable payload    : 236 bytes (256 - 8 - 12)
//      * Max data rate     :  32 GT/s per lane (Advanced package)
//      * Link widths       :  x2, x4, x8, x16 (Standard) / x64 (Advanced)
//      * Flow control      :  Credit-based (header credits + data credits)
//      * Error recover     :  Flit-level Retry (FLR) with ACK/NAK protocol + timeout
//
// ================================================================================

#ifndef __UCIE_UCIE_LINK_HH__
#define __UCIE_UCIE_LINK_HH__

//  gem5 core headers
#include "params/UcieLink.hh"       // Auto-generated from UcieLink.py (SCons)
#include "sim/clocked_object.hh"    // Base class: tick-accurate clocked model
#include "mem/port.hh"              // RequestPort / ResponsePort abstractions
#include "mem/packet.hh"            // gem5 Packet (base for UcieFlitPacket)
#include "base/statistics.hh"       // gem5 statistics framework

//  STL
#include <deque>
#include <vector>
#include <cstdint>
#include <array>
#include <string>

namespace gem5
{

// ================================================================================
//  SECTION 1 - UCIe ENUMERATED TYPES
//  These mirror the state machines and message classifications defined in 
//  UCIe Spec (Link Training) and (Die-to-Die Adapter).
// ================================================================================

//  1.1     Physical Layer Link Training State Machine
//  
//  The Physical Layer follows this exact 9-state sequence from spec Table 22.
//  Every state except RESET and TRAINERROR has an 8ms residency timeout;
//  expiry causes a transition to TRAINERROR --> RESET.
//
//  State descriptions (verbatim from spec Table 22):
//      RESET       - Following primary reset or exit from TRAINERROR.
//                    Must remain here >= 4ms to allow PLLs to stabilize.
//      SBINIT      - Sideband interface detected, repaired (Advanced Package),
//                    and out-of-reset message transmitted at 800 MT/s.
//      MBINIT      - Mainband initialized at lowest speed (4 GT/s). On-die
//                    calibration + interconnect repair (Advanced Package).
//      MBTRAIN     - Mainband speed raised to highest negotiated data rate.
//                    Die-to-die clock centering vs data lanes performed.
//      LINKINIT    - Adapter and Link management messages exchanged.
//                    Protocol parameter negotiation completes here.
//      ACTIVE      - Transactions are sent and received. Normal operation.
//      L1          - Power Management low-power state. Mandatory for PCIe/CXL.
//      L2          - Power Management deep-sleep state. Mandatory for PCIe/CXL.
//      PHYRETRAIN  - Initiates the runtime retrain flow for the physical link.
//                    Distinct from Adapter-layer RETRAIN.
//      TRAINERROR  - Fatal or non-fatal event during training or operation 
//                    Link must exit to RESET from here.
enum class PhyLinkState : uint8_t
{
    RESET       = 0,    // Post-reset; PLLs stabilizing (min 4ms)
    SBINIT      = 1,    // Sideband initialization at 800 MT/s
    MBINIT      = 2,    // Mainband init at 4 GT/s; lane repair
    MBTRAIN     = 3,    // Mainband speed ramp to max negotiated rate
    LINKINIT    = 4,    // Adapter & link management message exchange
    ACTIVE      = 5,    // Normal operation - flits flowing
    L1          = 6,    // PM L1 low-power state 
    L2          = 7,    // PM L2 deep-sleep state 
    PHYRETRAIN  = 8,    // Runtime physical retrain initiation
    TRAINERROR  = 9     // Fatal/non-fatal training error -> must exit to RESET
};

//  1.2     Die-to-Die Adapter Link State Machine (LSM)
//
//  The Adapter LSM sits ABOVE the Physica Layer and has its own separate
//  set of states. State transitions in the Adapter LSM are strictly gated
//  by the RDI SM (which abstracts Physical Layer state to upper layers).
//  
//  Spec-mandated dependency ordering:
//      1.  RDI SM must reach target state BEFORE Adapter LSM requests it.
//      2.  Adapter LSM must reach target state BEFORE Protocol vLSM requests it.
//
//  Priority ordering for error/reset states:
//      LinkError > Disabled > LinkReset
//
//  State descriptions:
//      RESET       - Adapater reset; coordinates with Physical Layer RESET.
//      ACTIVE      - Normal operation; requires RDI SM to be ACTIVE first.
//      RETRAIN     - Adapter retrain; RDI SM must enter RETRAIN first.
//                    All Adapter LSMs in ACTIVE must propagate RETRAIN.
//      L1          - Adapter PM L1; all vLSMs must be in PM first.
//      L2          - Adapter PM L2; all vLSMs must be in PM first.
//      LINKERROR   - Fatal link error; propagated from RDT SM.
//                    Highest priority: overrides LinkReset and Disabled.
//      LINKRESET   - Hot reset negotiated via sideband with remote partner.
//      DISABLED    - Administratively disabled; takes priority over LinkReset.
enum class AdapterLinkState : uint8_t
{
    RESET       = 0,    // Adapter in reset
    ACTIVE      = 1,    // Normal flit transfer operation
    RETRAIN     = 2,    // Adapter-layer retrain (gated by RDI SM retrain)
    L1          = 3,    // PM L1 
    L2          = 4,    // PM L2
    LINKERROR   = 5,    // Fatal error propagated from RDI SM (highest priority)
    LINKRESET   = 6,    // Hot reset - negotiated via sideband
    DISABLED    = 7     // Disabled - priority over LinkReset, below LinkError
};

//  Convenience alias - the state machine most of the link logic uses
//  is the Adapter LSM (sits at D2D layer, directly above PHY abstraction)
using LinkState = AdapterLinkState;

//  1.3     Flit Type 
//  
//  UCIe defines distinct flit categories carrying different header encodings
//  and used for different purposes within the link protocol.
enum class FlitType : uint8_t
{
    PROTOCOL        = 0,    // Carries PCIe / CXL / Streaming TLP payload data
    FLIT_LEVEL_ACK  = 1,    // Acknowledgement: receiver consumed N flits cleanly
    FLIT_LEVEL_NAK  = 2,    // Negative-ACK: requests retransmission from seq N
    LINK_MGMT       = 3,    // Link management: credit returns, PM state requests
    NULL_FLIT       = 4     // IDLE / training flit - no protocol payload
};

//  1.4     Protocol Stack Identifier
//
//  The D2D Adapter must tag each flit with the source protocol so the
//  receiving adapter can route to the correct protocol stack.
enum class ProtocolType : uint8_t
{
    PCIE        = 0,    // PCI Express TLP/DLLP payload
    CXL_IO      = 1,    // Compute Express Link - CXL.io (PCIe-compatible)
    CXL_MEM     = 2,    // Compute Express Link - CXL.mem (memory expansion)
    CXL_CACHE   = 3,    // Compute Express Link - CXL.cache (coherent cache)
    STREAMING   = 4,    // Raw streaming protocol (vendor-defined)
    UNDEFINED   = 0xFF
};

//  1.5     Message Class 
//
//  Within PROTOCOL flits, message class determines QoS priority and 
//  virtual channel mapping.
enum class MessageClass : uint8_t
{
    NPR     = 0,    // Non-Posted Request
    PR      = 1,    // Posted Request (e.g. memory write)
    CPL     = 2,    // Completion (read return / write status)
    RSVD    = 3     // Reserved for future extension
};

// ================================================================================
//  SECTION 2 - UCIe FLIT HEADER
//  
//  Every 256-byte flit begins with an 8-byte header that the D2D Adapter 
//  constructs and parses. This struct models those 8 bytes with named fields
//  to avoid error-prone raw bit manipulation in the .cc file.
//
//  Byte layout (conceptual - actual packing done by D2D hardware):
//  
//      Byte 0  : [7:4] srcID   [3:0] dstID
//      Byte 1  : [7:4] msgClass    [3:0] protocol
//      Byte 2  : flitType
//      Byte 3  : [7:1] SeqNum[6:0] [0] ackNakValid
//      Byte 4-5: ackNakSeqNum (16-bit, for ACK/NAK responses)
//      Byte 6  : headerCreditsReturned (TX -> RX credit return for header slots)
//      Byte 7  : dataCreditsReturned   (TX -> RX credit return for data slots)
// ================================================================================
struct UcieFlitHeader
{
    uint8_t     srcID;                  // Source chiplet identifier
    uint8_t     dstID;                  // Destination chiplet identifier
    MessageClass    msgClass;           // QoS / virtual channel
    ProtocolType    protocol;           // Protocol stack selector
    FlitType        flitType;           // Flit category (see enum above)

    // Optimized: Using Tick to avoid wrap-around and track latency
    Tick        timestampSeqNum;    

    bool        ackNakValid;            // True when ackNakSeqNum is meaningful
    Tick        ackNakTimestamp;        // Replacing 16-bit ackNakSeqNum

    // Credit return fields - piggybacked on every flit 
    uint8_t     headerCreditsReturned;  // Header credit slots returned to sender
    uint8_t     dataCreditsReturned;    // Data credit slots returned to sender

    // Default constructor produces a valid NULL flit header
    UcieFlitHeader()
        : srcID(0), dstID(0),
          msgClass(MessageClass::NPR), protocol(ProtocolType::PCIE),
          flitType(FlitType::NULL_FLIT),
          timestampSeqNum(0), ackNakValid(false), ackNakTimestamp(0),
          headerCreditsReturned(0), dataCreditsReturned(0)
    {}
};

// ================================================================================
//  SECTION 3 - UCIe FLIT PACKET    (256-byte Atomic Transfer Unit)
//
//  UcieFlitPacket inherits from gem5's Packet to integrate cleanly with the 
//  gem5 timing memory system. It extends Packet with UCIe-specific metadata:
//  the flit header, CRC storage, and references to the original TLPs packed
//  inside this flit (needed for retransmission and unpack operations).
//
//  CRC Note: UCIe uses a per -64B CRC group scheme, producing 4 x CRC-32
//  values stored in the 12-byte CRC field (three 32-bit words are used;
//  the fourth 32-bit word stores link-level status bits).
// ================================================================================

//  Fixed flit dimensions - spec-mandated constants
static constexpr uint32_t UCIE_FLIT_SIZE_BYTES      = 256;  // Total flit size
static constexpr uint32_t UCIE_HEADER_SIZE_BYTES    = 8;    // Flit header
static constexpr uint32_t UCIE_CRC_SIZE_BYTES       = 12;   // CRC field
static constexpr uint32_t UCIE_PAYLOAD_SIZE_BYTES  =
    UCIE_FLIT_SIZE_BYTES - UCIE_HEADER_SIZE_BYTES - UCIE_CRC_SIZE_BYTES;    // 236

//  Maximum sequence number before wrap-around (7-bit filed -> 0..127)
static constexpr uint8_t  UCIE_MAX_SEQ_NUM          = 128;

class UcieFlitPacket : public Packet
{
    public:
        //  3.1     UCIe Protocol Metadata
        UcieFlitHeader  header;             // 8-byte structured flit header
        uint32_t        payloadBytes;       // Actual TLP bytes in payload (<= 236)
        uint32_t        paddingBytes;       // Zero-padding appended to reach 236B
                                            // paddingBytes = 236 - payloadBytes

        //  3.2     CRC Storage
        //
        //  Four CRC-32 values, each covering one 64-byte group of the flit body.
        //  Groups: [Bytes 0-63], [Bytes 64-127], [Bytes 128-191], [Bytes 192-235]
        //  Only 3 groups carry data CRC; the 4tn stores link status bits.
        std::array<uint32_t, 4> crcGroups;  // crcGroups[0..2]  = data CRC
                                            // crcGroups[3]     = link status
        
        //  3.3     Retry Buffer Metadata 
        Tick sequenceNumber;                // Timestamp sequence number 
        bool    crcValid;                   // True if CRC check passed on receive
        bool    isRetransmission;           // True if this flit is being replayed
                                            // from the retry buffer (not first send)

        //  3.4     TLP Provenance - for Unpack & Retry
        //
        //  Holds strong references to the original gem5 Packets (TLPs) that were
        //  packed into this flit. On ACK: packets are retired. On NAK: they are
        //  repacked and retransmitted from the retry buffer.
        std::vector<PacketPtr> originalPackets;

        //  3.5     TLP Segmentation Flags
        //
        //  A single TLP may exceed 236B and must be split across consecutive flits.
        //  These flags tell the receiver how to reassemble.
        bool isFirstSegment;    // This flit begins a segmented TLP
        bool isLastSegment;     // This flit ends a segemented TLP (may also be first)
        bool isMiddleSegment;   // Interior segment of a multi-flit TLP

        //  Constructor
        //  req     - gem5 request object (provides address/command context)
        //  cmd     - gem5 memory command (typically MemCmd::WriteReq for TX)
        //  seq_num - flit sequence number assigned by the packer
        //  type    - flit type classification
        UcieFlitPacket(RequestPtr req,
                       MemCmd cmd,
                       uint8_t seq_num,
                       FlitType type=FlitType::PROTOCOL)
            : Packet(req, cmd, UCIE_FLIT_SIZE_BYTES),
              payloadBytes(0), paddingBytes(0),
              sequenceNumber(seq_num),
              crcValid(false), isRetransmission(false),
              isFirstSegment(true), isLastSegment(true), isMiddleSegment(false)
        {
            header.timestampSeqNum   = seq_num;
            header.flitType = type;
            crcGroups.fill(0);
            allocate(); // Allocated 256 bytes in gem5's memory pool
        }
};

// ================================================================================
//  SECTION 4 - CRC ENGINE
//
//  The CRC engine is stateless (pure computation) so it is modelle as a 
//  namespace of free functions rather than a class. The implementation in
//  UcieLink.cc uses a pre-computed lookup table for performance.
//
//  UCIe uses standard CRC-32 (polynomial 0x04C11DB7, reflected) applied
//  independently to each 64-byte group within the flit.
// ================================================================================
namespace UcieCRC
{
    // Compute CRC-32 over [data, data+length]
    uint32_t compute (const uint8_t* data, size_t length);

    // Populate the four crcGroups fields of a flit before transmission
    void generateFlitCRC(UcieFlitPacket* flit);

    // Verify crcGroups against flit payload; sets flit-crcValid
    // Returns true if all groups pass, false on any failure 
    bool verifyFlitCRC(UcieFlitPacket* flit);
}

// ================================================================================
//  SECTION 5 - CREDIT MANAGER
//
//  UCIe uses a credit-based flow control scheme at the D2D adapter layer.
//  Two orthogonal credit pools exist:
//      * Header Credits    - permission to send one flit header (one TLP)
//      * Data Credits      - permission to send on 4-byte unit of TLP payload
//
//  Credits are initialized during link training (MBTRAIN state) and returned 
//  by the receiver piggybacked on outgoing flits (via header fields
//  headerCreditsReturned / dataCreditsReturned).
//
//  This class tracks credit state for one direction of the link.
// ================================================================================
class UcieCreditManager
{
    public:
        // Per-message-class credit pools
        // Index: 0 = NPR, 1 = PR, 2 = CPL (MessageClass enum values)
        static constexpr int NUM_MSG_CLASSES = 3;

        struct CreditPool {
            uint32_t txAvailable;   // Credits this side may consume for TX
            uint32_t rxGranted;     // Credits this side has granted to remote TX
            uint32_t rxConsumed;    // Credits consumed by received flits (not yet returned)
        };

        std::array<CreditPool, NUM_MSG_CLASSES> pools;

        // Header credit initial values set during link training
        // (negotiated; typical initial value = 8 per message class)
        static constexpr uint32_t INITIAL_HEADER_CREDITS    = 8;
        static constexpr uint32_t INITIAL_DATA_CREDITS      = 32;   // in 4B units

        // API used by UcieLink
        UcieCreditManager();

        // Returns true if at least one header credit + enough data credits are 
        // available to transmit a packet of payloadBytes bytes.
        bool canSend(MessageClass cls, uint32_t payloadBytes) const;

        // Deduct credits when scheduling a flit for transmission
        void consumeCredits(MessageClass cls, uint32_t payloadBytes);

        // Called when a received flit's header carries credit return fields
        void returnCredits(uint8_t headerCreds, uint8_t dataCreds,
                           MessageClass cls);

        // Initialize pools to spec-defined initial values
        void reset();
};

// ================================================================================
//  SECTION 6 - FLIT PACKER ENGINE (D2D Adapter TX path)
//
//  The FlitPacker accumulates incoming gem5 Packets (Protocol Layer TLPs)
//  into 256-byte UCIe flits. It respects the 236-byte payload limit and 
//  handles two packing triggers:
//
//      a) Payload Full : staging buffer reaches 236B -> immediate flush
//      b) Timer Flush  : 8-cycle timeout fires -> partial flit with padding
//
//  TLP Segmentation:
//      If a single TLP exceeds 236B it is split: the first 236B go into one flit
//      (isFirstSegment=true), remaining bytes fill subsequent flits 
//      (isMiddleSegment=true / isLastSegment=true on the last segment).
//
//  Reference: [REF-PAPER] SS 3.2 "Flit Assembly and Padding Analysis"
// ================================================================================
class FlitPacker
{
    public:
        //  6.1     Configuration (set during UcieLink construction)
        const uint32_t flitSize;        // Always 256 (UCIE_FLIT_SIZE_BYTES)
        const uint32_t maxPayloadSize;  // Always 236 (UCIE_PAYLOAD_SIZE_BYTES)

        //  Constructor
        explicit FlitPacker(uint32_t flit_size= UCIE_FLIT_SIZE_BYTES);

        //  6.2     Primary Interface

        // Accept one incoming TLP from the Protocol Layer.
        // If the staging buffer fills to 236B or the TLP exactly fits:
        //      Returns a fully-packed UcieFlitPacket* ready for CRC + transmission.
        // Otherwise:
        //      Stores TLP in staging buffer and returns nullptr (more data needed).
        // Large TLPs (> 236B) produce on flit immediately and re-queue remainder.
        UcieFlitPacket* processIncomingTLP(PacketPtr pkt);

        // Flush the staging buffer unconditionally with padding.
        // Called by the 8-cycle timer event in UcieLink.
        // Returns nullptr if staging buffer is empty (nothing to flush).
        UcieFlitPacket* forceFlush();

        // True when there is at least one byte in the staging buffer
        bool hasData() const { return currentBytes > 0; }

        // How many payload bytes are currently staged
        uint32_t stagedBytes() const { return currentBytes; }

        // Reset sequence numbering (called on link reset / retrain)
        void resetSequenceCounter() { nextSequenceNumber = 0; }

        bool isStagingBufferEmpty() const {return stagingBuffer.empty() && segementResidue.empty(); }

    private:
        //  6.3     Internal State
        uint32_t                currentBytes;           // Bytes accumulated in staging
        Tick                    nextSequenceNumber;     // timestamp-based; set per pack
        std::vector<PacketPtr>  stagingBuffer;          // TLPs waiting to be packed
        std::vector<uint8_t>    segementResidue;        // Leftover bytes from a segement TLP

        //  6.4     Internal Helpers

        // Build a UcieFlitPacket from whatever is currently in stagingBuffer.
        // Applies padding, sets segmentation flags, advances sequence counter.
        UcieFlitPacket* assembleFlit(bool isPartial);

        // Assign the next 7-bit sequence number (wraps at UCIE_MAX_SEQ_NUM)
        Tick assignTimestampSequence();
};

// ================================================================================
//  SECTION 7 - FLIT UNPACKER ENGINE (D2D Adapter RX path)
//
//  The FlitUnpacker is the receive-side complement of FlitPacker. It:
//      1. Accepts a received UcieFlitPacket*
//      2. Verifies the CRC (delegates to UcieCRC::verifyFlitCRC
//      3. Extracts individual TLPs from the payload, respecting segmentation
//      4. Reassembles multi-flit segmented TLPs
//      5. Forwards complete TLPs to the protocol layer (rxBuffer in D2DAdapter)
//      6. Generates ACK or NAK flit for the sender
// ================================================================================
class FlitUnpacker
{
    public:
        explicit FlitUnpacker() = default;

        //  7.1     Primary Interface

        // Process on received flit.
        // Returns a list of complete TLPs extracted from the flit.
        // If CRC fails, returns empty list (caller must generate NAK).
        std::vector<PacketPtr> processReceivedFlit(UcieFlitPacket* flit);

        // True if we are mid-way through reassembling a segmented TLP
        bool hasPartialTLP() const { return !reassemblyBuffer.empty(); }

    private:
        //  7.2     Segmented TLP Reassembly Buffer
        std::vector<uint8_t>    reassemblyBuffer;   // Raw bytes of teh in-progress TLP
        uint32_t                expectedTotalBytes; // Size of the TLP being assembled
};

// ================================================================================
//  SECTION 8 - UCIe LINK MAIN CONTROLLER
//
//  UcieLink is the top-level gem5 ClockedObject that modles one direction of
//  the UCIe stack. It wires together all sub-components and implements:
//      * gem5 timing port callbacks (send / receive)
//      * Link state machine transitions
//      * 8-cycle flit assembly timer
//      * Retry buffer management (ACK / NAK processing)
//      * Credit tracking (via UcieCreditManager)
//      * gem5 statistics collection
//
// ================================================================================
class UcieLink : public ClockedObject
{
    private:
        //  8.1     BIDIRECTIONAL PORTS

        // TX Port - sends packed flits to the adjacent chiplet 
        // (gem5 RequestPort: this side initiates the memory transaction)
        class UcieTxPort : public RequestPort
        {
            private:
                UcieLink* owner;
            public:
                UcieTxPort(const std::string& name, UcieLink* owner);

                // Called when hte far-end chiplet sends a response (ACK/NAK flit)
                bool recvTimingResp(PacketPtr pkt) override;

                // Called when the far-end was busy and now has capacity again
                void recvReqRetry() override;

                // Address range changes from the far side
                void recvRangeChange() override;
        };

        // RX Port - receives TLPs from the local chiplet's protocol stack
        // (gem5 ResponsePort: this side resopnds to memory transactions)
        class UcieRxPort : public ResponsePort
        {
            private:
                UcieLink* owner;
            public:
                UcieRxPort(const std::string& name, UcieLink* owner);

                // Backdoor / zero-latency access (functional simulation mode)
                Tick recvAtomic(PacketPtr pkt) override;
                void recvFunctional(PacketPtr pkt) override;

                // Main timing path: a TLP arrives from the local protocol stack
                bool recvTimingReq(PacketPtr pkt) override;

                // Flow control retry: called when we can accept more packets
                void recvRespRetry() override;

                // Memory address space this port is responsible for
                AddrRangeList getAddrRanges() const override;
        };

        //  8.2     UCIe D2D ADAPTER SUB-MODULE 
        struct D2DAdapter
        {
            // Flit sizing (spec-mandated, duplicated here for clarity)
            static constexpr uint32_t FLIT_SIZE     = UCIE_FLIT_SIZE_BYTES;     // 256
            static constexpr uint32_t PAYLOAD_SIZE  = UCIE_PAYLOAD_SIZE_BYTES; // 236

            // Retry Buffer
            // Holds every transmitted flit until an ACK is received.
            // On Nak: all flits from NAK.seqNum onwards are retransmitted.
            // Capacity = retryBufferCapacity (configured at construction).
            uint32_t retryBufferCapacity;   // Max flits held pending ACK
            std::deque<UcieFlitPacket*> txRetryBuffer;

            // Highest ACK's sequence number (flits <= this value may be retired)
            Tick lastAckedSeqNum;

            // RX Buffer - holds unpacked TLPs waiting to be forwarded to memory
            std::deque<PacketPtr> rxBuffer;
            uint32_t rxBufferMaxDepth;  // Configurable; controls back-pressure

            // Credit Manager
            UcieCreditManager creditManager;

            // Chiplet Addressing 
            uint8_t localChipletID;     // This chiplet's ID (0..255)
            uint8_t remoteChipletID;    // Target chiplet's ID (0..255)
        } d2dAdapter;

        //  8.3     UCIe LOGICAL PHY SUB-MODULE
        //  Modles the lane-level physical parameters without transistor-level detail.
        //  Reference: UCIe Spec (Physical Layer) and (Logical PHY).
        struct LogicalPhy
        {
            // Link width in lanes: 2, 4, 8, 16 (Standard) or 64 (Advanced)
            int     linkWidth;

            // Data rate in Gbps per lane (Standard: up to 32 GT/s; Advanced: 32 GT/s)
            double  dataRateGbps;

            // Point-to-point propagation delay (Tick = gem5 simulator time unit)
            Tick    linkLatency;

            // Effective bandwidth in bytes/tick = (linkWidth x dataRateGbps) / 8
            // Computed once during init() and cached here
            double effectiveBandwidthBytesPerTick;
        } logicalPhy;

        //  8.4     SUB-COMPONENT INSTANCES
        //
        //  Constructor init-list order:
        //      txPort -> rxPort -> txPacker -> errorRate -> txBlocked ->
        //      phyLinkState -> currentLinkState -> flushTimerCycles ->
        //      flushEventPending -> flushEvent -> stats
        UcieTxPort      txPort;     // 1 - TX Port (must be before rxPort)
        UcieRxPort      rxPort;     // 2
        FlitPacker      txPacker;   // 3 - flit assembly engine
        FlitUnpacker    rxUnpacker; // 4 - (default-constructed, order flexible)

        // Simulated bit-error rate applied on each transmitted flit
        // (0.0 = error-free; e.g., 1e-9 = one bit error per billion bits)
        double errorRate;           // 5
        
        //  8.5     FLIT TRANSMISSION PIPELINE (continued)

        // True when the downstream port is busy (credit or port backpressure)
        bool txBlocked;             // 6

        //  8.6     STATE MACHINES 
        //
        //  UCIe is hierarchical: Physical Layer state must be advanced BEFORE
        //  the Adapter LSM can request the equivalent state. Both are tracked
        //  independently so the model can enforce this gating.
        //
        //  Declaraction AFTER txBlocked (position 6) to match init-list position 7.

        // Physical Layer training state 
        PhyLinkState    phyLinkState;   // 7a - tracks 9-state PHY machine

        // Adapter LSM state - gates data transmission
        AdapterLinkState currentLinkState;  // 7b - gates flit flow in ACTIVE only

        //  State transition helpers
        
        // Advance Physical Layer training sequence (RESET->SBINIT->ACTIVE)
        void transitionPhyState(PhyLinkState newState);

        // Advance Adapter LSM (gated: phyLinkState must be >= equivalent level)
        void transitionLinkState(AdapterLinkState newState);

        // Physical Layer initialization substeps
        void handleSbInit();        // SBINIT: sideband detection & repair
        void handleMbInit();        // MBINIT: mainband init at 4 GT/s
        void handleMbTrain();       // MBTRAIN: spead ramp + clock centering
        void handleLinkInit();      // LINKINIT: adapter parameter exchange

        // Runtime state transitions
        void triggerPhyRetrain();   // Enter PHYRETRAIN -> MBTRAIN -> .. -> ACTIVE
        void triggerRetrain();      // Ender Adapter RETRAIN (Gated by PHY retrain)
        void triggerLinkError();    // Enter LINKERROR (highest priority)
        void triggerLinkReset();    // Enter LINKRESET (hot reset flow)
        void enterPowerManagement(bool deepSleep);  // Enter L1 (false) or L2 (true)
        void exitPowerManagement(); // Return to ACTIVE from L1/L2

        //  8.7     TX SEND QUEUE AND HELPERS
        //  (Not in the initializer list - default-constructed; order flexible).

        // Queue of fully-assembled, CRC-stamped flits awaiting port bandwidth
        std::deque<UcieFlitPacket*> txSendQueue;

        // Attempt to drain txSendQueue through txPort; respects credit limits
        void drainTxSendQueue();

        // Apply CRC + inject simulated errors + push flit into txSendQueue
        void transmitFlit(UcieFlitPacket* flit);

        //  8.8     ACK / NAK PROCESSING 
        
        // Retires all txRetryBuffer entries with seqNum <= ackedSeqNum
        void processAck(Tick ackedSeqNum);

        // Retransmits all txRetryBuffer entries with seqNum >= nakSeqNum
        void processNak(Tick nakSeqNum);

        // Generate and send an ACK flit piggybacked with credit returns
        void sendAck(Tick ackedSeqNum);

        // Generate and send a NAK flit for a CRC-failed received flit
        void sendNak(Tick nakSeqNum);

        // Task-based event handlers
        void processPackTlp();
        void processSendFlit();
        void processRetryTimeout();

        // Event objects
        EventFunctionWrapper packTlpEvent;
        EventFunctionWrapper sendFlitEvent;
        EventFunctionWrapper retryTimeoutEvent;

        Tick retryTimeoutDelay;

        //  8.9     GEM5 STATISTICS 
        //
        //  The reference paper evaluates the UCIe model using these key metrics:
        //      * Flit packing efficiencey  = payload / (payload + padding)
        //      * Retransmission rate       = retransmitted flits / total flits
        //      * CRC error rate            = errored flits / total flits
        //      * Effective throughput      = payload bytes / simulation time
        struct UcieStats : public statistics::Group
        {
            // Constructor wires stats into gem5's statistics framework
            UcieStats(UcieLink* parent);

            //  TX Path
            statistics::Scalar totalFlitsSent;          // All flits pushed to txPort
            statistics::Scalar totalTLPsSent;           // Original TLPs packed
            statistics::Scalar totalPayloadBytes;       // Real TLP bytes transmitted
            statistics::Scalar totalPaddingBytes;       // Zero=padding bytes added
            statistics::Scalar totalRetransmissions;    // Flits resent due to NAK
            statistics::Scalar totalFlitsNaked;         // Naks received from remote

            //  RX Path
            statistics::Scalar totalFlitsReceived;      // Flits received from txPort
            statistics::Scalar totalCrcErrors;          // Flits failing CRC check
            statistics::Scalar totalAcksSent;           // ACK flits generated
            statistics::Scalar totalNaksSent;           // NAK flits generated

            //  Derived metrics (Formula = auto-computed from Scalars)
            statistics::Formula payloadEfficiency;      // totalPayloadBytes / (totalPayloadBytes + totalPaddingBytes)
            statistics::Formula retransmissionRate;     // totalRetransmissions / totalFlitsSent
            statistics::Formula crcErrorRate;           // totalCrcError / totalFlitsReceived
        } stats;

    public:
        //  8.10        PUBLIC INTERFACE - gem5 ClockedObject API

        // Construct from Python-generated parameter struct (UcieLink.py -> SCons)
        explicit UcieLink(const UcieLinkParams& p);

        // gem5 port wiring - called by Python simulation script
        Port& getPort(const std::string& if_name,
                      PortID idx = InvalidPortID) override;
        
        // Called by gem5 just before simulation starts; validates config and 
        // schedules initial link training events
        void init() override;

        //  8.11    DIAGNOSTIC / DEBUG API

        // Print current link state and credit pools to std::cout
        void dumpLinkStatus() const;

        // Return current Physical Layer state
        PhyLinkState getPhyState() const { return phyLinkState; }
        
        // Return current Adapter LSM state (controls flit gating)
        AdapterLinkState getLinkState() const { return currentLinkState; }
};

} // end namespace gem5

#endif // __UCIE_UCIE_LINK_HH__