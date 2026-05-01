#ifndef __UCIE_UCIE_LINK_HH__
#define __UCIE_UCIE_LINK_HH__

//  gem5 core headers
#include "params/UcieLink.hh"       // Auto-generated from UcieLink.py (SCons)
#include "sim/clocked_object.hh"    // Base class: tick-accurate clocked model
#include "mem/port.hh"              // RequestPort / ResponsePort abstractions
#include "mem/packet.hh"            // gem5 Packet (base for UcieFlitPacket)
#include "base/statistics.hh"       // gem5 statistics framework
#include "sim/eventq.hh"            // Required for event scheduling

//  STL
#include <deque>
#include <vector>
#include <cstdint>
#include <memory>

namespace gem5
{

// Custom SenderState to track end-to-end TLP latency
struct UcieTimerState: public Packet::SenderState {
    Tick entryTime;
    UcieTimerState(Tick t) : entryTime(t) {}
};

// 1. Simplified State Machine:
enum class UcieLinkState : uint8_t
{
    INIT = 0,   // Link is initializing 
    ACTIVE = 1  // Normal Operation - ready to process flits
};

//  2. Flit Type 
enum class FlitType : uint8_t
{
    PROTOCOL        = 0,    // Carries PCIe / CXL / Streaming TLP payload data
    FLIT_LEVEL_ACK  = 1,    // Acknowledgement: receiver consumed N flits cleanly
    FLIT_LEVEL_NAK  = 2,    // Negative-ACK: requests retransmission from seq N
    LINK_MGMT       = 3,    // Link management: credit returns, PM state requests
    NULL_FLIT       = 4     // Corresponds to the NOP flits
};

//  3. Protocol Stack Identifier
enum class ProtocolType : uint8_t
{
    PCIE        = 0,    // PCI Express TLP/DLLP payload
    CXL_IO      = 1,    // Compute Express Link - CXL.io (PCIe-compatible)
    CXL_MEM     = 2,    // Compute Express Link - CXL.mem (memory expansion)
    CXL_CACHE   = 3,    // Compute Express Link - CXL.cache (coherent cache)
    STREAMING   = 4,    // Raw streaming protocol (vendor-defined)
    UNDEFINED   = 0xFF
};

// Fixed flit dimensions from the paper
// changed the flit size to 236 for optimized simulation
static constexpr uint32_t UCIE_FLIT_SIZE_BYTES = 236;
static constexpr uint32_t UCIE_PAYLOAD_SIZE_BYTES = 236;

// 4. Flit Packet

class UcieFlitPacket : public Packet
{
    public:
        FlitType        flitType;
        ProtocolType    protocol;

        // Sequence numbers are timestamps (Tick)
        Tick timestamp;

        uint32_t payloadBytes;

        // True if this flit is being replayed from the retry buffer
        bool isRetransmission;

        // Holds strong references to original TLPs for unpack & retry
        std::vector<PacketPtr> originalPackets;

        // TLP Segmentation Flags
        bool isFirstSegment;
        bool isLastSegment;
        bool isMiddleSegment;

        UcieFlitPacket(RequestPtr req,
                       MemCmd cmd,
                       Tick time_stamp,
                       FlitType type = FlitType::PROTOCOL)
            : Packet(req, cmd, UCIE_FLIT_SIZE_BYTES),
              flitType(type), protocol(ProtocolType::PCIE), timestamp(time_stamp),
              payloadBytes(0), isRetransmission(false),
              isFirstSegment(true), isLastSegment(true), isMiddleSegment(false)
        {
            allocate(); // Allocates 256 bytes in gem5's memory pool
        }
};

struct StagedTLP {
    PacketPtr pkt;
    uint32_t bytesRemaining;
};

// 5. Flit Assembly/Disassembly Engines
class FlitPacker
{
    public: 
        explicit FlitPacker (uint32_t flit_size = UCIE_FLIT_SIZE_BYTES)
            : currentBytes(0) {}
        
        // Changed return type to void!
        void processIncomingTLP(PacketPtr pkt);
        UcieFlitPacket* forceFlush();

        bool hasData() const { return currentBytes > 0; }
        uint32_t stagedBytes() const { return currentBytes; } // ADDED THIS

        // Make assembleFlit public so the Port can call it in a loop
        UcieFlitPacket* assembleFlit(bool isFlush);

    private:
        uint32_t currentBytes;
        // CHANGED from std::vector to our new deque
        std::deque<StagedTLP> tlpQueue; 
};

// 6. Flit Unpacker
class FlitUnpacker
{
    public:
        FlitUnpacker() = default;
        std::vector<PacketPtr> processReceivedFlit(UcieFlitPacket* flit);
        bool hasPartialTLP() const { return !reassemblyBuffer.empty(); }

    private:
        std::vector<uint8_t>    reassemblyBuffer;   // Raw bytes of teh in-progress TLP
        uint32_t                expectedTotalBytes; // Size of the TLP being assembled
};

class UcieLink : public ClockedObject
{
    private:
        class UcieTxPort : public RequestPort
        {
            private:
                UcieLink* owner;
            public:
                UcieTxPort(const std::string& name, UcieLink* owner);
                bool recvTimingResp(PacketPtr pkt) override;
                void recvReqRetry() override;
                void recvRangeChange() override;
        };

        class UcieRxPort : public ResponsePort
        {
            private:
                UcieLink* owner;
            public:
                UcieRxPort(const std::string& name, UcieLink* owner);
                Tick recvAtomic(PacketPtr pkt) override;
                void recvFunctional(PacketPtr pkt) override;
                bool recvTimingReq(PacketPtr pkt) override;
                void recvRespRetry() override;
                AddrRangeList getAddrRanges() const override;
        };

        UcieTxPort      txPort;     
        UcieRxPort      rxPort;     

        FlitPacker      txPacker;   
        FlitUnpacker    rxUnpacker; 

        UcieLinkState linkState;

        // Error modeling
        double errorRate;      
        uint64_t rxFlitCounter;


        // Core Queues
        bool txBlocked;          
        bool rxWaitingForRetry;   
        bool tlpBlocked;
        std::deque<PacketPtr> tlpSendQueue;

        Tick lastProcessedTimestamp;
        std::deque<UcieFlitPacket*> txSendQueue;
        std::deque<UcieFlitPacket*> retryBuffer;
        Tick lastAckedTimestamp;

        // Task-based event handlers matching the paper's scheduling
        void processPackTlp();
        EventFunctionWrapper packTlpEvent;

        void processSendFlit();
        EventFunctionWrapper sendFlitEvent;

        void processRetryTimeout();
        EventFunctionWrapper retryTimeoutEvent;
        Tick retryTimeoutDelay;

        // Transmission Helpers
        void drainTxSendQueue();
        void drainTlpSendQueue();
        void transmitFlit(UcieFlitPacket* flit);

        // ACK/NAK Handlers
        void processAck(Tick ackedTimestamp);
        void processNak(Tick nakTimestamp);
        void sendAck(Tick ackedTimestamp);
        void sendNak(Tick nakTimestamp);

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
            statistics::Scalar totalNaksSent;  
            
            statistics::Scalar totalTLPsReceived;       // TLPs successfully unpacked// NAK flits generated
            statistics::Histogram tlpLatency;           // End-to-end latency timer

            //  Derived metrics (Formula = auto-computed from Scalars)
            statistics::Formula payloadEfficiency;      // totalPayloadBytes / (totalPayloadBytes + totalPaddingBytes)
            statistics::Formula retransmissionRate;     // totalRetransmissions / totalFlitsSent
            statistics::Formula crcErrorRate;           // totalCrcError / totalFlitsReceived

        } stats;

    public:
        explicit UcieLink(const UcieLinkParams& p);
        Port& getPort(const std::string& if_name, PortID idx = InvalidPortID) override;
        void init() override;
};

} // end namespace gem5

#endif // __UCIE_UCIE_LINK_HH__