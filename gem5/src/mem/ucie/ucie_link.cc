#include "ucie_link.hh"
#include "base/trace.hh"
#include "debug/UcieLink.hh"
#include "sim/system.hh"
#include "mem/request.hh"

#include <cstdlib>

namespace gem5
{

// =======================================================================
// UcieTxPort Implementation
// =======================================================================
UcieLink::UcieTxPort::UcieTxPort(const std::string& name, UcieLink* owner)
    : RequestPort(name), owner(owner) {}

bool UcieLink::UcieTxPort::recvTimingResp(PacketPtr pkt)
{
    // 1. Is it a Flit (Ack/Nak) from the remote chiplet?
    auto* flit = dynamic_cast<UcieFlitPacket*>(pkt);
    if (flit) {
        if (flit->flitType == FlitType::FLIT_LEVEL_ACK) {
            owner->processAck(flit->timestamp);
        } else if (flit->flitType == FlitType::FLIT_LEVEL_NAK) {
            owner->processNak(flit->timestamp);
        }
        delete flit; 
        return true;
    }

    // 2. Otherwise, it is a Memory Response TLP coming from the DRAM!
    // Pass it straight back to the CPU so it doesn't hang waiting for read data.
    return owner->rxPort.sendTimingResp(pkt);
}

void UcieLink::UcieTxPort::recvReqRetry()
{
    owner->txBlocked = false;
    owner->drainTxSendQueue();
}

void UcieLink::UcieTxPort::recvRangeChange()
{
    owner->rxPort.sendRangeChange();
}


// =======================================================================
// FlitPacker Implementation
// =======================================================================
void FlitPacker::processIncomingTLP(PacketPtr pkt)
{
    uint32_t totalTlpSize = pkt->getSize() + 16; 
    tlpQueue.push_back({pkt, totalTlpSize});
    currentBytes += totalTlpSize;
}

UcieFlitPacket* FlitPacker::assembleFlit(bool isFlush)
{
    if (currentBytes == 0) return nullptr;

    uint32_t bytesToPack = std::min(currentBytes, (uint32_t)UCIE_PAYLOAD_SIZE_BYTES);
    auto dummy_req = std::make_shared<Request>(0, UCIE_PAYLOAD_SIZE_BYTES, 0, 0);
    UcieFlitPacket* flit = new UcieFlitPacket(dummy_req, MemCmd::WriteReq, curTick());
    flit->payloadBytes = bytesToPack;
    
    // Pull bytes from our queued TLPs to fill this flit
    uint32_t spaceLeft = bytesToPack;
    while (spaceLeft > 0 && !tlpQueue.empty()) {
        if (tlpQueue.front().bytesRemaining <= spaceLeft) {
            // TLP fully fits in this flit! Pass the pointer to the receiver.
            spaceLeft -= tlpQueue.front().bytesRemaining;
            flit->originalPackets.push_back(tlpQueue.front().pkt);
            tlpQueue.pop_front();
        } else {
            // SEGMENTATION: The TLP is bigger than the remaining space.
            // Leave it in the queue for the next flit, just reduce its bytes.
            tlpQueue.front().bytesRemaining -= spaceLeft;
            spaceLeft = 0;
        }
    }
    
    currentBytes -= bytesToPack;
    return flit;
}

UcieFlitPacket* FlitPacker::forceFlush()
{
    if (hasData()) return assembleFlit(true);
    return nullptr;
}

// =======================================================================
// UcieRxPort Implementation
// =======================================================================
UcieLink::UcieRxPort::UcieRxPort(const std::string& name, UcieLink* owner)
    : ResponsePort(name), owner(owner) {}

Tick UcieLink::UcieRxPort::recvAtomic(PacketPtr pkt)
{
    return owner->txPort.sendAtomic(pkt);
}

void UcieLink::UcieRxPort::recvFunctional(PacketPtr pkt)
{
    owner->txPort.sendFunctional(pkt);
}

AddrRangeList UcieLink::UcieRxPort::getAddrRanges() const
{
    // In a point-to-point link, pass the connected port's ranges
    return owner->txPort.getAddrRanges();
}

bool UcieLink::UcieRxPort::recvTimingReq(PacketPtr pkt)
{
    // Check if this is an incoming Flit from the remote chiplet
    auto* flit = dynamic_cast<UcieFlitPacket*>(pkt);
    if (flit) {
        owner->stats.totalFlitsReceived++;

        // 1. ERROR INJECTION MODELING
        // Roll a random number between 0.0 and 1.0
        double rand_val = (double)std::rand() / RAND_MAX;
        
        if (owner->errorRate > 0.0 && rand_val <= owner->errorRate && !flit->isRetransmission && !owner->rxWaitingForRetry) {
            // CRC Check Failed! Log the error, send a NAK, and drop the flit.
            owner->stats.totalCrcErrors++;
            owner->rxWaitingForRetry = true;    // Lock the receiver
            owner->sendNak(flit->timestamp);
            delete flit; 
            return true;
        }
        
        // 2. GO-BACK-N RECEIVER LOCK
        if (owner->rxWaitingForRetry) {
            if (flit->isRetransmission) {
                // The retransmitted flit finally arrived! Unlock the receiver.
                owner->rxWaitingForRetry = false;
            } else {
                // Out-of-order flit arriving AFTER a drop but BEFORE the retry.
                // Protocol rules dictate we MUST drop it and send NO ACK.
                delete flit;
                return true;
            }
        }

        // 3. NORMAL OPERATION (CRC Passed)
        std::vector<PacketPtr> originalPkts = owner->rxUnpacker.processReceivedFlit(flit);
        for (auto* tlp : originalPkts) {
            owner->txPort.sendTimingReq(tlp);
        }
        
        owner->sendAck(flit->timestamp);
        delete flit;
        return true;
    }

    // Otherwise, it is a local TLP from the CPU. Pack it!
    owner->stats.totalTLPsSent++;
    owner->txPacker.processIncomingTLP(pkt);
    
    // NEW: Build as many FULL flits as possible immediately (handles huge DMA blocks)
    while (owner->txPacker.stagedBytes() >= UCIE_PAYLOAD_SIZE_BYTES) {
        UcieFlitPacket* fullFlit = owner->txPacker.assembleFlit(false);
        owner->txSendQueue.push_back(fullFlit);
        
        if (!owner->sendFlitEvent.scheduled()) {
            owner->schedule(owner->sendFlitEvent, owner->clockEdge(Cycles(8)));
        }
    }

    if (!owner->packTlpEvent.scheduled() && owner->txPacker.stagedBytes() > 0) {
        owner->schedule(owner->packTlpEvent, owner->clockEdge(Cycles(10))); 
    }
    return true;
}

void UcieLink::UcieRxPort::recvRespRetry() {}

// =======================================================================
// FlitUnpacker Implementation
// =======================================================================
std::vector<PacketPtr> FlitUnpacker::processReceivedFlit(UcieFlitPacket* flit)
{
    std::vector<PacketPtr> extracted = flit->originalPackets;
    return extracted;
}

// =======================================================================
// UcieLink Model Implementation
// =======================================================================
UcieLink::UcieLink(const UcieLinkParams& p)
    : ClockedObject(p),
      txPort(p.name + ".tx_port", this),
      rxPort(p.name + ".rx_port", this),
      linkState(UcieLinkState::INIT),
      errorRate(p.error_rate), // From Python params
      rxFlitCounter(0),
      txBlocked(false),
      rxWaitingForRetry(false),
      lastAckedTimestamp(0),
      packTlpEvent([this]{ processPackTlp(); }, name()),
      sendFlitEvent([this]{ processSendFlit(); }, name()),
      retryTimeoutEvent([this]{ processRetryTimeout(); }, name()),
      retryTimeoutDelay(p.retry_timeout),
      stats(this)
{
}

Port& UcieLink::getPort(const std::string& if_name, PortID idx)
{
    if (if_name == "tx_port") return txPort;
    if (if_name == "rx_port") return rxPort;
    return ClockedObject::getPort(if_name, idx);
}

void UcieLink::init()
{
    ClockedObject::init();
    if (!txPort.isConnected() || !rxPort.isConnected()) {
        fatal("UCIeLink ports are not connected!");
    }
    linkState = UcieLinkState::ACTIVE;
}



void UcieLink::processPackTlp()
{
    // A timeout occurred. Flush whatever partial data is sitting in the staging buffer.
    UcieFlitPacket* flit = txPacker.forceFlush();
    
    if (flit) {
        txSendQueue.push_back(flit);
        if (!sendFlitEvent.scheduled()) {
            schedule(sendFlitEvent, clockEdge(Cycles(8)));
        }
    }
}

void UcieLink::processSendFlit()
{
    if (txSendQueue.empty() || txBlocked) return;

    // 1. Get the original flit from the queue (do NOT send this one!)
    UcieFlitPacket* originalFlit = txSendQueue.front();

    // GUARANTEE UNIQUE TIMESTAMPS: 
    // Assign timestamp at transmission, perfectly spacing them by 8 cycles.
    // (Only do this if it's a fresh flit, NOT a retransmission)
    if (!originalFlit->isRetransmission) {
        originalFlit->timestamp = curTick();
    }

    // 2. Create a disposable clone specifically for the wire
    // This ensures the receiving chiplet can safely delete it without destroying our retry data.
    auto dummy_req = std::make_shared<Request>(0, UCIE_PAYLOAD_SIZE_BYTES, 0, 0);
    UcieFlitPacket* wireFlit = new UcieFlitPacket(
        dummy_req, MemCmd::WriteReq, originalFlit->timestamp, originalFlit->flitType
    );
    wireFlit->payloadBytes = originalFlit->payloadBytes;
    wireFlit->originalPackets = originalFlit->originalPackets;
    wireFlit->isRetransmission = originalFlit->isRetransmission;

    // Apply transmission delay to the clone
    Tick delay = clockEdge(Cycles(8)) - curTick();
    wireFlit->headerDelay += delay;

    // 3. Attempt to send the CLONE
    if (txPort.sendTimingReq(wireFlit)) {
        txSendQueue.pop_front();

        retryBuffer.push_back(originalFlit);

        // Track stats accurately
        stats.totalFlitsSent++;
        stats.totalPayloadBytes += originalFlit->payloadBytes;
        stats.totalPaddingBytes += (UCIE_PAYLOAD_SIZE_BYTES - originalFlit->payloadBytes);

        if (!txSendQueue.empty() && !sendFlitEvent.scheduled()) {
            schedule(sendFlitEvent, clockEdge(Cycles(8)));
        }

        if (!retryTimeoutEvent.scheduled()) {
            schedule(retryTimeoutEvent, curTick() + retryTimeoutDelay);
        }
    } else {
        // If the port was busy, clean up the clone and wait
        delete wireFlit;
        txBlocked = true;
    }
}

void UcieLink::drainTxSendQueue()
{
    if (!sendFlitEvent.scheduled()) {
        schedule(sendFlitEvent, clockEdge(Cycles(1)));
    }
}

void UcieLink::sendAck(Tick ackedTimestamp)
{
    auto dummy_req = std::make_shared<Request>(0, UCIE_FLIT_SIZE_BYTES, 0, 0);
    // Changed to WriteResp to safely bypass gem5 internal port checks
    UcieFlitPacket* ackFlit = new UcieFlitPacket(dummy_req, MemCmd::WriteResp, curTick(), FlitType::FLIT_LEVEL_ACK);
    ackFlit->timestamp = ackedTimestamp;
    
    rxPort.sendTimingResp(ackFlit);
    stats.totalAcksSent++;
}

void UcieLink::sendNak(Tick nakTimestamp)
{
    auto dummy_req = std::make_shared<Request>(0, UCIE_FLIT_SIZE_BYTES, 0, 0);
    // Changed to WriteResp to safely bypass gem5 internal port checks
    UcieFlitPacket* nakFlit = new UcieFlitPacket(dummy_req, MemCmd::WriteResp, curTick(), FlitType::FLIT_LEVEL_NAK);
    nakFlit->timestamp = nakTimestamp;
    
    rxPort.sendTimingResp(nakFlit);
    stats.totalNaksSent++;
}

// --- Retry Mechanism (Ack/Nak) ---

void UcieLink::processAck(Tick ackedTimestamp)
{
    lastAckedTimestamp = ackedTimestamp;
    
    while (!retryBuffer.empty() && retryBuffer.front()->timestamp <= ackedTimestamp) {
        UcieFlitPacket* retiredFlit = retryBuffer.front();
        retryBuffer.pop_front();
        delete retiredFlit;
    }
    
    if (retryTimeoutEvent.scheduled()) {
        deschedule(retryTimeoutEvent);
    }
    
    // Only reschedule if there are still pending flits waiting for their own ACKs
    if (!retryBuffer.empty()) {
        Tick oldest_timestamp = retryBuffer.front()->timestamp;
        schedule(retryTimeoutEvent, oldest_timestamp + retryTimeoutDelay);
    }
}

void UcieLink::processNak(Tick nakTimestamp)
{
    stats.totalFlitsNaked++;
    
    // Move flits sent AFTER the nakTimestamp back to the front of the txSendQueue
    while (!retryBuffer.empty()) {
        UcieFlitPacket* replayFlit = retryBuffer.back();
        if (replayFlit->timestamp >= nakTimestamp) {
            replayFlit->isRetransmission = true;
            txSendQueue.push_front(replayFlit); 
            stats.totalRetransmissions++;
            retryBuffer.pop_back();
        } else {
            break; 
        }
    }
    
    // Clear the timeout since we are handling the error now
    if (retryTimeoutEvent.scheduled()) {
        deschedule(retryTimeoutEvent);
    }
    
    drainTxSendQueue();
}

void UcieLink::processRetryTimeout()
{
    if (!retryBuffer.empty()) {
        Tick oldest_timestamp = retryBuffer.front()->timestamp;
        
        // Did it TRULY expire, or did it just get pushed back by continuous traffic?
        if (curTick() >= oldest_timestamp + retryTimeoutDelay) {
            processNak(lastAckedTimestamp);
        } else {
            // False alarm. Reschedule for its actual expiration time.
            schedule(retryTimeoutEvent, oldest_timestamp + retryTimeoutDelay);
        }
    }
}


// =======================================================================
// Statistics Implementation
// =======================================================================
UcieLink::UcieStats::UcieStats(UcieLink* parent)
    : statistics::Group(parent, "UcieStats"),
      ADD_STAT(totalFlitsSent, statistics::units::Count::get(), "Total UCIe Flits Transmitted"),
      ADD_STAT(totalTLPsSent, statistics::units::Count::get(), "Total TLPs Packed"),
      ADD_STAT(totalPayloadBytes, statistics::units::Byte::get(), "Total Payload Bytes"),
      ADD_STAT(totalPaddingBytes, statistics::units::Byte::get(), "Total Padding Bytes"),
      ADD_STAT(totalRetransmissions, statistics::units::Count::get(), "Total Flits Retransmitted"),
      ADD_STAT(totalFlitsNaked, statistics::units::Count::get(), "Total NAKs Received"),
      ADD_STAT(totalFlitsReceived, statistics::units::Count::get(), "Total Flits Received"),
      ADD_STAT(totalCrcErrors, statistics::units::Count::get(), "Total CRC Errors Triggered"),
      ADD_STAT(totalAcksSent, statistics::units::Count::get(), "Total ACKs Sent"),
      ADD_STAT(totalNaksSent, statistics::units::Count::get(), "Total NAKs Sent"),
      ADD_STAT(payloadEfficiency, statistics::units::Ratio::get(), "Payload Efficiency"),
      ADD_STAT(retransmissionRate, statistics::units::Ratio::get(), "Retransmission Rate"),
      ADD_STAT(crcErrorRate, statistics::units::Ratio::get(), "CRC Error Rate")
{
    payloadEfficiency = totalPayloadBytes / (totalPayloadBytes + totalPaddingBytes);
    retransmissionRate = totalRetransmissions / totalFlitsSent;
    crcErrorRate = totalCrcErrors / totalFlitsReceived;
}

} // namespace gem5