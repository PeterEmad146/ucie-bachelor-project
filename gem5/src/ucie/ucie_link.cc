#include "ucie/ucie_link.hh"
#include "base/trace.hh"
#include "base/logging.hh"

namespace gem5
{

UcieLink::UcieLink(const UcieLinkParams &p) :
    ClockedObject(p), 
    txPort(name() + ".tx_port", this),
    rxPort(name() + ".rx_port", this)
{
    // Initialize strictly to the paper's parameters
    d2dAdapter.retryBufferCapacity = p.retry_buffer_capacity;
    d2dAdapter.flitSize = p.flit_size;
    logicalPhy.linkWidth = p.link_width;
    logicalPhy.linkLatency = p.link_latency;
}

Port &
UcieLink::getPort(const std::string &if_name, PortID idx)
{
    if (if_name == "tx_port") {
        return txPort;
    } else if (if_name == "rx_port") {
        return rxPort;
    } else {
        return ClockedObject::getPort(if_name, idx);
    }
}

void 
UcieLink::init()
{
    ClockedObject::init();
    fatal_if(!txPort.isConnected(), "UCIe TX Port is not connected!");
    fatal_if(!rxPort.isConnected(), "UCIe RX Port is not connected!");
}

// --- TX Port Methods ---
UcieLink::UcieTxPort::UcieTxPort(const std::string& name, UcieLink *owner) : 
    RequestPort(name, owner), owner(owner) {}

bool UcieLink::UcieTxPort::recvTimingResp(PacketPtr pkt) {return true; }
void UcieLink::UcieTxPort::recvReqRetry() {}

// --- RX Port Methods ---
UcieLink::UcieRxPort::UcieRxPort(const std::string& name, UcieLink *owner) :
    ResponsePort(name, owner), owner(owner) {}

Tick UcieLink::UcieRxPort::recvAtomic(PacketPtr pkt) { return owner->logicalPhy.linkLatency; }
void UcieLink::UcieRxPort::recvFunctional(PacketPtr pkt) {}
bool UcieLink::UcieRxPort::recvTimingReq(PacketPtr pkt) { return true; }
void UcieLink::UcieRxPort::recvRespRetry() {}
AddrRangeList UcieLink::UcieRxPort::getAddrRanges() const { return AddrRangeList(); }

} // namespace gem5