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



} // namespace gem5