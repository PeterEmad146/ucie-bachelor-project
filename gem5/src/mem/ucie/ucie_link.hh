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
//      * Error recover     :  Flit-level Retry (FLR) with ACK/NAK protocol
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

    uint8_t     seqNum;                 // 7-bit sequence number [0-127]
                                        // Wraps modulo retryBufferCapacity
    bool        ackNakValid;            // True when ackNakSeqNum is meaningful
    uint16_t    ackNakSeqNum;           // Sequence number being ACK'd or NAK'd

    // Credit return fields - piggybacked on every flit 
    uint8_t     headerCreditsReturned;  // Header credit slots returned to sender
    uint8_t     dataCreditsReturned;    // Data credit slots returned to sender

    // Default constructor produces a valid NULL flit header
    UcieFlitHeader()
        : srcID(0), dstID(0),
          msgClass(MessageClass::NPR), protocol(ProtocolType::PCIE),
          flitType(FlitType::NULL_FLIT),
          seqNum(0), ackNakValid(false), ackNakSeqNum(0),
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
static constexpr uint32_t UCIE_PAYLOAD_SIZZE_BYTES  =
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
        uint8_t sequenceNumber;             // 7-bit flit sequence number (0..127)
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
            header.seqNum   = seq_num;
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



};

#endif