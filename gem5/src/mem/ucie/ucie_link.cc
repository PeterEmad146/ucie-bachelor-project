// ================================================================================
//  UcieLink.cc - UCIe Die-to-Die Link Model Implementation
//
//  Specification References:
//      [UCIe-SPEC]     Universal Chiplet Interconnect Express Specification v1.1
//      [REF-PAPER]     "Efficient Die-to-Die Communication: UCIe Link Simulation
//                       and Optimization in a Chiplet-Based System"
//      [GEM5]          "The gem5 Simulator: Version 20.0"
//  
//  Implemenation Sections:
//      S1  CRC Engine          (UcieCRC namespace)
//      S2  Credit Manager      (UcieCreditManager)
//      S3  Flit Packer         (FlitPacker)
//      S4  Flit Unpacker       (FlitUnpacker)
//      S5  UcieLink Core       (Constructor, init, getPort)
//      S6  Link State Machine  (transitionLinkState, handleMbInit, handleMbTrain)
//      S7  TX Pipeline         (transmitFlit, drainTxSendQueue, flushEvent)
//      S8  ACK/NAK Processing  (processAck, processNak, sendAck, sendNak)
//      S9  TX Port Callbacks   (recvTimingResp, recvReqRetry, recvRangeChange)
//      S10 RX Port Callbacks   (recvTimingReq, recvAtomic, recvFunctional, ...)
//      S11 Statistics          (UcieStats constructor)
//      S12 Diagnostics         (dumpLinkStatus)
// ================================================================================

#include "mem/ucie/ucie_link.hh"
#include "base/trace.hh"
#include "base/logging.hh"

#include <cstring>  // memset, memcpy
#include <cstdlib>  // rand
#include <cassert>

namespace gem5
{

// ================================================================================
//  S1  CRC ENGINE
//
//  UCIe mandates CRC-32 (IEEE 802.3 polynomial 0x04C11DB7, reflected input and 
//  output) applied independently to each 64-byte group in the 256-byte flit.
//  A pre-computed 256-entry lookup table is used for simulation speed.
//
//  Four CRC groups per flit:
//      Group 0: bytes [  0 -  63]  (header + first 56B of payload)
//      Group 1: bytes [ 64 - 127]   
//      Group 2: bytes [128 - 191]
//      Group 3: bytes [192 - 255]  (last payload bytes + padding)
//  The 12-byte CRC field stores crcGroups[0..2]; crcGroups[3] carries link
//  status bits rather than a data CRC 
// ================================================================================
namespace UcieCRC
{
    // CRC-32 lookup table (generated once at program start)
    // Polynomial: 0xEDB88320 (reflected form of 0x04C1DB7)
    static uint32_t crcTable[256];
    static bool     tableInitialized = false;

    static void initTable()
    {
        if (tableInitialized) return;
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t crc = i;
            for (int j = 0; j < 8; ++j) {
                crc = (crc & 1) ? (0xEDB88320u ^ (crc >> 1)) : (crc >> 1);
            }
            crcTable[i] = crc;
        }
        tableInitialized = true;
        warn("[UCIe CRC] CRC-32 lookup table initialized (poly=0xEDB88320).");
    }

    // Compute CRC-32 over [data, data+length)
    uint32_t compute(const uint8_t* data, size_t length)
    {
        initTable();
        uint32_t crc = 0xFFFFFFFFu;
        for (size_t i = 0; i < length; ++i) {
            crc = crcTable[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
        }
        return crc ^ 0xFFFFFFFFu;
    }

    // Generate all four CRC groups for a flit before transmission.
    // We operate on the raw 256-byte flit data buffer via getConstPtr<uint8_t>().
    // 
    // gem5 Packet API note:
    //      getConstPtr<uint8_t>()  - read-only pointer to the packet's data buffer
    //      getPtr<uint8_t>()       - read/write pointer (required allocated buffer)
    void generateFlitCRC(UcieFlitPacket* flit)
    {
        assert(flit != nullptr);
        const uint8_t* raw = flit->getConstPtr<uint8_t>();  // 256B flit buffer

        // Compute CRC-32 for each 64-byte group
        for (int group = 0; group < 4; ++group) {
            flit->crcGroups[group] = compute(raw + (group * 64), 64);
        }

        warn("[UCIe CRC] Flit seq=%u: CRC generated. "
             "Groups: [0x%08X, 0x%08X, 0x%08X, 0x%08X]",
             flit->sequenceNumber, 
             flit->crcGroups[0], flit->crcGroups[1],
             flit->crcGroups[2], flit->crcGroups[3]);
    }

    // Verify CRC of a received flit. Sets flit->crcValid.
    // Returns true if all groups pass; false if any group fails.
    bool verifyFlitCRC(UcieFlitPacket* flit)
    {
        assert(flit != nullptr);
        const uint8_t* raw = flit->getConstPtr<uint8_t>();

        for(int group = 0; group < 4; ++group) {
            uint32_t computed = compute(raw + (group * 64), 64);
            if(computed != flit->crcGroups[group]) {
                warn("[UCIe CRC] Flit seq=%u: CRC FAIL on group %d. "
                     "Expected=0x%08X Got=0x%08X",
                     flit->sequenceNumber, group,
                     flit->crcGroups[group], computed);
                return false;
            }
        }

        flit->crcValid = true;
        warn("[UCIe CRC] Flit seq=%u: CRC OK - all 4 groups verified.",
             flit->sequenceNumber);
        return true;
    }
} // namespace UcieCRC

// ================================================================================
//  S2 CREDIT MANAGER 
//
//  Credit pools are per-message-class (NPR, PR, CPL). Initial values are
//  negotiated during MBTRAIN and then maintained through piggyback returns.
//
//  Data credit unit = 4 bytes of TLP payload 
//  Header credit    = permission to send on TLP header entry.
// ================================================================================

UcieCreditManager::UcieCreditManager()
{
    reset();
}

void UcieCreditManager::reset()
{
    for (int cls = 0; cls < NUM_MSG_CLASSES; ++cls) {
        pools[cls].txAvailable = INITIAL_HEADER_CREDITS;
        pools[cls].rxGranted   = INITIAL_HEADER_CREDITS;
        pools[cls].rxConsumed  = 0;
    }
    warn("[UCIe Credits] Credit pools reset. "
         "Initial header credits=%u per class, data credits=%u.",
         INITIAL_HEADER_CREDITS, INITIAL_DATA_CREDITS);
}

bool UcieCreditManager::canSend(MessageClass cls, uint32_t payloadBytes) const
{
    int idx = static_cast<int>(cls);
    // Check: at least 1 header credit AND enough data credits (4B units)
    uint32_t dataCreds = (payloadBytes + 3) / 4;    // round up to 4B units
    bool hdrOk = (pools[idx].txAvailable >= 1);
    bool dataOk = (pools[idx].txAvailable >= dataCreds);
    return hdrOk && dataOk;
}

void UcieCreditManager::consumeCredits(MessageClass cls, uint32_t payloadBytes)
{
    int idx = static_cast<int>(cls);
    uint32_t dataCreds = (payloadBytes + 3) / 4;

    // Guard: never go negative (programming error if this fires)
    assert(pools[idx].txAvailable >= dataCreds);

    pools[idx].txAvailable -= dataCreds;
    pools[idx].rxConsumed  += dataCreds;

    warn("[UCIe Credits] Class=%d consumed %u data credits. "
         "TX available=%u.",
         idx, dataCreds, pools[idx].txAvailable);
}

void UcieCreditManager::returnCredits(uint8_t headerCreds, uint8_t dataCreds, MessageClass cls)
{
    int idx = static_cast<int>(cls);
    pools[idx].txAvailable += headerCreds + dataCreds;

    warn("[UCIe Credits] Class=%d returned hdr=%u data=%u credits. "
         "TX available now=%u.",
         idx, headerCreds, dataCreds, pools[idx].txAvailable);
}

// ================================================================================
//  S3 FLIT PACKER ENGINE (D2D Adapter TX path)
//
//  Implements the flit assembly algorithm described in [REF-PAPER]
//  Two packing triggers:
//      a) Payload Full : staged bytes reach UCIE_PAYLOAD_SIZE_BYTES (236B)
//      b) Timer Flush  : 8-cycle timeout fires -> partial flit with zero-padding
//
//  TLP Segmentation:
//      If a single TLP exceeds 236B it is split. The first 236B fill flit N
//      (isFirstSegment=true, isLastSegment=false). The remainder is stored in
//      segmentResidue and prepended to the next flit assembly cycle.
// ================================================================================

FlitPacker::FlitPacker(uint32_t flit_size)
    : flitSize(flit_size),
      maxPayloadSize(flit_size - UCIE_HEADER_SIZE_BYTES - UCIE_CRC_SIZE_BYTES),
      currentBytes(0),
      nextSequenceNumber(0)
{
    warn("[UCIe Packer] Initialized. flitSize=%uB payloadLimit=%uB "
         "(header=%uB + CRC=%uB overhead).",
         flitSize, maxPayloadSize,
         UCIE_HEADER_SIZE_BYTES, UCIE_CRC_SIZE_BYTES);
}

// assignSequenceNumber - 7-bit wrapping counter 
uint8_t FlitPacker::assignSequenceNumber()
{
    uint8_t seq = nextSequenceNumber;
    nextSequenceNumber = (nextSequenceNumber + 1) % UCIE_MAX_SEQ_NUM;
    return seq;
}

// assembleFlit - build a UcieFlitPacker from the current staging buffer.
// isPartial = true when called by forceFlush (timer or overflow).
// isPartial = false when payload is exactly 236B.
UcieFlitPacket* FlitPacker::assembleFlit(bool isPartial)
{
    assert(!stagingBuffer.empty() || !segementResidue.empty());

    // Use the address of the first packet's request as the flit address
    RequestPtr flitReq = std::make_shared<Request>(
        stagingBuffer.empty()
            ? 0
            : stagingBuffer.front()->getAddr(),
        flitSize, 0,
        stagingBuffer.empty()
            ? 0
            : stagingBuffer.front()->req->requestorId()
    );

    uint8_t seq = assignSequenceNumber();

    UcieFlitPacket* flit = new UcieFlitPacket(
        flitReq, MemCmd::WriteReq, seq, FlitType::PROTOCOL
    );

    // Transfer TLPs from staging -> flit
    flit->originalPackets = stagingBuffer;
    flit->payloadBytes    = currentBytes;
    flit->paddingBytes    = maxPayloadSize - currentBytes;

    // Segmentation flags: most flits are single-TLP non-segmented
    flit->isFirstSegment  = true;
    flit->isLastSegment   = currentBytes;
    flit->paddingBytes    = maxPayloadSize - currentBytes;

    // Segmentation flags: most flits are single-TLP non-segmented
    flit->isFirstSegment  = true;
    flit->isLastSegment   = segementResidue.empty();    // false if TLP split
    flit->isMiddleSegment = false;

    // Write zero-padding into the raw flit buffer for correct CRC coverage
    // getPtr<uint8_t>() - mutable pointer, valid because allocate() was called
    // in UcieFlitPacket's constructor.
    uint8_t* rawData = flit->getPtr<uint8_t>();
    if (flit->paddingBytes > 0) {
        std::memset(rawData + UCIE_HEADER_SIZE_BYTES + flit->payloadBytes,
                    0x00, flit->paddingBytes);
    }

    warn("[UCIe Packer] Assembled flit seq=%u. "
         "TLPs=%zu payloadBytes=%u paddingBytes=%u partial=%s "
         "firstSeg=%s lastSeq=%s.",
         seq,
         flit->originalPackets.size(),
         flit->payloadBytes,
         flit->paddingBytes,
         isPartial ? "YES" : "NO",
         flit->isFirstSegment ? "true" : "false",
         flit->isLastSegment  ? "true" : "false");

    // Reset staging state
    stagingBuffer.clear();
    currentBytes = 0;

    return flit;
}

// processIncoming TLP - main packer entry point
//
// Algorithm 
//      1. If TLP > 236B: split into head (236B) + residue
//      2. If adding TLP overflows staged bytes: flush current buffer first
//      3. Add TLP to staging buffer
//      4. If staging buffer is exactly full: flush immediately
UcieFlitPacket* FlitPacker::processIncomingTLP(PacketPtr pkt)
{
    warn("[UCIe Packer] Incoming TLP size=%Ub. Currently staged=%uB.",
         pkt->getSize(), currentBytes);

    UcieFlitPacket* flit = nullptr;

    // Case 1: TLP larger than one full flit payload -> segment it
    if (pkt->getSize() > maxPayloadSize) {
        warn("[UCIe Packer] TLP size=%uB exceeds payload limit=%uB. "
             "Segmenting across multiple flits.", pkt->getSize(), maxPayloadSize);

        // Store the remainder for the next flit assembly cycle
        // getConstPtr<uint8_t>() - read-only access to the incoming TLP's raw bytes
        const uint8_t* tlpData = pkt->getConstPtr<uint8_t>();
        segementResidue.assign(tlpData + maxPayloadSize,
                               tlpData + pkt->getSize());

        // Stage only the first 236B (we synthesize a partial staging entry)
        stagingBuffer.push_back(pkt);
        currentBytes = maxPayloadSize;      // artificially cap at payload limit

        flit = assembleFlit(false);
        flit->isLastSegment = false;        // more segment follow
        return flit;
    }

    // Case 2: Adding this TLP would overflow current staging -> flush first
    if(currentBytes + pkt->getSize() > maxPayloadSize) {
        warn("[UCIe Packer] Adding TLP(%uB) would overflow staging(%uB/%uB). "
             "Flushing current buffer first.",
             pkt->getSize(), currentBytes, maxPayloadSize);
        flit = assembleFlit(true);      // flush existing partial buffer
    }

    // Case 3: Stage the incoming TLP
    stagingBuffer.push_back(pkt);
    currentBytes += pkt->getSize();

    // Case 4: Staging buffer is exactly full -> flush immediately
    if (currentBytes == maxPayloadSize) {
        warn("[UCIe Packer] Staging buffer full (%uB). Immediate flush.",
             currentBytes);
        // Only flush now if we didn't already flush in Case 2
        if (flit == nullptr) {
            flit = assembleFlit(false);
        }
    }

    return flit;    // nullptr = still accumulating; non-null = flit read
}

// forceFlush - drain staging buffer unconditionally (timer-triggered).
// If nothing is staged, returns nullptr.
UcieFlitPacket* FlitPacker::forceFlush()
{
    if (stagingBuffer.empty() && segementResidue.empty()) {
        warn("[UCIe Packer] forceFlush called but staging buffer is empty. "
             "Nothing to flush.");
        return nullptr;
    }

    warn("[UCIe Packer] forceFlush: sealing partial flit with %uB payload, "
         "%uB padding.", currentBytes, maxPayloadSize - currentBytes);

    return assembleFlit(true);
}

// ================================================================================
//  S4 FLIT UNPACKER ENGINE (D2D Adapter RX path)
//
//  Processes received flits: extracts TLPs, handles multi-flit segmentation
//  reassembly, and signals to the caller whether CRC passed.
// ================================================================================
std::vector<PacketPtr> FlitUnpacker::processReceivedFlit(UcieFlitPacket* flit)
{
    assert(flit != nullptr);
    std::vector<PacketPtr> extractedTLPs;

    // CRC must already be verified by the caller (UcieRxPort::recvTimingReq)
    if (!flit->crcValid) {
        warn("[UCIe Unpacker] Flit seq=%u: CRC invalid - dropping payload. "
             "Caller should issue NAK.", flit->sequenceNumber);
        return extractedTLPs;     // empty vector signals failure to caller
    }

    warn("[UCIe Unpacker] Flit seq=%u: Unpacking %zu TLPs "
         "(payload=%uB, padding=%uB). firstSeg=%s lastSeg=%s.",
         flit->sequenceNumber,
         flit->originalPackets.size(),
         flit->payloadBytes,
         flit->payloadBytes,
         flit->paddingBytes,
         flit->isFirstSegment ? "true" : "false",
         flit->isLastSegment  ? "true" : "false");

    // Non-segmented flit (most common case): extract all TLPs directly
    if (flit->isFirstSegment && flit->isLastSegment) {
        for (PacketPtr tlp : flit->originalPackets) {
            extractedTLPs.push_back(tlp);
            warn("[UCIe Unpacker] Extracted TLP addr=0x%llx size=%uB.",
                 (unsigned long long)tlp->getAddr(), tlp->getSize());
        }
        return extractedTLPs;
    }

    // First segment of a multi-flit TLP: begin reassembly
    if (flit->isFirstSegment && !flit->isLastSegment) {
        warn("[UCIe Unpacker] First segment of split TLP received. "
             "Starting reassembly buffer (%uB).", flit->payloadBytes);
        const uint8_t* raw = flit->getConstPtr<uint8_t>() + UCIE_HEADER_SIZE_BYTES;
        reassemblyBuffer.assign(raw, raw + flit->payloadBytes);
        expectedTotalBytes = 0;     // Will be determined on last segment
        return extractedTLPs;         // Nothing complete yet
    }

    // Middle or last segment: append to reassembly buffer
    if (flit->isMiddleSegment || flit->isLastSegment) {
        const uint8_t* raw = flit->getConstPtr<uint8_t>() + UCIE_HEADER_SIZE_BYTES;
        reassemblyBuffer.insert(reassemblyBuffer.end(),
                                raw, raw + flit->payloadBytes);
        warn("[UCIe Unpacker] Segment appended. Reassembly buffer now=%zuB. "
             "Last segment=%s.",
             reassemblyBuffer.size(),
             flit->isLastSegment ? "YES" : "NO");

        if (flit->isLastSegment) {
            // Reassembly complete — the originalPackets in the last flit
            // holds the reconstructed TLP reference
            for (PacketPtr tlp : flit->originalPackets) {
                extractedTLPs.push_back(tlp);
                warn("[UCIe Unpacker] Reassembled TLP addr=0x%llx size=%uB.",
                     (unsigned long long)tlp->getAddr(), tlp->getSize());
            }
            reassemblyBuffer.clear();
        }
    }

    return extractedTLPs;
}

// ================================================================================
//  S5 UCIELINK CORE - Constructor, init(), getPort()
// ================================================================================

// Statistics group constructor
// gem5 ADD_STAT macro registers each stat with the gem5 statistics engine.
UcieLink::UcieStats::UcieStats(UcieLink* parent)
    : statistics::Group(parent),
      ADD_STAT(totalFlitsSent,       statistics::units::Count::get(),
               "Total UCIe flits pushed to TX port"),
      ADD_STAT(totalTLPsSent,        statistics::units::Count::get(),
               "Total Protocol-Layer TLPs encapsulated and sent"),
      ADD_STAT(totalPayloadBytes,    statistics::units::Byte::get(),
               "Total valid TLP payload bytes transmitted"),
      ADD_STAT(totalPaddingBytes,    statistics::units::Byte::get(),
               "Total zero-padding bytes added (wasted bandwidth)"),
      ADD_STAT(totalRetransmissions, statistics::units::Count::get(),
               "Flits retransmitted due to NAK (Flit-Level Retry)"),
      ADD_STAT(totalFlitsNaked,      statistics::units::Count::get(),
               "NAK responses received from remote chiplet"),
      ADD_STAT(totalFlitsReceived,   statistics::units::Count::get(),
               "Total UCIe flits received on RX port"),
      ADD_STAT(totalCrcErrors,       statistics::units::Count::get(),
               "Received flits that failed CRC verification"),
      ADD_STAT(totalAcksSent,        statistics::units::Count::get(),
               "ACK flits generated and sent"),
      ADD_STAT(totalNaksSent,        statistics::units::Count::get(),
               "NAK flits generated and sent"),
      ADD_STAT(payloadEfficiency,    statistics::units::Ratio::get(),
               "Fraction of flit capacity carrying real TLP data: "
               "payloadBytes / (payloadBytes + paddingBytes)"),
      ADD_STAT(retransmissionRate,   statistics::units::Ratio::get(),
               "Retransmitted flits / total flits sent"),
      ADD_STAT(crcErrorRate,         statistics::units::Ratio::get(),
               "CRC-failed flits / total flits received")
{
    // Formula stats: computed automatically from scalar accumulators
    payloadEfficiency  = totalPayloadBytes /
                         (totalPayloadBytes + totalPaddingBytes);
    retransmissionRate = totalRetransmissions / totalFlitsSent;
    crcErrorRate       = totalCrcErrors       / totalFlitsReceived;
}

// UcieLink Constructor 
// Maps Python parameters -> C++ sub-module configuraiton.
// (Python param names come from UcieLink.py processed by SCons)
UcieLink::UcieLink(const UcieLinkParams& p)
    : ClockedObject(p),
      txPort(name() + ".tx_port", this),
      rxPort(name() + ".rx_port", this),
      txPacker(p.flit_size),
      errorRate(p.error_rate),
      txBlocked(false),
      phyLinkState(PhyLinkState::RESET),
      currentLinkState(AdapterLinkState::RESET),
      flushTimerCycles(p.flush_timer_cycles),
      flushEventPending(false),
      flushEvent([this]{ processFlushEvent(); }, name() + ".flushEvent"),
      stats(this)
{
    // D2D Adapter configuration
    d2dAdapter.retryBufferCapacity  = p.retry_buffer_capacity;
    d2dAdapter.lastAckedSeqNum      = 0;
    d2dAdapter.rxBufferMaxDepth     = p.rx_buffer_depth;
    d2dAdapter.localChipletID       = static_cast<uint8_t>(p.local_chiplet_id);
    d2dAdapter.remoteChipletID      = static_cast<uint8_t>(p.remote_chiplet_id);

    // Logical PHY configuration
    logicalPhy.linkWidth    = p.link_width;
    logicalPhy.dataRateGbps = p.data_rate_gbps;
    logicalPhy.linkLatency  = p.link_latency;

    // Effective bandwidth = (lanes × Gbps) / 8 bits-per-byte
    // Expressed as bytes per Tick (Tick = picoseconds in gem5 by default)
    // dataRateGbps × 1e9 bits/s → bytes/s ÷ 1e12 ticks/s = bytes/tick × 1e3
    logicalPhy.effectiveBandwidthBytesPerTick =
        (logicalPhy.linkWidth * logicalPhy.dataRateGbps * 1e9)
        / (8.0 * 1e12);

    warn("[UCIe Link] Constructed. "
         "localID=%u remoteID=%u linkWidth=x%d dataRate=%.1fGbps "
         "latency=%lu ticks flitSize=%uB payloadLimit=%uB "
         "retryBufCap=%u errorRate=%.2e flushTimer=%lu cycles.",
         d2dAdapter.localChipletID,
         d2dAdapter.remoteChipletID,
         logicalPhy.linkWidth,
         logicalPhy.dataRateGbps,
         logicalPhy.linkLatency,
         p.flit_size,
         UCIE_PAYLOAD_SIZE_BYTES,
         d2dAdapter.retryBufferCapacity,
         errorRate,
         flushTimerCycles);
}

// getPort - wires Python-named ports to C++ port objects
Port& UcieLink::getPort(const std::string& if_name, PortID idx)
{
    if (if_name == "tx_port") return txPort;
    if (if_name == "rx_port") return rxPort;
    return ClockedObject::getPort(if_name, idx);
}

// init - pre-simulation sanity checks and link training kickoff
void UcieLink::init()
{
    ClockedObject::init();

    fatal_if(!txPort.isConnected(),
             "[UCIe Link] TX port '%s.tx_port' is not connected! "
             "Check your Python topology script.", name());
    fatal_if(!rxPort.isConnected(),
             "[UCIe Link] RX port '%s.rx_port' is not connected! "
             "Check your Python topology script.", name());

    warn("[UCIe Link] init() — ports verified connected.");
    warn("[UCIe Link] Running full Physical Layer training sequence ");

    // Physical Layer Training Sequence
    // Fast-forwarded at init time in behavioral model.
    // In a cycle-accurate model each would be a timed event.
    transitionPhyState(PhyLinkState::SBINIT);
    handleSbInit();

    transitionPhyState(PhyLinkState::MBINIT);
    handleMbInit();

    transitionPhyState(PhyLinkState::MBTRAIN);
    handleMbTrain();

    transitionPhyState(PhyLinkState::LINKINIT);
    handleLinkInit();

    transitionPhyState(PhyLinkState::ACTIVE);
    warn("[UCIe Link] Physical Layer ACTIVE.");

    // Adapter LSM initialization 
    // Can only enter ACTIVE after PhyLinkState == ACTIVE.
    transitionLinkState(AdapterLinkState::ACTIVE);

    warn("[UCIe Link] Adapter LSM ACTIVE. Link fully operational. "
         "localID=%u remoteID=%u x%d @ %.1f GT/s.",
         d2dAdapter.localChipletID, d2dAdapter.remoteChipletID,
         logicalPhy.linkWidth, logicalPhy.dataRateGbps);
}   

// ================================================================================
//  S6 STATE MACHINES
//
//  Two independent machines must be advanced in lockstep:
//      1. PhyLinkStage - Physical Layer (9 states)
//      2. AdapterLinkStage - Adapter LSM (8 states)
//
//  The spec mandates that PhyLinkState must reach a given level BEFORE
//  the AdapterLinkState can request the equivalent level.
// ================================================================================

// State name tables for warn() output
static const char* phyStateNames[] = {
    "RESET", "SBINIT", "MBINIT", "MBTRAIN",
    "LINKINIT", "ACTIVE", "L1", "L2", "PHYRETRAIN", "TRAINERROR"
};

static const char* adapterStateNames[] = {
    "RESET", "ACTIVE", "RETRAIN", "L1", "L2",
    "LINKERROR", "LINKRESET", "DISABLED"
};

// transitionPhyState - advance the Physical Layer training FSM
void UcieLink::transitionPhyState(PhyLinkState newState)
{
    uint8_t oldIdx = static_cast<uint8_t>(phyLinkState);
    uint8_t newIdx = static_cast<uint8_t>(newState);

    warn("[UCIe PHY State] %s → %s (tick=%lu).",
         phyStateNames[oldIdx], phyStateNames[newIdx], curTick());

    phyLinkState = newState;
}

// transitionLinkState - advance the Adapter LSM
// Enforces: PhyLinkState must be ACTIVE before AdapterLinkState -> ACTIVE
void UcieLink::transitionLinkState(AdapterLinkState newState)
{
    // RDI SM (Physical Layer) must be in Active before Adapter LSM
    if (newState == AdapterLinkState::ACTIVE &&
        phyLinkState != PhyLinkState::ACTIVE) {
        warn("[UCIe Adapter State] BLOCKED: Cannot enter ACTIVE — "
             "Physical Layer is in %s (must be ACTIVE first).",
             phyStateNames[static_cast<uint8_t>(phyLinkState)]);
        return;
    }

    uint8_t oldIdx = static_cast<uint8_t>(currentLinkState);
    uint8_t newIdx = static_cast<uint8_t>(newState);

    warn("[UCIe Adapter State] %s → %s (tick=%lu).",
         adapterStateNames[oldIdx], adapterStateNames[newIdx], curTick());

    currentLinkState = newState;
}

// handleSbInit - SBINIT: Sideband initialization 
// Behavioral model: detect sideband, exchange {SBINIT Out of Reset} and
// {SBINIT done req/resp} messages. Here simulated as an instant pass
void UcieLink::handleSbInit()
{
    warn("[UCIe PHY] SBINIT: Sideband detection and out-of-reset "
         "message exchange complete (800 MT/s).");
}

// handleMbInit - MBINIT: Mainband init at 4 GT/s 
// Credit pools are initialized here - first time the D2D Adapter is
// active and can negotiate initial credit values.
void UcieLink::handleMbInit()
{
    d2dAdapter.creditManager.reset();
    warn("[UCIe PHY] MBINIT: Mainband initialized at 4 GT/s. "
         "On-die calibration complete. Credit pools initialized.");
}

// handleMbTrain - MBTRAIN: Speed ramp + clock centering 
void UcieLink::handleMbTrain()
{
    warn("[UCIe PHY] MBTRAIN: Mainband speed raised to %.1f GT/s. "
         "x%d lanes. Clock centering vs data complete. "
         "Effective BW = %.3f GB/s.",
         logicalPhy.dataRateGbps,
         logicalPhy.linkWidth,
         logicalPhy.linkWidth * logicalPhy.dataRateGbps / 8.0);
}

// handleLinkInit - LINKINIT: Adapter & protocol parameter exchange
// This is the state where UCIe Flit Mode vs Raw Mode, protocol type
// (PCIe/CXL/Streaming), and credit initial values are negotiated.
void UcieLink::handleLinkInit()
{
    warn("[UCIe PHY] LINKINIT: Adapter capabilities and link management "
         "messages exchanged. Protocol negotiation complete. "
         "localChiplet=%u remoteChiplet=%u.",
         d2dAdapter.localChipletID, d2dAdapter.remoteChipletID);
}

// triggerPhyRetrain - Runtime physical retrain 
// Spec: "Used to begin the retrain flow for the Link during runtime."
// After physical retrain, link re-enters ACTIVE via MBTRAIN -> LINKINIT.
void UcieLink::triggerPhyRetrain()
{
    warn("[UCIe PHY] PHYRETRAIN triggered. "
         "CRC errors=%lu NAKs=%lu. Flushing TX queue (%zu flits).",
         (unsigned long)stats.totalCrcErrors.value(),
         (unsigned long)stats.totalFlitsNaked.value(),
         txSendQueue.size());

    transitionPhyState(PhyLinkState::PHYRETRAIN);

    // Drain send queue — flits retransmitted from retry buffer after retrain
    while (!txSendQueue.empty()) {
        delete txSendQueue.front();
        txSendQueue.pop_front();
    }

    // Re-run MBTRAIN → LINKINIT → ACTIVE
    transitionPhyState(PhyLinkState::MBTRAIN);
    handleMbTrain();
    transitionPhyState(PhyLinkState::LINKINIT);
    handleLinkInit();
    transitionPhyState(PhyLinkState::ACTIVE);

    warn("[UCIe PHY] Physical link back to ACTIVE after PHYRETRAIN.");
}

// triggerRetrain - Adapter LSM RETRAIN
// Spec: "RDI SM must be in Retrain BEFORE propagating Retrain to Adapter LSMs."
// Spec: "All Adapter LSMs in Active must propagate Retrain."
void UcieLink::triggerRetrain()
{
    warn("[UCIe Adapter] Adapter RETRAIN requested. "
         "Triggering Physical PHYRETRAIN first (spec §3.4 requirement).");

    // Step 1: Physical Layer must enter PHYRETRAIN first
    triggerPhyRetrain();

    // Step 2: Now Adapter LSM can enter RETRAIN
    transitionLinkState(AdapterLinkState::RETRAIN);

    warn("[UCIe Adapter] Adapter in RETRAIN. "
         "Retransmitting from oldest un-ACKed flit in retry buffer.");

    // Step 3: Retransmit from oldest un-ACKed flit
    if (!d2dAdapter.txRetryBuffer.empty()) {
        processNak(d2dAdapter.txRetryBuffer.front()->sequenceNumber);
    }

    // Step 4: Return Adapter LSM to ACTIVE after retrain completes
    transitionLinkState(AdapterLinkState::ACTIVE);
}

// triggerLinkError - LINKERROR 
// Spec: "LinkError transition takes priority over LinkReset or Disabled."
// Spec: "RDI SM must be in LinkError before Adapter LSM can transition."
void UcieLink::triggerLinkError()
{
    warn("[UCIe Adapter] LINKERROR triggered! "
         "This overrides any pending LinkReset or Disabled transitions. "
         "CRC errors=%lu NAKs=%lu.",
         (unsigned long)stats.totalCrcErrors.value(),
         (unsigned long)stats.totalFlitsNaked.value());

    transitionPhyState(PhyLinkState::TRAINERROR);
    transitionLinkState(AdapterLinkState::LINKERROR);
}

// triggerLinkReset — LINKRESET
// Spec: "Adapter LSM negotiates LinkReset via sideband with remote partner."
// Spec: "Disabled takes priority over LinkReset."

void UcieLink::triggerLinkReset()
{
    // Guard: LinkError takes priority (spec §3.4)
    if (currentLinkState == AdapterLinkState::LINKERROR) {
        warn("[UCIe Adapter] LinkReset IGNORED — LINKERROR has priority.");
        return;
    }

    warn("[UCIe Adapter] LINKRESET: Hot reset initiated via sideband. "
         "Negotiating with remote chiplet %u.",
         d2dAdapter.remoteChipletID);

    transitionLinkState(AdapterLinkState::LINKRESET);
    // After sideband negotiation completes (behavioral: immediate), go to RESET
    transitionLinkState(AdapterLinkState::RESET);
    transitionPhyState(PhyLinkState::RESET);

}

// enterPowerManagement — L1 or L2 PM state 
// Spec: "All Adapter LSMs must be in PM before RDI SM is transitioned to PM."
// Behavioral model: directly gates flit transmission.
void UcieLink::enterPowerManagement(bool deepSleep)
{
    AdapterLinkState pmState = deepSleep
                               ? AdapterLinkState::L2
                               : AdapterLinkState::L1;
    PhyLinkState phyPmState  = deepSleep
                               ? PhyLinkState::L2
                               : PhyLinkState::L1;

    warn("[UCIe PM] Entering %s. TX blocked. "
         "Sideband remains active for PM exit signaling.",
         deepSleep ? "L2 (deep sleep)" : "L1 (low power)");

    transitionLinkState(pmState);
    transitionPhyState(phyPmState);
    txBlocked = true;
}

//  exitPowerManagement — Return to ACTIVE from L1 or L2
//  Spec: "Once physical Link is retrained, RDI is in Active, then
//  Adapter LSM PM exit triggered from both sides via sideband."
void UcieLink::exitPowerManagement()
{
    warn("[UCIe PM] PM exit triggered. Running PHYRETRAIN to restore link.");

    // Physical Layer must retrain back to ACTIVE
    triggerPhyRetrain();

    // Then Adapter LSM returns to ACTIVE
    transitionLinkState(AdapterLinkState::ACTIVE);

    txBlocked = false;

    warn("[UCIe PM] PM exit complete. Link ACTIVE. Draining TX queue.");
    drainTxSendQueue();
}

// ================================================================================
//  S7 TX PIPELINE
// ================================================================================

//  transmitFlit
//  1. Generates CRC fr the flit 
//  2. Optionally injects a simulated bit error (test harness)
//  3. Checks credit availability
//  4. Pushes flit into txSendQueue and triggers drainTxSendQueue()
//  5. Updates statistics
//  6. Stores flit in txRetryBuffer (for potential NAK retransmission)
void UcieLink::transmitFlit(UcieFlitPacket* flit)
{
    assert(flit != nullptr);
    assert(currentLinkState == AdapterLinkState::ACTIVE);

    // CRC generation 
    UcieCRC::generateFlitCRC(flit);

    // Simulated bit error injection
    // A random float in [0, 1) is compared to errorRate. If less, the flit's
    // CRC is corrupted to simulate a physical transmission error.
    if (errorRate > 0.0 && ((double)rand() / RAND_MAX) < errorRate) {
        flit->crcGroups[0] ^= 0xDEADBEEFu;  // Corrupt first CRC group
        warn("[UCIe TX] ERROR INJECTED on flit seq=%u (errorRate=%.2e). "
             "CRC group[0] corrupted → receiver will NAK.",
             flit->sequenceNumber, errorRate);
    }

    // Credit check 
    MessageClass cls = flit->header.msgClass;
    if (!d2dAdapter.creditManager.canSend(cls, flit->payloadBytes)) {
        warn("[UCIe TX] Credit stall! Flit seq=%u queued. "
             "Waiting for credit returns from remote chiplet.",
             flit->sequenceNumber);
        txBlocked = true;
        // Push to send queue; will be drained when credits are returned
        txSendQueue.push_back(flit);
        return;
    }

    // Consume credits
    d2dAdapter.creditManager.consumeCredits(cls, flit->payloadBytes);

    // Add to retry buffer BEFORE sending (in case NAK arrives)
    if(d2dAdapter.txRetryBuffer.size() >= d2dAdapter.retryBufferCapacity) {
        warn("[UCIe TX] WARNING: Retry buffer full (%zu/%u). "
             "Back-pressure — flit seq=%u queued.",
             d2dAdapter.txRetryBuffer.size(),
             d2dAdapter.retryBufferCapacity,
             flit->sequenceNumber);
        txSendQueue.push_back(flit);
        return;
    }
    d2dAdapter.txRetryBuffer.push_back(flit);

    // Update statistics
    stats.totalFlitsSent++;
    stats.totalTLPsSent     += flit->originalPackets.size();
    stats.totalPayloadBytes += flit->payloadBytes;
    stats.totalPaddingBytes += flit->paddingBytes;

    if (flit->isRetransmission) {
        stats.totalRetransmissions++;
    }

    warn("[UCIe TX] Sending flit seq=%u → chiplet %u. "
         "TLPs=%zu payload=%uB padding=%uB retransmit=%s. "
         "RetryBuf=%zu/%u.",
         flit->sequenceNumber,
         d2dAdapter.remoteChipletID,
         flit->originalPackets.size(),
         flit->payloadBytes,
         flit->paddingBytes,
         flit->isRetransmission ? "YES" : "NO",
         d2dAdapter.txRetryBuffer.size(),
         d2dAdapter.retryBufferCapacity);

    // Send across the wire (scheduled at linklatency in gem5 timing)
    bool sent = txPort.sendTimingReq(flit);
    if (!sent) {
        txBlocked = true;
        warn("[UCIe TX] txPort.sendTimingReq blocked (downstream busy). "
             "Flit seq=%u remains in retry buffer. Will retry on recvReqRetry.",
             flit->sequenceNumber);
    }
}

//  drainTxSendQueue - attempt to send all queued flits
void UcieLink::drainTxSendQueue()
{
    warn("[UCIe TX] drainTxSendQueue: %zu flits queued.", txSendQueue.size());
    
    while (!txSendQueue.empty()) {
        UcieFlitPacket* front = txSendQueue.front();

        // Re-check credits before each send attempt
        if (!d2dAdapter.creditManager.canSend(front->header.msgClass,front->payloadBytes)) {
            warn("[UCIe TX] drainTxSendQueue: Still credit-starved. Stopping.");
            break;
        }

        txSendQueue.pop_front();
        transmitFlit(front);    // This will send or re-queue if port is busy

        if (txBlocked) break;   // Port busy again, stop draining
    }
}

//  processFlushEvent - 8-cycle timer fires, flush partial staging buffer
void UcieLink::processFlushEvent()
{
    flushEventPending = false;

    warn("[UCIe Flush] Timer fired after %lu cycles. "
         "Staged bytes=%u.", flushTimerCycles, txPacker.stagedBytes());

    UcieFlitPacket* flit = txPacker.forceFlush();
    if(flit != nullptr) {
        transmitFlit(flit);
    }
}




} // namespace gem5