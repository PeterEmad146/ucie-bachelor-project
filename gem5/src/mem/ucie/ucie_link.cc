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
    warn("[UCIe Packer] Init. flitSize=%uB payloadLimit=%uB.",
         flitSize, maxPayloadSize);

}

Tick FlitPacker::assignTimestampSequence()
{
       // Returns the current simulation Tick
       // This is monotonically increasing and unique in gem5
       return curTick();
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

    Tick seq = assignTimestampSequence();

    UcieFlitPacket* flit = new UcieFlitPacket(
        flitReq, MemCmd::WriteReq, seq, FlitType::PROTOCOL
    );

    // Transfer TLPs from staging -> flit
    flit->originalPackets = stagingBuffer;
    flit->payloadBytes    = currentBytes;
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
      packTlpEvent([this]{ processPackTlp(); }, name() + ".packTlpEvent",
                    false, EventBase::Maximum_Pri),
      sendFlitEvent([this]{ processSendFlit(); }, name() + ".sendFlitEvent"),
      retryTimeoutEvent([this] { processRetryTimeout(); }, name() + ".retryTimeoutEvent"),
      retryTimeoutDelay(p.retry_timeout_delay),
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

    warn("[UCIe Link] Constructed. localID=%u remoteID=%u "
         "linkWidth=x%d dataRate=%.1fGbps latency=%lu ticks "
         "retryTimeout=%lu ticks flitSize=%uB payloadLimit=%uB "
         "retryBufCap=%u errorRate=%.2e.",
         d2dAdapter.localChipletID, d2dAdapter.remoteChipletID,
         logicalPhy.linkWidth, logicalPhy.dataRateGbps,
         logicalPhy.linkLatency, retryTimeoutDelay,
         p.flit_size, UCIE_PAYLOAD_SIZE_BYTES,
         d2dAdapter.retryBufferCapacity, errorRate);

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
    warn("[UCIe PHY] %s → %s (tick=%lu).",
         phyStateNames[static_cast<uint8_t>(phyLinkState)],
         phyStateNames[static_cast<uint8_t>(newState)],
         curTick());
    phyLinkState = newState;
}


// transitionLinkState - advance the Adapter LSM
// Enforces: PhyLinkState must be ACTIVE before AdapterLinkState -> ACTIVE
void UcieLink::transitionLinkState(AdapterLinkState newState)
{
    if (newState == AdapterLinkState::ACTIVE &&
        phyLinkState != PhyLinkState::ACTIVE) {
        warn("[UCIe Adapter] BLOCKED: cannot enter ACTIVE while PHY is in %s.",
             phyStateNames[static_cast<uint8_t>(phyLinkState)]);
        return;
    }
    warn("[UCIe Adapter] %s → %s (tick=%lu).",
         adapterStateNames[static_cast<uint8_t>(currentLinkState)],
         adapterStateNames[static_cast<uint8_t>(newState)],
         curTick());
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

// S7   TX PIPELINE

// Logic for Pack TLP: highest priority
void UcieLink::processPackTlp()
{
    warn("[UCIe Task] processPackTlp (MaxPri) fired at tick=%lu.", curTick());
    // Schedule sendFlit on next 8-cycle boundary if there is data to send
    if ((txPacker.hasData() || !txSendQueue.empty()) &&
        !sendFlitEvent.scheduled()) {
        schedule(sendFlitEvent, curTick() + clockPeriod() * 8);
        warn("[UCIe Task] sendFlitEvent scheduled at tick=%lu.",
             curTick() + clockPeriod() * 8);
    }
}


// Logic for Send Flit: 8-Cycle Aligned
void UcieLink::processSendFlit()
{
    warn("[UCIe Task] processSendFlit at tick=%lu. "
         "staged=%uB queuedFlits=%zu.",
         curTick(), txPacker.stagedBytes(), txSendQueue.size());

    // Flush partial staging buffer if present
    if (!txPacker.isStagingBufferEmpty()) {
        UcieFlitPacket* flit = txPacker.forceFlush();
        if (flit) {
            txSendQueue.push_back(flit);
            warn("[UCIe Task] Partial flit seq=%lu queued for send.",
                 flit->sequenceNumber);
        }
    }

    drainTxSendQueue();

    // Reschedule ONLY if there is more work – prevents idle simulation cycles
    if (!txSendQueue.empty() || !txPacker.isStagingBufferEmpty()) {
        schedule(sendFlitEvent, curTick() + clockPeriod() * 8);
        warn("[UCIe Task] sendFlitEvent rescheduled (still has data).");
    } else {
        warn("[UCIe Task] Link idle – sendFlitEvent NOT rescheduled. "
             "Simulation cycles saved per [REF-PAPER].");
    }
}

void UcieLink::processRetryTimeout()
{
    if (d2dAdapter.txRetryBuffer.empty()) {
        warn("[UCIe Retry] Timeout fired but retry buffer empty – ignoring.");
        return;
    }
    warn("[UCIe Retry] Timeout! Moving %zu flits back to send queue.",
         d2dAdapter.txRetryBuffer.size());

    // Move all un-ACKed flits back to send queue for one retry attempt
    while (!d2dAdapter.txRetryBuffer.empty()) {
        UcieFlitPacket* f = d2dAdapter.txRetryBuffer.front();
        f->isRetransmission = true;
        txSendQueue.push_back(f);
        d2dAdapter.txRetryBuffer.pop_front();
    }

    // Wake up sender if idle
    if (!txBlocked && !sendFlitEvent.scheduled()) {
        schedule(sendFlitEvent, curTick());
    }
}

void UcieLink::transmitFlit(UcieFlitPacket* flit)
{
    assert(flit != nullptr);
    assert(currentLinkState == AdapterLinkState::ACTIVE);

    UcieCRC::generateFlitCRC(flit);

    // Simulated bit-error injection
    if (errorRate > 0.0 && ((double)rand() / RAND_MAX) < errorRate) {
        flit->crcGroups[0] ^= 0xDEADBEEFu;
        warn("[UCIe TX] ERROR INJECTED on flit seq=%lu (rate=%.2e).",
             flit->sequenceNumber, errorRate);
    }

    MessageClass cls = flit->header.msgClass;
    if (!d2dAdapter.creditManager.canSend(cls, flit->payloadBytes)) {
        warn("[UCIe TX] Credit stall – flit seq=%lu queued.",
             flit->sequenceNumber);
        txBlocked = true;
        txSendQueue.push_back(flit);
        return;
    }
    d2dAdapter.creditManager.consumeCredits(cls, flit->payloadBytes);

    if (d2dAdapter.txRetryBuffer.size() >= d2dAdapter.retryBufferCapacity) {
        warn("[UCIe TX] Retry buffer full (%zu/%u). Back-pressure flit seq=%lu.",
             d2dAdapter.txRetryBuffer.size(),
             d2dAdapter.retryBufferCapacity, flit->sequenceNumber);
        txSendQueue.push_back(flit);
        return;
    }
    d2dAdapter.txRetryBuffer.push_back(flit);
    // Start retry timeout if not already running
    if (!retryTimeoutEvent.scheduled()) {
        schedule(retryTimeoutEvent, curTick() + retryTimeoutDelay);
        warn("[UCIe TX] Retry timeout scheduled at tick=%lu.",
             curTick() + retryTimeoutDelay);
    }

    stats.totalFlitsSent++;
    stats.totalTLPsSent     += flit->originalPackets.size();
    stats.totalPayloadBytes += flit->payloadBytes;
    stats.totalPaddingBytes += flit->paddingBytes;
    if (flit->isRetransmission) stats.totalRetransmissions++;

    warn("[UCIe TX] Sending flit seq=%lu → chiplet %u. "
         "TLPs=%zu payload=%uB padding=%uB retx=%s retryBuf=%zu/%u.",
         flit->sequenceNumber, d2dAdapter.remoteChipletID,
         flit->originalPackets.size(), flit->payloadBytes, flit->paddingBytes,
         flit->isRetransmission ? "YES" : "NO",
         d2dAdapter.txRetryBuffer.size(), d2dAdapter.retryBufferCapacity);

    bool sent = txPort.sendTimingReq(flit);
    if (!sent) {
        txBlocked = true;
        warn("[UCIe TX] sendTimingReq blocked. Will retry on recvReqRetry.");
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



// ================================================================================
//  S8      ACK/NAK PROCESSING
// ================================================================================

// processAck - retire all retry buffer entreis upt to and including ackedSeqNum
void UcieLink::processAck(Tick ackedTimestamp)
{
    size_t retired = 0;
    while (!d2dAdapter.txRetryBuffer.empty()) {
        UcieFlitPacket* front = d2dAdapter.txRetryBuffer.front();
        if (front->sequenceNumber > ackedTimestamp) break;
        warn("[UCIe ACK] Retiring flit seq=%lu.", front->sequenceNumber);
        d2dAdapter.txRetryBuffer.pop_front();
        delete front;
        ++retired;
    }

    d2dAdapter.lastAckedSeqNum = ackedTimestamp;

    // Cancel timeout if retry buffer is now empty
    if (d2dAdapter.txRetryBuffer.empty() && retryTimeoutEvent.scheduled()) {
        deschedule(retryTimeoutEvent);
        warn("[UCIe ACK] Retry buffer empty – timeout cancelled.");
    }

    warn("[UCIe ACK] ts=%lu processed. Retired %zu. RetryBuf=%zu.",
         ackedTimestamp, retired, d2dAdapter.txRetryBuffer.size());

    drainTxSendQueue();
}


// processNak - retransmit all flits from nakSeqNum onwards
void UcieLink::processNak(Tick nakTimestamp)
{
    stats.totalFlitsNaked++;
    warn("[UCIe NAK] NAK ts=%lu. Retransmitting from retry buf (%zu flits).",
         nakTimestamp, d2dAdapter.txRetryBuffer.size());

    bool found = false;
    for (UcieFlitPacket* flit : d2dAdapter.txRetryBuffer) {
        if (flit->sequenceNumber >= nakTimestamp) {
            found = true;
            flit->isRetransmission = true;
            warn("[UCIe NAK] Retransmitting flit seq=%lu.", flit->sequenceNumber);
            UcieCRC::generateFlitCRC(flit);
            bool sent = txPort.sendTimingReq(flit);
            if (!sent) {
                txBlocked = true;
                warn("[UCIe NAK] Retransmit blocked – will resume on retry.");
                break;
            }
        }
    }
    if (!found)
        warn("[UCIe NAK] ts=%lu not in retry buffer (already ACKed?).", nakTimestamp);
}


// sendAck - create and dispatch an ACK flit to the remote chiplet
// Piggybacks credit returns in the flit header
void UcieLink::sendAck(Tick ackedTimestamp)
{
    RequestPtr req = std::make_shared<Request>(0, UCIE_FLIT_SIZE_BYTES, 0, 0);
    UcieFlitPacket* ack = new UcieFlitPacket(
        req, MemCmd::WriteReq, ackedTimestamp, FlitType::FLIT_LEVEL_ACK);

    ack->header.flitType              = FlitType::FLIT_LEVEL_ACK;
    ack->header.ackNakValid           = true;
    ack->header.ackNakTimestamp       = ackedTimestamp;
    ack->header.srcID                 = d2dAdapter.localChipletID;
    ack->header.dstID                 = d2dAdapter.remoteChipletID;
    ack->header.headerCreditsReturned = 1;
    ack->header.dataCreditsReturned   = (UCIE_PAYLOAD_SIZE_BYTES + 3) / 4;
    ack->payloadBytes                 = 0;
    ack->paddingBytes                 = UCIE_PAYLOAD_SIZE_BYTES;
    ack->makeResponse();

    stats.totalAcksSent++;
    warn("[UCIe ACK] Sending ACK ts=%lu to chiplet %u. "
         "hdrCred=%u dataCred=%u.",
         ackedTimestamp, d2dAdapter.remoteChipletID,
         ack->header.headerCreditsReturned,
         ack->header.dataCreditsReturned);
    rxPort.sendTimingResp(ack);
}


// sendNak - create and dispatch a NAK flit requesting retransmission
void UcieLink::sendNak(Tick nakTimestamp)
{
    RequestPtr req = std::make_shared<Request>(0, UCIE_FLIT_SIZE_BYTES, 0, 0);
    UcieFlitPacket* nak = new UcieFlitPacket(
        req, MemCmd::WriteReq, nakTimestamp, FlitType::FLIT_LEVEL_NAK);

    nak->header.flitType        = FlitType::FLIT_LEVEL_NAK;
    nak->header.ackNakValid     = true;
    nak->header.ackNakTimestamp = nakTimestamp;
    nak->header.srcID           = d2dAdapter.localChipletID;
    nak->header.dstID           = d2dAdapter.remoteChipletID;
    nak->payloadBytes           = 0;
    nak->paddingBytes           = UCIE_PAYLOAD_SIZE_BYTES;
    nak->makeResponse();

    stats.totalNaksSent++;
    warn("[UCIe NAK] Sending NAK ts=%lu to chiplet %u.",
         nakTimestamp, d2dAdapter.remoteChipletID);
    rxPort.sendTimingResp(nak);
}


// ================================================================================
//  S9 TX PORT CALLBACKS
//  UcieTxPort connects to the REMOTE chiplet (or memory controller).
//  Responses arriving here are ACK/NAK flits from the receiver
// ================================================================================

UcieLink::UcieTxPort::UcieTxPort(const std::string& name, UcieLink* owner)
    : RequestPort(name), owner(owner) {}

// recvTimingResp - ACK/NAK from remote chiplet, OR read data from memory

bool UcieLink::UcieTxPort::recvTimingResp(PacketPtr pkt)
{
    UcieFlitPacket* ctrlFlit = dynamic_cast<UcieFlitPacket*>(pkt);
    if (ctrlFlit != nullptr) {
        if (ctrlFlit->header.flitType == FlitType::FLIT_LEVEL_ACK) {
            warn("[UCIe TX Port] ACK ts=%lu.", ctrlFlit->header.ackNakTimestamp);
            owner->d2dAdapter.creditManager.returnCredits(
                ctrlFlit->header.headerCreditsReturned,
                ctrlFlit->header.dataCreditsReturned,
                ctrlFlit->header.msgClass);
            owner->processAck(ctrlFlit->header.ackNakTimestamp);
        } else if (ctrlFlit->header.flitType == FlitType::FLIT_LEVEL_NAK) {
            warn("[UCIe TX Port] NAK ts=%lu.", ctrlFlit->header.ackNakTimestamp);
            owner->processNak(ctrlFlit->header.ackNakTimestamp);
        } else {
            warn("[UCIe TX Port] Unexpected flit type=%u in recvTimingResp.",
                 static_cast<uint8_t>(ctrlFlit->header.flitType));
        }
        delete ctrlFlit;
        return true;
    }
    warn("[UCIe TX Port] Memory read response (addr=0x%llx size=%uB).",
         (unsigned long long)pkt->getAddr(), pkt->getSize());
    return owner->rxPort.sendTimingResp(pkt);
}


// recvReqRetry - downstream became available; resume pending sends
void UcieLink::UcieTxPort::recvReqRetry()
{
    warn("[UCIe TX Port] recvReqRetry – downstream unblocked.");
    owner->txBlocked = false;

    while (!owner->d2dAdapter.rxBuffer.empty()) {
        PacketPtr front = owner->d2dAdapter.rxBuffer.front();
        if (!sendTimingReq(front)) {
            owner->txBlocked = true;
            return;
        }
        owner->d2dAdapter.rxBuffer.pop_front();
    }
    owner->drainTxSendQueue();
}


// recvRangeChange - propagate address range updates upstream
void UcieLink::UcieTxPort::recvRangeChange()
{
    warn("[UCIe TX Port] Address range change received — "
         "propagating to RX port.");
    owner->rxPort.sendRangeChange();
}

// ================================================================================
//  S10     RX PORT CALLBACKS
//  UcieRxPort connects t the LOCAL chiplet's CPU / cache / NoC.
//  Incoming requests here are either:
//      a) TLPs from the local protocol stack -> pack into flit -> send
//      b) Received UCIe flits from the remote -> unpack -> forward to memory
// ================================================================================
UcieLink::UcieRxPort::UcieRxPort(const std::string& name, UcieLink* owner)
    : ResponsePort(name), owner(owner) {}

// recvAtomic - backdoor zero-latency access (functional/ atomic CPU mode)
Tick UcieLink::UcieRxPort::recvAtomic(PacketPtr pkt)
{
    return owner->txPort.sendAtomic(pkt) + owner->logicalPhy.linkLatency;
}


// recvFunctional - backdoor direct memory write (debugging)
void UcieLink::UcieRxPort::recvFunctional(PacketPtr pkt)
{
    owner->txPort.sendFunctional(pkt);
}

// recvTimingReq - MAIN DATA PATH
//
// Two roles depending on what arrives:
// 
// ROLE A - SENDER (local CPU/cache sends a TLP to the remote chiplet):
//      Incoming packet is a standard gem5 packet (not UcieFlitPacket).
//      -> Hand to FlitPacker -> if flit assembled -> transmitFlit()
//      -> Schedule 8-cycle flush timer if staging buffer has partial data
//
// ROLE B - RECEIVER (remote chiplet sent us a packed UCIe flit):
//      Incoming packet is a UcieFlitPacket (dynamic_cast suceeds).
//      -> Verify CRC -> ACK or NAK -> unpack TLPs -> forward memory
bool UcieLink::UcieRxPort::recvTimingReq(PacketPtr pkt)
{
    UcieFlitPacket* incomingFlit = dynamic_cast<UcieFlitPacket*>(pkt);

    // ---- ROLE B: received UCIe flit from remote chiplet ----
    if (incomingFlit != nullptr) {
        owner->stats.totalFlitsReceived++;
        warn("[UCIe RX Port] RECEIVER: flit seq=%lu from chiplet %u "
             "type=%u payload=%uB.",
             incomingFlit->sequenceNumber,
             incomingFlit->header.srcID,
             static_cast<uint8_t>(incomingFlit->header.flitType),
             incomingFlit->payloadBytes);

        // LINK_MGMT: credit returns only
        if (incomingFlit->header.flitType == FlitType::LINK_MGMT) {
            owner->d2dAdapter.creditManager.returnCredits(
                incomingFlit->header.headerCreditsReturned,
                incomingFlit->header.dataCreditsReturned,
                incomingFlit->header.msgClass);
            delete incomingFlit;
            return true;
        }

        // CRC verification
        bool crcOk = UcieCRC::verifyFlitCRC(incomingFlit);
        if (!crcOk) {
            owner->stats.totalCrcErrors++;
            warn("[UCIe RX Port] CRC FAIL seq=%lu. Sending NAK. Total=%lu.",
                 incomingFlit->sequenceNumber,
                 (unsigned long)owner->stats.totalCrcErrors.value());
            owner->sendNak(incomingFlit->sequenceNumber);
            delete incomingFlit;
            return true;
        }
        // CRC OK: ACK and unpack
        warn("[UCIe RX Port] CRC PASS seq=%lu. Sending ACK.", incomingFlit->sequenceNumber);
        owner->sendAck(incomingFlit->sequenceNumber);

        std::vector<PacketPtr> tlps =
            owner->rxUnpacker.processReceivedFlit(incomingFlit);

        for (PacketPtr tlp : tlps) {
            if (owner->d2dAdapter.rxBuffer.size() >=
                owner->d2dAdapter.rxBufferMaxDepth) {
                warn("[UCIe RX Port] RX buffer full – BACK-PRESSURE.");
                break;
            }
            owner->d2dAdapter.rxBuffer.push_back(tlp);
        }

        size_t drained = 0;
        while (!owner->d2dAdapter.rxBuffer.empty()) {
            PacketPtr front = owner->d2dAdapter.rxBuffer.front();
            if (!owner->txPort.sendTimingReq(front)) break;
            owner->d2dAdapter.rxBuffer.pop_front();
            ++drained;
        }
        warn("[UCIe RX Port] Drained %zu TLPs. RX buf remaining=%zu.",
             drained, owner->d2dAdapter.rxBuffer.size());

        delete incomingFlit;
        return true;
    }

    // ---- ROLE A: TLP from local CPU/cache → pack and schedule send ----
    warn("[UCIe RX Port] SENDER: TLP addr=0x%llx size=%uB.",
         (unsigned long long)pkt->getAddr(), pkt->getSize());

    if (owner->currentLinkState != AdapterLinkState::ACTIVE) {
        warn("[UCIe RX Port] Adapter not ACTIVE (%s). Dropping TLP.",
             adapterStateNames[static_cast<uint8_t>(owner->currentLinkState)]);
        return false;
    }
    // Pack the TLP
    UcieFlitPacket* readyFlit = owner->txPacker.processIncomingTLP(pkt);
    if (readyFlit != nullptr) {
        owner->txSendQueue.push_back(readyFlit);
        warn("[UCIe RX Port] Flit seq=%lu queued for send.",
             readyFlit->sequenceNumber);
    }

    // [REF-PAPER] Schedule packTlpEvent at Maximum_Pri to trigger sendFlitEvent.
    // This ensures intake processing happens before other same-tick events.
    if (!owner->packTlpEvent.scheduled()) {
        owner->schedule(owner->packTlpEvent, curTick());
    }

    return true;
}

// recvRespRetry - upstream caller can retyr after we previously blocked
void UcieLink::UcieRxPort::recvRespRetry()
{
    owner->txPort.sendRetryResp();
}

// getAddrRanges - transparent pass-through to whatever TX port connects to 
AddrRangeList UcieLink::UcieRxPort::getAddrRanges() const
{
    return owner->txPort.getAddrRanges();
}


// ================================================================================
//  S12     DIAGNOSTICS
// ================================================================================
void UcieLink::dumpLinkStatus() const
{
    warn("=== UCIe Link Status [%s] ===", name().c_str());
    warn("  PHY State    : %s", phyStateNames[static_cast<uint8_t>(phyLinkState)]);
    warn("  Adapter State: %s", adapterStateNames[static_cast<uint8_t>(currentLinkState)]);

    if (currentLinkState == AdapterLinkState::ACTIVE &&
        phyLinkState     != PhyLinkState::ACTIVE) {
        warn("  *** SPEC VIOLATION: Adapter ACTIVE but PHY not ACTIVE! ***");
    }

    warn("  Local ID     : %u", d2dAdapter.localChipletID);
    warn("  Remote ID    : %u", d2dAdapter.remoteChipletID);
    warn("  Lane Width   : x%d @ %.1f GT/s", logicalPhy.linkWidth, logicalPhy.dataRateGbps);
    warn("  Link Latency : %lu ticks", logicalPhy.linkLatency);
    warn("  Eff BW       : %.3f GB/s",
         logicalPhy.linkWidth * logicalPhy.dataRateGbps / 8.0);
    warn("  TX Blocked   : %s", txBlocked ? "YES" : "NO");
    warn("  Retry Buffer : %zu / %u flits",
         d2dAdapter.txRetryBuffer.size(), d2dAdapter.retryBufferCapacity);
    warn("  Last ACK'd   : ts=%lu", d2dAdapter.lastAckedSeqNum);
    warn("  RX Buffer    : %zu / %u TLPs",
         d2dAdapter.rxBuffer.size(), d2dAdapter.rxBufferMaxDepth);
    warn("  TX SendQueue : %zu flits", txSendQueue.size());
    warn("  Staging      : %u / %u bytes",
         txPacker.stagedBytes(), UCIE_PAYLOAD_SIZE_BYTES);
    warn("  sendFlit     : %s", sendFlitEvent.scheduled() ? "SCHEDULED" : "IDLE");
    warn("  RetryTimeout : %s", retryTimeoutEvent.scheduled() ? "RUNNING" : "IDLE");

    const char* clsNames[] = { "NPR", "PR ", "CPL" };
    for (int c = 0; c < UcieCreditManager::NUM_MSG_CLASSES; ++c) {
        warn("  Credits[%s]  : txAvail=%u rxGranted=%u rxConsumed=%u",
             clsNames[c],
             d2dAdapter.creditManager.pools[c].txAvailable,
             d2dAdapter.creditManager.pools[c].rxGranted,
             d2dAdapter.creditManager.pools[c].rxConsumed);
    }

    warn("  Flits Sent   : %lu", (unsigned long)stats.totalFlitsSent.value());
    warn("  TLPs Sent    : %lu", (unsigned long)stats.totalTLPsSent.value());
    warn("  Payload B    : %lu", (unsigned long)stats.totalPayloadBytes.value());
    warn("  Padding B    : %lu", (unsigned long)stats.totalPaddingBytes.value());

    uint64_t totalB = stats.totalPayloadBytes.value() + stats.totalPaddingBytes.value();
    if (totalB > 0)
        warn("  Payload Eff  : %.2f%% (spec max=%.2f%%)",
             100.0 * stats.totalPayloadBytes.value() / totalB,
             100.0 * UCIE_PAYLOAD_SIZE_BYTES / UCIE_FLIT_SIZE_BYTES);
    else
        warn("  Payload Eff  : N/A");

    warn("  Retransmits  : %lu (%.4f%%)",
         (unsigned long)stats.totalRetransmissions.value(),
         stats.totalFlitsSent.value() > 0
             ? 100.0 * stats.totalRetransmissions.value() /
               stats.totalFlitsSent.value() : 0.0);
    warn("  NAKs Recv    : %lu", (unsigned long)stats.totalFlitsNaked.value());
    warn("  Flits Recv   : %lu", (unsigned long)stats.totalFlitsReceived.value());
    warn("  CRC Errors   : %lu (%.4f%%)",
         (unsigned long)stats.totalCrcErrors.value(),
         stats.totalFlitsReceived.value() > 0
             ? 100.0 * stats.totalCrcErrors.value() /
               stats.totalFlitsReceived.value() : 0.0);
    warn("  ACKs Sent    : %lu", (unsigned long)stats.totalAcksSent.value());
    warn("  NAKs Sent    : %lu", (unsigned long)stats.totalNaksSent.value());
    warn("=== End UCIe Link Status [%s] ===", name().c_str());
}


} // namespace gem5