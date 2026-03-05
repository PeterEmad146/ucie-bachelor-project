#include "mem/ucie/ucie_link.hh"
#include "base/trace.hh"
#include "base/logging.hh"

namespace gem5
{

// ==========================================================
// WEEK 3: FLIT PACKER IMPLEMENTATION
// ==========================================================

// Initialize the packer with the size from Python (e.g., 256 Bytes)
FlitPacker::FlitPacker(uint32_t flit_size)
    : targetFlitSize(flit_size), currentBytes(0), nextSequenceNumber(0) {}

UcieFlitPacket* FlitPacker::processIncomingTLP(PacketPtr pkt) 
{
    // 1. Add the incoming TLP to our temporary staging buffer
    stagingBuffer.push_back(pkt);
    currentBytes += pkt->getSize();

    // 2. Check if we have accumulated enough bytes to form a complete Flit
    if (currentBytes >= targetFlitSize) {

        // We have enough data! Create a dummy request for the new Flit
        RequestPtr flitReq = std::make_shared<Request>(
            pkt->getAddr(), targetFlitSize, 0, pkt->req->requestorId()
        );

        // Create the custom UcieFlitPacket (Inheriting from base Packet)
        UcieFlitPacket* flit = new UcieFlitPacket(
            flitReq, MemCmd::WriteReq, targetFlitSize, nextSequenceNumber++
        );

        // Move all the stored TLPs into the new Flit container
        flit->originalPackets = stagingBuffer;

        // Reset the staging buffer for the next batch of data
        stagingBuffer.clear();
        currentBytes = 0;

        // Return the fully packed Flit so it can be transmitted
        return flit;
    }

    // Not enough data yet. Return nullptr and wait for the next TLP.
    return nullptr;
}

// ==========================================================
// CONSTRUCTOR & INITIALIZATION 
// ==========================================================
UcieLink::UcieLink(const UcieLinkParams &p) :
    ClockedObject(p), 
    // Initialize the ports with a name, but notice we do NOT pass 'owner'
    // to the base class to avoid the deprecated ownership warnings!
    txPort(name() + ".tx_port", this),
    rxPort(name() + ".rx_port", this),
    txPacker(p.flit_size)
{
    // Map the Python parameters to our C++ structs
    d2dAdapter.retryBufferCapacity = p.retry_buffer_capacity;
    d2dAdapter.flitSize = p.flit_size;
    logicalPhy.linkWidth = p.link_width;
    logicalPhy.linkLatency = p.link_latency;
}

// gem5 calls this function when parsing the Python script (e.g., system.chiplet_A.tx_port)
// to figure out which physical C++ port object to connect the wire to. 
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

// Runs once before tick 0. We use fatal_if to crash the simulator immediately
// if you forgot to wire up the chiplets in the Python script.
void 
UcieLink::init()
{
    ClockedObject::init();
    fatal_if(!txPort.isConnected(), "UCIe TX Port is not connected!");
    fatal_if(!rxPort.isConnected(), "UCIe RX Port is not connected!");
}

// ==========================================================
// TRANSMIT PORT (TX) METHODS
// ==========================================================
UcieLink::UcieTxPort::UcieTxPort(const std::string& name, UcieLink *owner) : 
    RequestPort(name), owner(owner) {}

bool UcieLink::UcieTxPort::recvTimingResp(PacketPtr pkt) 
{
    // Stub: When the other chiplet replies, just say "Yes, I got it"
    return true; 
}
void UcieLink::UcieTxPort::recvReqRetry() {
    // Week 3 Task: If the other chiplet was busy, it calls this when it's free.
    // Here, we will pull the next flit from the retryBuffer and send it again.
}

// ==========================================================
// RECEIVE PORT (RX) METHODS
// ==========================================================
UcieLink::UcieRxPort::UcieRxPort(const std::string& name, UcieLink *owner) :
    ResponsePort(name), owner(owner) {}

Tick UcieLink::UcieRxPort::recvAtomic(PacketPtr pkt) 
{ 
    // For backdoor memory access, return the standard link latency
    return owner->logicalPhy.linkLatency; 
}

void UcieLink::UcieRxPort::recvFunctional(PacketPtr pkt) 
{
    // Instantaneous debug access (does nothing to simulated time)
}

bool UcieLink::UcieRxPort::recvTimingReq(PacketPtr pkt) 
{ 
    // Week 3 Task: This is where the magic happes!
    // When a packet arrives from the other chiplet, we will:
    // 1. Pass it to the D2DAdapater.
    // 2. Use the FlitPacker class to process the 256B flits.
    // 3. Schedule an event based on logicalPhy.linklatency to process it.

    // The CPU or Memory just sent us a packet.
    // Hand it to the D2D Adapter's Flit Packer.
    UcieFlitPacket* packedFlit = owner->txPacker.processIncomingTLP(pkt);

    if (packedFlit != nullptr) {
        // SUCCESS! We formed a complete 256B Flit.
        // We print a debug message to prove it worked.
        warn("Created new UCIe Flit! Sequence Number: %d, Contains %d original TLPs.",
            packedFlit->sequenceNumber, packedFlit->originalPackets.size());
        
            // (Next task: Push this flit into the Ack/Nak Retry Buffer and send it)
    }

    // Tell the CPU we successfully accepted its packet
    return true;
}

void UcieLink::UcieRxPort::recvRespRetry() 
{
    // Stub
}

AddrRangeList UcieLink::UcieRxPort::getAddrRanges() const 
{ 
    // Return an empty list until we start mapping specific memory addresses
    // to the chiplet interconnect space.
    return AddrRangeList(); 
}

} // namespace gem5