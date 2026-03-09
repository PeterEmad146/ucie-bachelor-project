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
    : targetFlitSize(flit_size), 
      currentBytes(0), 
      nextSequenceNumber(1), 
      maxPayloadSize(flit_size-20) {}

UcieFlitPacket* FlitPacker::processIncomingTLP(PacketPtr pkt) 
{
    // // 1. Add the incoming TLP to our temporary staging buffer
    // stagingBuffer.push_back(pkt);
    // currentBytes += pkt->getSize();

    // // 2. Check if we have accumulated enough bytes to form a complete Flit
    // if (currentBytes >= maxPayloadSize) {

    //     // We have enough data! Create a dummy request for the new Flit
    //     RequestPtr flitReq = std::make_shared<Request>(
    //         pkt->getAddr(), targetFlitSize, 0, pkt->req->requestorId()
    //     );

    //     // Create the custom UcieFlitPacket (Inheriting from base Packet)
    //     UcieFlitPacket* flit = new UcieFlitPacket(
    //         flitReq, MemCmd::WriteReq, targetFlitSize, nextSequenceNumber++, false
    //     );

    //     // Move all the stored TLPs into the new Flit container
    //     flit->originalPackets = stagingBuffer;

    //     // Reset the staging buffer for the next batch of data
    //     stagingBuffer.clear();
    //     currentBytes = 0;

    //     // Return the fully packed Flit so it can be transmitted
    //     return flit;
    // }

    // // Not enough data yet. Return nullptr and wait for the next TLP.
    // return nullptr;

    // 1. Does this new packet fit in our remaining 236B payload space?
    if (currentBytes + pkt->getSize() > maxPayloadSize) {
        // NO! It overflows. We must seal and transmit the CURRENT buffer right now.

        RequestPtr flitReq = std::make_shared<Request>(
            pkt->getAddr(), targetFlitSize, 0, pkt->req->requestorId()
        );

        UcieFlitPacket* flit = new UcieFlitPacket(flitReq, MemCmd::WriteReq, targetFlitSize, nextSequenceNumber++, false);
        flit->originalPackets = stagingBuffer;

        // Record EXACTLY how many real bytes are in this flit
        flit->payloadBytes = currentBytes;

        // Clear the buffer, and put the new packet in as the first item of the NEXT flit
        stagingBuffer.clear();
        stagingBuffer.push_back(pkt);
        currentBytes = pkt->getSize();

        return flit;
    }

    // 2. YES! It fits perfectly. Add it to the buffer. 
    stagingBuffer.push_back(pkt);
    currentBytes += pkt->getSize();

    // 3. INSTANT FLUSH: We no longer wait to fill the 236B!
    // The CPU is block waiting for this request, so we transmit immeidately.
    RequestPtr flitReq = std::make_shared<Request>(
        pkt->getAddr(), targetFlitSize, 0, pkt->req->requestorId()
    );

    UcieFlitPacket* flit = new UcieFlitPacket(flitReq, MemCmd::WriteReq, targetFlitSize, nextSequenceNumber++, false);
    flit->originalPackets = stagingBuffer;
    flit->payloadBytes = currentBytes;

    stagingBuffer.clear();
    currentBytes = 0;
    return flit;

    // // 3. Did it happen to fill the 236B perfectly?
    // if (currentBytes == maxPayloadSize) {
    //     RequestPtr flitReq = std::make_shared<Request>(
    //         pkt->getAddr(), targetFlitSize, 0, pkt->req->requestorId()
    //     );

    //     flit = new UcieFlitPacket(flitReq, MemCmd::WriteReq, targetFlitSize, nextSequenceNumber++, false);
    //     flit->originalPackets = stagingBuffer;
    //     flit->payloadBytes = currentBytes;

    //     stagingBuffer.clear();
    //     currentBytes = 0;
        
    //     return flit;
    // }

    // // 4. It fit, but we still have space left over. Wait for more TLPs!
    // return nullptr;
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
    txPacker(p.flit_size),

    // Modern gem5 Statistics Initialization
    totalFlitsSent(this, "totalFlitsSent", "Total number of UCIe flits successfully transmitted"),
    totalTLPsSent(this, "totalTLPsSent", "Total number of original TLPs encapsulated and transmitted"),
    totalPayloadBytes(this, "totalPayloadBytes", "Total valid payload bytes transmitted"),
    totalPaddingBytes(this, "totalPaddingBytes", "Total wasted padding bytes transmitted"),
    totalCrcErrors(this, "totalCrcErrors", "Total number of CRC errors (NAKs) injected"),
    payloadEfficiency(this, "payloadEfficiency", "Ratio of valid payload to total flit data capacity")

{
    // Map the Python parameters to our C++ structs
    d2dAdapter.retryBufferCapacity = p.retry_buffer_capacity;
    d2dAdapter.flitSize = p.flit_size;
    logicalPhy.linkWidth = p.link_width;
    logicalPhy.linkLatency = p.link_latency;
    errorRate = p.error_rate;

    // Define the math for the formula
    payloadEfficiency = totalPayloadBytes / (totalPayloadBytes + totalPaddingBytes);
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
    // Check if the response is one of our custom ACK/NAK packets
    UcieFlitPacket* respFlit = dynamic_cast<UcieFlitPacket*>(pkt);

    if (respFlit != nullptr) {
        if (respFlit->isNak) {
            warn("SENDER: Received NAK for Flit %d! Retransmitting from buffer...", respFlit->sequenceNumber);
        
            // Re-fire the flit sitting at the front of the retry buffer
            if(!owner->d2dAdapter.txRetryBuffer.empty()) {
                UcieFlitPacket* retryFlit = owner->d2dAdapter.txRetryBuffer.front();
                sendTimingReq(retryFlit);
            }
        } else {
            warn("SENDER: Received ACK for Flit %d! Clearing from buffer.", respFlit->sequenceNumber);

            // Success! We can permantely remove the flit from the retry buffer
            if(!owner->d2dAdapter.txRetryBuffer.empty()) {
                // Success! Pull the good flit out of the buffer and permanently delete it
                UcieFlitPacket* goodFlit = owner->d2dAdapter.txRetryBuffer.front();
                owner->d2dAdapter.txRetryBuffer.pop_front();
                delete goodFlit;    // <--- SENDER safely deletes the memory!
            }
        }

        delete respFlit;    // Clean up the ACK/NAK message container
    }

    return true;
}

void UcieLink::UcieTxPort::recvReqRetry() {
    // Week 3 Task: If the other chiplet was busy, it calls this when it's free.
    // Here, we will pull the next flit from the retryBuffer and send it again.
    warn("PORT WAKEUP: The adjacent component is free. Resuming transmission...");

    // Scenario 1: We are Chiplet B and have unpacked TLPs waiting for Memory
    while(!owner->d2dAdapter.rxBuffer.empty()) {
        PacketPtr frontPkt = owner->d2dAdapter.rxBuffer.front();
        bool success = sendTimingReq(frontPkt);

        if (success) {
            owner->d2dAdapter.rxBuffer.pop_front();
        } else {
            return; // Memory got busy again. Exit and wait for the next wakeup.
        }
    }

    // Scenario 2: We are Chiplet A and have packed Flits waiting for Chiplet B
    if (!owner->d2dAdapter.txRetryBuffer.empty())
    {
        UcieFlitPacket* frontFlit = owner->d2dAdapter.txRetryBuffer.front();
        sendTimingReq(frontFlit);
        // We do not pop the buffer here. We wait for the ACK!
    }
    
}

void UcieLink::UcieTxPort::recvRangeChange()
{
    // When the memory controller tells our TX port its address ranges,
    // we immediately pass that information backward out of our RX port!
    owner->rxPort.sendRangeChange();
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
    // Instantly forward the backdoor memory load directly to the memory controller
    owner->txPort.sendFunctional(pkt);    
}

bool UcieLink::UcieRxPort::recvTimingReq(PacketPtr pkt) 
{ 
    // 1. THE TRAFFIC COP: Check if the incoming packet is a UCIe Flit
    UcieFlitPacket* incomingFlit = dynamic_cast<UcieFlitPacket*>(pkt);

    if (incomingFlit != nullptr) {
        // ==========================================================
        // RECEIVER LOGIC (E.g., Chiplet B handling an incoming Flit)
        // ==========================================================

        // ERROR Injection (Dynamic Python Parameter)
        // Generates a float between 0.0 and 1.0, and checks if it's less than our errorRate
        bool crcFailed = ((float)rand()/RAND_MAX) < owner->errorRate;


        if (crcFailed) {
            warn("RECEIVER: [CRC ERROR] Flit %d corrupted! Sending NAK.", incomingFlit->sequenceNumber);

            // Increment the error counter
            owner->totalCrcErrors++;

            // Create a NAK response (Notice we pass 'true' at the end)
            UcieFlitPacket* nakPkt = new UcieFlitPacket(
                incomingFlit->req, MemCmd::WriteReq, 0, incomingFlit->sequenceNumber, true
            );

            // Force the engine to flip all internal Response Flags
            nakPkt->makeResponse();

            sendTimingResp(nakPkt); // Fire NAK back to Sender
            // DO NOT DELETE incomingFlit! Chiplet A needs it to retransmit.
            // delete incomingFlit;    // Trash the corrupted data
            return true;

        }


        warn("RECEIVER: Got a UCIe Flit! Sequence Number: %d. Unpacking %d TLPs...",
            incomingFlit->sequenceNumber, incomingFlit->originalPackets.size());
        
        // // Loop through the flit and extracts the original 64-Byte packets
        // for (PacketPtr originalTLP : incomingFlit->originalPackets) {
        //     // Send the unpacked 64-Byte packet out the TX port to the RAM
        //     bool success = owner->txPort.sendTimingReq(originalTLP);

        //     if(!success) {
        //         warn("RECEIVER: Memory is busy! Failed to send unpacked TLP.");
        //         // (Handling memory backpressure is a task for later)
        //     }
        // }

        // 1. Push all unpacked TLPs into the safe RX Buffer
        for (PacketPtr originalTLP : incomingFlit->originalPackets) {
            owner->d2dAdapter.rxBuffer.push_back(originalTLP);
        }

        // SEND ACKNOWLEDGE (ACK)
        // Flit was good, tell the sender to clear their buffer! (Pass 'false')
        UcieFlitPacket* ackPkt = new UcieFlitPacket(
            incomingFlit->req, MemCmd::WriteReq, 0, incomingFlit->sequenceNumber, false
        );
        ackPkt->makeResponse(); // Force Response flags
        sendTimingResp(ackPkt);

        // DO NOT DELETE incomingFlit! Chiplet A will delete it when it gets this ACK.
        // // Cleanup: We successfully unpacked the data, so we destroy the 
        // // 256-Byte flit container to free up simulator RAM.
        // delete incomingFlit;

        // 2. Attempt to drain the RX buffer into the memory module
        while (!owner->d2dAdapter.rxBuffer.empty()) 
        {
            // Look at the first packet in line
            PacketPtr frontPkt = owner->d2dAdapter.rxBuffer.front();

            // Try to send it
            bool success = owner->txPort.sendTimingReq(frontPkt);

            if(success) {
                // Memory accepted it! Remove it from our waiting room.
                owner->d2dAdapter.rxBuffer.pop_front();
            } else {
                // Memory rejected it! We stop trying and wait for a wake-up call.
                warn("RECEIVER: Memory is busy! Leaving remaining %d TLP(s) in RX Buffer.",
                    owner->d2dAdapter.rxBuffer.size());
                break;
            }
        }
        

    } else {
        // ==========================================================
        // SENDER LOGIC (E.g., Chiplet A handling CPU Traffic)
        // ==========================================================

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
            warn("SENDER: Created new UCIe Flit! Sequence Number: %d, Contains %d original TLPs.",
                packedFlit->sequenceNumber, packedFlit->originalPackets.size());
            
            // (Next task: Push this flit into the Ack/Nak Retry Buffer and send it)
            // 1. Store a copy in the Retry Buffer in case we need to resent it
            owner->d2dAdapter.txRetryBuffer.push_back(packedFlit);
            warn("SENDER: Flit added to Retry Buffer. Buffer currently holds %d flit(s).",
                owner->d2dAdapter.txRetryBuffer.size());

            // 2. Attempt to send the flit across the physical wire via the TX Port!
            // (We pass 'packedFlit', which inherits from Packet, so the port accepts it)
            warn("SENDER: Flit %d transmitted! Contains %d TLPs. [Payload: %d B | Padding: %d B | Protocol: 20B]. Waiting for ACK/NAK...", 
                packedFlit->sequenceNumber,
                packedFlit->originalPackets.size(),
                packedFlit->payloadBytes,
                owner->txPacker.maxPayloadSize - packedFlit->payloadBytes);

            // Record all the traffic statistics!
            owner->totalFlitsSent++;
            owner->totalTLPsSent += packedFlit->originalPackets.size();
            owner->totalPayloadBytes += packedFlit->payloadBytes;
            owner->totalPaddingBytes += (owner->txPacker.maxPayloadSize - packedFlit->payloadBytes);

            bool success = owner->txPort.sendTimingReq(packedFlit);

            if (!success) {
                warn("SENDER: Transmission failed! Flit %d remains in buffer for retry.", packedFlit->sequenceNumber);
                // We leave the flit in the txRetryBuffer. We will try again later
                // when the other chiplet calls recvReqRetry().
            } 
        }
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
    // return AddrRangeList(); 

    // We act as a transparent interconnect! We ask whatever is connected
    // to our TX Port (like the memory module) what addresses it supports,
    // and we pass that answer back up to the CPU.
    return owner->txPort.getAddrRanges();
}

} // namespace gem5