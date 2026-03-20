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
//  FLIT UNPACKER ENGINE (D2D Adapter RX path)
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



} // namespace gem5