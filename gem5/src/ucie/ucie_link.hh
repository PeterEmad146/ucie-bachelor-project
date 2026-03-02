#ifndef __UCIE_UCIE_LINK_HH__
#define __UCIE_UCIE_LINK_HH__

#include "params/UcieLink.hh"
#include "sim/clocked_object.hh"
#include "mem/port.hh"
#include "mem/packet.hh"

namespace gem5 
{

class UcieLink : public ClockedObject
{
    private:
        // ========================================
        // PORT DEFINITIONS (Bidirectional Link)
        // ========================================
        class UcieTxPort : public RequestPort
        {
            private: 
                UcieLink *owner;
            public:
                UcieTxPort(const std::string& name, UcieLink *owner);
                bool recvTimingResp(PacketPtr pkt) override;
                void recvReqRetry() override;
        };

        class UcieRxPort : public ResponsePort
        {
            private:
                UcieLink *owner;
            public:
                UcieRxPort(const std::string& name, UcieLink *owner);
                Tick recvAtomic(PacketPtr pkt) override;
                void recvFunctional(PacketPtr pkt) override;
                bool recvTimingReq(PacketPtr pkt) override;
                void recvRespRetry() override;
                AddrRangeList getAddrRanges() const override;
        };

        // ==============================
        // UCIe SPECIFICATION HIERARCHY
        // ==============================

        // Sub-modules encapsulating D2D and PHY functionalities
        struct D2DAdapter {
            uint64_t retryBufferCapacity;
            uint32_t flitSize;
        } d2dAdapter;

        struct LogicalPhy {
            int linkWidth;
            Tick linkLatency;
        } logicalPhy;

        UcieTxPort txPort;
        UcieRxPort rxPort;

    public:
        UcieLink(const UcieLinkParams &p);

        Port &getPort(const std::string &if_name, PortID idx = InvalidPortID) override;
        void init() override;
};

} // namespace gem5

#endif  // __UCIE_UCIE_LINK_HH__