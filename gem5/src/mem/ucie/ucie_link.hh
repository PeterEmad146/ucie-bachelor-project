// Header guards to prevent double-inclusion during compilation
#ifndef __UCIE_UCIE_LINK_HH__
#define __UCIE_UCIE_LINK_HH__

// This is the auto-generated file created by SCons from UcieLink.py
#include "params/UcieLink.hh"
#include "sim/clocked_object.hh"
#include "mem/port.hh"
#include "mem/packet.hh"
#include <deque>

namespace gem5 
{

// =========================================================================
// WEEK 3: UCIe FLIT PAKCET & PACKER LOGIC
// =========================================================================

// 1. The custom Flit Pakcet (Inherits from gem5's standard Packet)
// This perfectly aligns with the methodology in the reference paper.
class UcieFlitPacket : public Packet
{
    public:
        uint64_t sequenceNumber;    // We will use this next for the Ack/Nak retry buffer
        std::vector<PacketPtr> originalPackets; // The original TLPs packed inside this flit

        // Constructor creates a new packet of the specified flit size
        UcieFlitPacket(RequestPtr req, MemCmd cmd, uint32_t flit_size, uint64_t seq_num)
            : Packet (req, cmd, flit_size), sequenceNumber(seq_num)
        {
            allocate(); // Allocate the physical 256 bytes in the simulator's memory
        }
};

// 2. The Flit Packer Engine
class FlitPacker
{
    private:
        uint32_t targetFlitSize;
        uint32_t currentBytes;
        uint64_t nextSequenceNumber;
        std::vector<PacketPtr> stagingBuffer;   // Temporarily holds TLPs until we reach 256B

    public:
        FlitPacker(uint32_t flit_size);

        // Accepts an incoming TLP. Returns a UcieFlitPacket if 256B is reached 
        // otherwise returns nullptr (meaning it's still waiting for more data)
        UcieFlitPacket* processIncomingTLP(PacketPtr pkt);
};


class UcieLink : public ClockedObject
{
    private:
        // ========================================
        // PORT DEFINITIONS (Bidirectional Link)
        // ========================================

        // Transmit Port (Master/Sender)
        class UcieTxPort : public RequestPort
        {
            private: 
                UcieLink *owner;    // Pointer back to the main controller
            public:
                UcieTxPort(const std::string& name, UcieLink *owner);
                // Called when the adjacent chiplet sends a response back to us
                bool recvTimingResp(PacketPtr pkt) override;
                // Called when the adjacent chiplet is full and tells us to back off
                void recvReqRetry() override;
        };

        // Receive Port (Slave/Receiver)
        class UcieRxPort : public ResponsePort
        {
            private:
                UcieLink *owner;    // Pointer back to the main controller
            public:
                UcieRxPort(const std::string& name, UcieLink *owner);
                // Used for instantaneous, 0-tick memory reads (backdoor access)
                Tick recvAtomic(PacketPtr pkt) override;
                // Used for debugging to instantly write to memory
                void recvFunctional(PacketPtr pkt) override;
                // The main function: Called when a packet actually arrives on the wire
                bool recvTimingReq(PacketPtr pkt) override;
                // Called to tell the sender they can try sending again
                void recvRespRetry() override;
                // Defines what memory addresses this port is responsible for
                AddrRangeList getAddrRanges() const override;
        };

        // ==============================
        // UCIe SPECIFICATION HIERARCHY
        // ==============================

        // Sub-modules encapsulating D2D and PHY functionalities
        // In Week 3, the FlitPacker logic and Ack/Nak queues will live in here.
        struct D2DAdapter {
            uint64_t retryBufferCapacity;
            uint32_t flitSize;

            // Week 3: The Ack/Nak Retry Buffer
            // Holds pointers to flits that have been packed but not yet Acknowledged
            std::deque<UcieFlitPacket*> txRetryBuffer;
        } d2dAdapter;

        struct LogicalPhy {
            int linkWidth;
            Tick linkLatency;
        } logicalPhy;

        // Instantiate the two physical ports
        UcieTxPort txPort;
        UcieRxPort rxPort;

        // Instantiate the FlitPacker
        FlitPacker txPacker;

    public:
        // Constructor that takes the auto-generated Python parameters.
        UcieLink(const UcieLinkParams &p);

        // Required by gem5 to wire the ports together during initialization
        Port &getPort(const std::string &if_name, PortID idx = InvalidPortID) override;
        // Called right before the simuation starts ticking
        void init() override;
};


} // namespace gem5

#endif  // __UCIE_UCIE_LINK_HH__