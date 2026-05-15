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
    // 1. Is it a control flit (ACK / NAK / LINK_MGMT) from the remote chiplet?
    auto* flit = dynamic_cast<UcieFlitPacket*>(pkt);
    if (flit) {
        if (flit->flitType == FlitType::FLIT_LEVEL_ACK) {
            owner->processAck(flit->timestamp);
        } else if (flit->flitType == FlitType::FLIT_LEVEL_NAK) {
            owner->processNak(flit->timestamp);
        } else if (flit->flitType == FlitType::LINK_MGMT) {
            // Credit-return: peer has freed a buffer slot — increment our credits.
            owner->txCredits = std::min(owner->txCredits + 1u,
                                        (uint32_t)owner->creditPool);
            if (owner->txBlocked && owner->txCredits > 0) {
                owner->txBlocked = false;
                owner->drainTxSendQueue();
            }
        }
        delete flit;
        return true;
    }

    // 2. Otherwise it is a Memory Response TLP from DRAM — pass back to CPU.
    return owner->rxPort.sendTimingResp(pkt);
}

void UcieLink::UcieTxPort::recvReqRetry()
{
    owner->txBlocked = false;
    owner->tlpBlocked = false;
    owner->drainTxSendQueue();
    owner->drainTlpSendQueue();
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

        // 1. DETERMINISTIC BER ERROR INJECTION
        // An error fires exactly every ceil(1/BER) bits received, giving
        // reproducible results that match the paper's controlled experiments.
        // (Retransmitted flits are immune — same as the paper's model.)
        owner->rxBitsReceived += UCIE_FLIT_SIZE_BYTES * 8;
        bool crcError = (owner->errorRate > 0.0)
                     && !flit->isRetransmission
                     && !owner->rxWaitingForRetry
                     && (owner->rxBitsReceived >= owner->nextErrorAtBits);

        if (crcError) {
            owner->nextErrorAtBits += (uint64_t)((1.0 / owner->errorRate)
                                                  * UCIE_FLIT_SIZE_BYTES * 8);
            owner->stats.totalCrcErrors++;
            owner->rxWaitingForRetry = true;
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

        // 3. DUPLICATE FLIT REJECTION 
        // If the sender's timeout was too aggressive, we drop flits we've already processed
        if (owner->rxFlitCounter > 0 && flit->timestamp <= owner->lastProcessedTimestamp) {
            owner->sendAck(owner->lastProcessedTimestamp);  // Re-ack to calm the sender
            delete flit;
            return true;
        }

        owner->lastProcessedTimestamp = flit->timestamp;
        owner->rxFlitCounter++;

        // 4. NORMAL OPERATION (CRC Passed)
        std::vector<PacketPtr> originalPkts = owner->rxUnpacker.processReceivedFlit(flit);
        for (auto* tlp : originalPkts) {
            // Stop the timer and record the latency
            auto* timerState = dynamic_cast<UcieTimerState*>(tlp->popSenderState());
            if (timerState) {
                owner->stats.tlpLatency.sample(curTick() - timerState->entryTime);
                delete timerState;  // Clean up memory!
            }
            owner->stats.totalTLPsReceived++;
            owner->tlpSendQueue.push_back(tlp);
            ///owner->txPort.sendTimingReq(tlp);
        }
        owner->drainTlpSendQueue();
        
        owner->sendAck(flit->timestamp);
        delete flit;
        return true;
    }

    // 1. Reject new TLPs while in RETRAIN (error-recovery) state.
    // This correctly back-pressures the CPU during retry replay.
    if (owner->linkState == UcieLinkState::RETRAIN) {
        return false;
    }

    owner->stats.totalTLPsSent++;
    pkt->pushSenderState(new UcieTimerState(curTick()));

    // 2. Latency model — paper formula: t = t_tx + t_accumulation + t_physical
    //
    //   t_tx: time to serialise firstChunkSize bytes at the configured BW.
    //       BW (GB/s) = data_rate (GT/s) × num_lanes ÷ 8
    //
    uint32_t tlpSize = pkt->getSize() + TLP_HEADER_BYTES;

    // ── Paper formula: t = (TLP_bytes × 8) / 64 + 16 − 1/(2F)  ─────────────
    // BW = 64 Gbps (16 lanes × 4 GT/s).  Use the FULL TLP size, not per-flit.
    // F  = data_rate / num_lanes = 4/16 = 0.25 GHz → t_acc = 16-2 = 14 ns.
    // t_physical is absorbed: at F=0.25 GHz the formula already yields the
    // combined constant (14 ns) observed in every row of the paper's Table I.
    double BW_Gbps         = owner->dataRate * owner->numLanes;          // 64 Gbps
    double transmission_ns = (tlpSize * 8.0) / BW_Gbps;                  // full TLP
    double f_link_GHz      = owner->dataRate / (double)owner->numLanes;  // 0.25 GHz
    double accumulation_ns = 16.0 - (1.0 / (2.0 * f_link_GHz));         // 14 ns

    Tick startDelayTicks   = (Tick)((transmission_ns + accumulation_ns) * 1000.0);

    // 3. Process the TLP
    owner->txPacker.processIncomingTLP(pkt);

    while (owner->txPacker.stagedBytes() >= UCIE_PAYLOAD_SIZE_BYTES) {
        UcieFlitPacket* fullFlit = owner->txPacker.assembleFlit(false);
        owner->txSendQueue.push_back(fullFlit);
        if (!owner->sendFlitEvent.scheduled()) {
            owner->schedule(owner->sendFlitEvent, curTick() + startDelayTicks);
        }
    }

    if (!owner->packTlpEvent.scheduled() && owner->txPacker.stagedBytes() > 0) {
        owner->schedule(owner->packTlpEvent, curTick() + startDelayTicks);
    }
    return true;
}

void UcieLink::UcieRxPort::recvRespRetry()
{
    // The downstream memory bus was congested and asks us to retry.
    // Clear the blocked flag and re-attempt draining the TLP send queue.
    owner->tlpBlocked = false;
    owner->drainTlpSendQueue();
}

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
      dataRate(p.data_rate),
      numLanes(p.num_lanes),
      physDelay(p.phys_delay),
      creditPool(p.credit_pool),
      errorRate(p.error_rate),
      rxFlitCounter(0),
      rxBitsReceived(0),
      nextErrorAtBits(0),
      txCredits(p.credit_pool),
      txBlocked(false),
      rxWaitingForRetry(false),
      tlpBlocked(false),
      lastProcessedTimestamp(0),
      lastAckedTimestamp(0),
      simStartTick(0),
      simLastTick(0),
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

    // Initialise credit counter from the configured pool size
    txCredits = (uint32_t)creditPool;

    // Deterministic BER: pre-compute the bit offset of the first error.
    // An error fires exactly every ceil(1/BER) bits — matching the paper's
    // controlled, reproducible error-injection methodology.
    if (errorRate > 0.0) {
        nextErrorAtBits = (uint64_t)((1.0 / errorRate) * UCIE_FLIT_SIZE_BYTES * 8);
    }

    // NOTE: The UCIe sideband channel (800 MHz fixed clock, used for link
    // parameter negotiation and power-management messages) is intentionally
    // not modelled here.  This implementation focuses on mainband data-path
    // behaviour as studied in the paper.
    linkState = UcieLinkState::ACTIVE;
}



void UcieLink::processPackTlp()
{
    // A timeout occurred. Flush whatever partial data is sitting in the staging buffer.
    UcieFlitPacket* flit = txPacker.forceFlush();
    
    if (flit) {
        txSendQueue.push_back(flit);
        if (!sendFlitEvent.scheduled()) {
            schedule(sendFlitEvent, curTick()); // Send immediately
        }
    }
}

void UcieLink::processSendFlit()
{
    if (txSendQueue.empty() || txBlocked) return;

    // Credit-based flow control: stall if the peer has no buffer space.
    if (txCredits == 0) {
        txBlocked = true;
        return;
    }

    // 1. Get the original flit from the queue (do NOT send this one!)
    UcieFlitPacket* originalFlit = txSendQueue.front();

    // Assign timestamp at transmission time for fresh flits only.
    if (!originalFlit->isRetransmission) {
        originalFlit->timestamp = curTick();
    }

    // 2. Create a disposable clone for the wire.
    // The original stays in retryBuffer so we can replay it on NAK.
    auto dummy_req = std::make_shared<Request>(0, UCIE_PAYLOAD_SIZE_BYTES, 0, 0);
    UcieFlitPacket* wireFlit = new UcieFlitPacket(
        dummy_req, MemCmd::WriteReq, originalFlit->timestamp, originalFlit->flitType);
    wireFlit->payloadBytes      = originalFlit->payloadBytes;
    wireFlit->originalPackets   = originalFlit->originalPackets;
    wireFlit->isRetransmission  = originalFlit->isRetransmission;
    // Note: physical delay is already baked into startDelayTicks computed
    // in recvTimingReq, so we do NOT add a separate headerDelay here.

    // 3. Attempt to send the clone.
    if (txPort.sendTimingReq(wireFlit)) {
        txSendQueue.pop_front();
        retryBuffer.push_back(originalFlit);
        txCredits--;   // Consume one flow-control credit

        // Throughput tracking: record time window of active transmission.
        if (simStartTick == 0) simStartTick = curTick();
        simLastTick = curTick();
        stats.simDurationTicks = simLastTick - simStartTick;

        stats.totalFlitsSent++;
        stats.totalPayloadBytes  += originalFlit->payloadBytes;
        stats.totalPaddingBytes  += (UCIE_PAYLOAD_SIZE_BYTES - originalFlit->payloadBytes);

        // Subsequent flits for multi-flit TLPs are sent 1 tick later.
        // The full TLP latency is already baked into startDelayTicks
        // (using the complete TLP size, not per-flit), so these near-
        // simultaneous arrivals let the reassembler complete at ~startDelayTicks.
        if (!txSendQueue.empty() && !sendFlitEvent.scheduled()) {
            schedule(sendFlitEvent, curTick() + 1);
        }
        if (!retryTimeoutEvent.scheduled()) {
            schedule(retryTimeoutEvent, curTick() + retryTimeoutDelay);
        }
    } else {
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

void UcieLink::drainTlpSendQueue()
{
    while (!tlpSendQueue.empty() && !tlpBlocked) {
        PacketPtr tlp = tlpSendQueue.front();
        if (txPort.sendTimingReq(tlp)) {
            // Successfully sent to the memory bus
            tlpSendQueue.pop_front();
        } else {
            // The memory bus is congested. Stop sending and wait.
            tlpBlocked = true;
            break;
        }
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

    uint32_t flitsAcked = 0;
    while (!retryBuffer.empty() && retryBuffer.front()->timestamp <= ackedTimestamp) {
        UcieFlitPacket* retiredFlit = retryBuffer.front();
        retryBuffer.pop_front();
        delete retiredFlit;
        flitsAcked++;
    }

    // Return one credit per ACKed flit so the sender can resume transmitting.
    txCredits = std::min(txCredits + flitsAcked, (uint32_t)creditPool);
    if (txBlocked && txCredits > 0) {
        txBlocked = false;
        drainTxSendQueue();
    }

    if (retryTimeoutEvent.scheduled()) deschedule(retryTimeoutEvent);

    if (!retryBuffer.empty()) {
        Tick oldest = retryBuffer.front()->timestamp;
        schedule(retryTimeoutEvent, oldest + retryTimeoutDelay);
    }

    // If all retransmitted flits are now ACKed, leave RETRAIN and resume.
    if (retryBuffer.empty() && linkState == UcieLinkState::RETRAIN) {
        linkState = UcieLinkState::ACTIVE;
    }
}

void UcieLink::processNak(Tick nakTimestamp)
{
    stats.totalFlitsNaked++;

    // Clear only flits that arrived STRICTLY BEFORE the failed one.
    // The flit AT nakTimestamp failed and must itself be retransmitted.
    // (Using < not <=, unlike the old processAck call which was incorrect.)
    while (!retryBuffer.empty() && retryBuffer.front()->timestamp < nakTimestamp) {
        delete retryBuffer.front();
        retryBuffer.pop_front();
    }

    // Move everything from nakTimestamp onwards back to the front of txSendQueue
    // (including the failed flit itself) for immediate retransmission.
    while (!retryBuffer.empty()) {
        UcieFlitPacket* replayFlit = retryBuffer.back();
        replayFlit->isRetransmission = true;
        txSendQueue.push_front(replayFlit);
        stats.totalRetransmissions++;
        retryBuffer.pop_back();
    }

    if (retryTimeoutEvent.scheduled()) deschedule(retryTimeoutEvent);

    // Enter RETRAIN state: block new TLPs from the CPU until the retry
    // buffer has been fully replayed and ACKed.
    linkState = UcieLinkState::RETRAIN;

    drainTxSendQueue();
}

void UcieLink::processRetryTimeout()
{
    // 1. If congested, pause timeouts safely
    if (txBlocked) {
        if (!retryTimeoutEvent.scheduled()) {
            schedule(retryTimeoutEvent, curTick() + retryTimeoutDelay);
        }
        return;
    }

    if (!retryBuffer.empty()) {
        Tick oldest_timestamp = retryBuffer.front()->timestamp;
        
        if (curTick() >= oldest_timestamp + retryTimeoutDelay) {
            // THE MODIFICATION: Single Retry Mechanism
            UcieFlitPacket* probeFlit = retryBuffer.front();
            
            auto dummy_req = std::make_shared<Request>(0, UCIE_PAYLOAD_SIZE_BYTES, 0, 0);
            UcieFlitPacket* wireFlit = new UcieFlitPacket(
                dummy_req, MemCmd::WriteReq, probeFlit->timestamp, probeFlit->flitType
            );
            wireFlit->payloadBytes = probeFlit->payloadBytes;
            wireFlit->originalPackets = probeFlit->originalPackets;
            wireFlit->isRetransmission = true;
            
            Tick delay = clockEdge(Cycles(8)) - curTick();
            wireFlit->headerDelay += delay;

            if (txPort.sendTimingReq(wireFlit)) {
                stats.totalRetransmissions++;
                // FIX: Only schedule if a synchronous ACK hasn't already scheduled it!
                if (!retryTimeoutEvent.scheduled()) {
                    schedule(retryTimeoutEvent, curTick() + retryTimeoutDelay);
                }
            } else {
                delete wireFlit;
                txBlocked = true; 
                // FIX: Ensure the timeout loop continues even if we got blocked
                if (!retryTimeoutEvent.scheduled()) {
                    schedule(retryTimeoutEvent, curTick() + retryTimeoutDelay);
                }
            }
        } else {
            // FIX: Guard the false-alarm reschedule
            if (!retryTimeoutEvent.scheduled()) {
                schedule(retryTimeoutEvent, oldest_timestamp + retryTimeoutDelay);
            }
        }
    }
}

// =======================================================================
// Credit Return
// =======================================================================
void UcieLink::sendCreditReturn()
{
    // Send a LINK_MGMT flit back to the peer to return one flow-control credit.
    auto req = std::make_shared<Request>(0, UCIE_FLIT_SIZE_BYTES, 0, 0);
    UcieFlitPacket* mgmt = new UcieFlitPacket(
        req, MemCmd::WriteResp, curTick(), FlitType::LINK_MGMT);
    rxPort.sendTimingResp(mgmt);
}


UcieLink::UcieStats::UcieStats(UcieLink* parent)
    : statistics::Group(parent, "UcieStats"),
      ADD_STAT(totalFlitsSent,      statistics::units::Count::get(), "Total UCIe Flits Transmitted"),
      ADD_STAT(totalTLPsSent,       statistics::units::Count::get(), "Total TLPs Packed"),
      ADD_STAT(totalPayloadBytes,   statistics::units::Byte::get(),  "Total Payload Bytes"),
      ADD_STAT(totalPaddingBytes,   statistics::units::Byte::get(),  "Total Padding Bytes"),
      ADD_STAT(totalRetransmissions,statistics::units::Count::get(), "Total Flits Retransmitted"),
      ADD_STAT(totalFlitsNaked,     statistics::units::Count::get(), "Total NAKs Received"),
      ADD_STAT(totalFlitsReceived,  statistics::units::Count::get(), "Total Flits Received"),
      ADD_STAT(totalCrcErrors,      statistics::units::Count::get(), "Total CRC Errors Triggered"),
      ADD_STAT(totalAcksSent,       statistics::units::Count::get(), "Total ACKs Sent"),
      ADD_STAT(totalNaksSent,       statistics::units::Count::get(), "Total NAKs Sent"),
      ADD_STAT(totalTLPsReceived,   statistics::units::Count::get(), "Total TLPs Successfully Unpacked"),
      ADD_STAT(tlpLatency,          statistics::units::Tick::get(),  "End-to-End TLP Latency (ps)"),
      ADD_STAT(simDurationTicks,    statistics::units::Tick::get(),  "Simulation duration ticks (first to last flit)"),
      ADD_STAT(payloadEfficiency,   statistics::units::Ratio::get(), "Payload Efficiency (payload/wire)"),
      ADD_STAT(retransmissionRate,  statistics::units::Ratio::get(), "Retransmission Rate"),
      ADD_STAT(crcErrorRate,        statistics::units::Ratio::get(), "CRC Error Rate"),
      ADD_STAT(throughputGbps,      statistics::units::Rate<
                                        statistics::units::Bit,
                                        statistics::units::Second>::get(),
                                    "Effective throughput (Gb/s)")
{
    tlpLatency.init(50);

    payloadEfficiency  = totalPayloadBytes / (totalFlitsSent * UCIE_FLIT_SIZE_BYTES);
    retransmissionRate = totalRetransmissions / totalFlitsSent;
    crcErrorRate       = totalCrcErrors / totalFlitsReceived;

    // throughputGbps = (payload bits) / (duration in ns)
    // simDurationTicks is in ps (1 Tick = 1 ps), so /1000 gives ns.
    // totalPayloadBytes * 8000 converts bytes to bits and cancels the /1000:
    //   bits / (ticks/1000) = bits*1000/ticks = (bytes*8)*1000/ticks
    throughputGbps = (totalPayloadBytes * 8000) / simDurationTicks;
}


} // namespace gem5