// ================================================================================
//  UcieLink.hh - UCIe Die-to-Die link Model for gem5
// 
//  Sepecification References:
//      [UCIe-SPEC] Universal Chiplet Interconnect Express (UCIe) Specification
//                  Version 1.1, 2023
//      [REF-PAPER] "Efficient Die-to-Die Communication: UCIe Link Simulation
//                   and Optimization in a Chiplet-Based System"
//      [GEM5]      "The gem5 Simulator: Version 20.0" - gem5.org
// 
//  Architecture Modelled (UCIe stack, top-down):
//  --> Protocol Layer:             PCIe / CXL / Streaming TLPs
//  --> Die-to-Die (D2D) Adapter:   Flit packing, CRC, ACK/NAK, credit-based flow
//                                  control
//  --> Logical PHY:                Lane width, data-rate, encoding
//  --> Physical PHY:               (out of scope of behavioral model)
//
//  Key UCIe Flit Parameters:
//      * Flit Size         : 256 bytes (fixed, spec-mandated)
//      * Flit header       :   8 bytes 
//      * CRC field         :  23 bytes (CRC-32 per 64B CRC group)
//      * Usable payload    : 236 bytes (256 - 8 - 12)
//      * Max data rate     :  32 GT/s per lane (Advanced package)
//      * Link widths       :  x2, x4, x8, x16 (Standard) / x64 (Advanced)
//      * Flow control      :  Credit-based (header credits + data credits)
//      * Error recover     :  Flit-level Retry (FLR) with ACK/NAK protocol
//
// ================================================================================

#ifndef __UCIE_UCIE_LINK_HH__
#define __UCIE_UCIE_LINK_HH__

//  gem5 core headers
#include "params/UcieLink.hh"       // Auto-generated from UcieLink.py (SCons)
#include "sim/clocked_object.hh"    // Base class: tick-accurate clocked model
#include "mem/port.hh"              // RequestPort / ResponsePort abstractions
#include "mem/packet.hh"            // gem5 Packet (base for UcieFlitPacket)
#include "base/statistics.hh"       // gem5 statistics framework

//  STL
#include <deque>
#include <vector>
#include <cstdint>
#include <array>
#include <string>

namespace gem5
{

// ================================================================================
//  SECTION 1 - UCIe ENUMERATED TYPES
//  These mirror the state machines and message classifications defined in 
//  UCIe Spec (Link Training) and (Die-to-Die Adapter).
// ================================================================================

//  1.1     Physical Layer Link Training State Machine
//  
//  The Physical Layer follows this exact 9-state sequence from spec Table 22.
//  Every state except RESET and TRAINERROR has an 8ms residency timeout;
//  expiry causes a transition to TRAINERROR --> RESET.
//
//  State descriptions (verbatim from spec Table 22):
//      RESET       - Following primary reset or exit from TRAINERROR.
//                    Must remain here >= 4ms to allow PLLs to stabilize.
//      SBINIT      - Sideband interface detected, repaired (Advanced Package),
//                    and out-of-reset message transmitted at 800 MT/s.
//      MBINIT      - Mainband initialized at lowest speed (4 GT/s). On-die
//                    calibration + interconnect repair (Advanced Package).
//      MBTRAIN     - Mainband speed raised to highest negotiated data rate.
//                    Die-to-die clock centering vs data lanes performed.
//      LINKINIT    - Adapter and Link management messages exchanged.
//                    Protocol parameter negotiation completes here.
//      ACTIVE      - Transactions are sent and received. Normal operation.
//      L1          - Power Management low-power state. Mandatory for PCIe/CXL.
//      L2          - Power Management deep-sleep state. Mandatory for PCIe/CXL.
//      PHYRETRAIN  - Initiates the runtime retrain flow for the physical link.
//                    Distinct from Adapter-layer RETRAIN.
//      TRAINERROR  - Fatal or non-fatal event during training or operation 
//                    Link must exit to RESET from here.
enum class PhyLinkState : uint8_t
{
    RESET       = 0,    // Post-reset; PLLs stabilizing (min 4ms)
    SBINIT      = 1,    // Sideband initialization at 800 MT/s
    MBINIT      = 2,    // Mainband init at 4 GT/s; lane repair
    MBTRAIN     = 3,    // Mainband speed ramp to max negotiated rate
    LINKINIT    = 4,    // Adapter & link management message exchange
    ACTIVE      = 5,    // Normal operation - flits flowing
    L1          = 6,    // PM L1 low-power state 
    L2          = 7,    // PM L2 deep-sleep state 
    PHYRETRAIN  = 8,    // Runtime physical retrain initiation
    TRAINERROR  = 9     // Fatal/non-fatal training error -> must exit to RESET
};

//  1.2     Die-to-Die Adapter Link State Machine (LSM)
//
//  The Adapter LSM sits ABOVE the Physica Layer and has its own separate
//  set of states. State transitions in the Adapter LSM are strictly gated
//  by the RDI SM (which abstracts Physical Layer state to upper layers).
//  
//  Spec-mandated dependency ordering:
//      1.  RDI SM must reach target state BEFORE Adapter LSM requests it.
//      2.  Adapter LSM must reach target state BEFORE Protocol vLSM requests it.
//
//  Priority ordering for error/reset states:
//      LinkError > Disabled > LinkReset
//
//  State descriptions:
//      RESET       - Adapater reset; coordinates with Physical Layer RESET.
//      ACTIVE      - Normal operation; requires RDI SM to be ACTIVE first.
//      RETRAIN     - Adapter retrain; RDI SM must enter RETRAIN first.
//                    All Adapter LSMs in ACTIVE must propagate RETRAIN.
//      L1          - Adapter PM L1; all vLSMs must be in PM first.
//      L2          - Adapter PM L2; all vLSMs must be in PM first.
//      LINKERROR   - Fatal link error; propagated from RDT SM.
//                    Highest priority: overrides LinkReset and Disabled.
//      LINKRESET   - Hot reset negotiated via sideband with remote partner.
//      DISABLED    - Administratively disabled; takes priority over LinkReset.
enum class AdapterLinkState : uint8_t
{
    RESET       = 0,    // Adapter in reset
    ACTIVE      = 1,    // Normal flit transfer operation
    RETRAIN     = 2,    // Adapter-layer retrain (gated by RDI SM retrain)
    L1          = 3,    // PM L1 
    L2          = 4,    // PM L2
    LINKERROR   = 5,    // Fatal error propagated from RDI SM (highest priority)
    LINKRESET   = 6,    // Hot reset - negotiated via sideband
    DISABLED    = 7     // Disabled - priority over LinkReset, below LinkError
};

//  Convenience alias - the state machine most of the link logic uses
//  is the Adapter LSM (sits at D2D layer, directly above PHY abstraction)
using LinkState = AdapterLinkState;

//  1.3     Flit Type 
//  
//  UCIe defines distinct flit categories carrying different header encodings
//  and used for different purposes within the link protocol.
enum class FlitType : uint8_t
{
    PROTOCOL        = 0,    // Carries PCIe / CXL / Streaming TLP payload data
    FLIT_LEVEL_ACK  = 1,    // Acknowledgement: receiver consumed N flits cleanly
    FLIT_LEVEL_NAK  = 2,    // Negative-ACK: requests retransmission from seq N
    LINK_MGMT       = 3,    // Link management: credit returns, PM state requests
    NULL_FLIT       = 4     // IDLE / training flit - no protocol payload
};

//  1.4     Protocol Stack Identifier
//
//  The D2D Adapter must tag each flit with the source protocol so the
//  receiving adapter can route to the correct protocol stack.
enum class ProtocolType : uint8_t
{
    PCIE        = 0,    // PCI Express TLP/DLLP payload
    CXL_IO      = 1,    // Compute Express Link - CXL.io (PCIe-compatible)
    CXL_MEM     = 2,    // Compute Express Link - CXL.mem (memory expansion)
    CXL_CACHE   = 3,    // Compute Express Link - CXL.cache (coherent cache)
    STREAMING   = 4,    // Raw streaming protocol (vendor-defined)
    UNDEFINED   = 0xFF
};

//  1.5     Message Class 
//
//  Within PROTOCOL flits, message class determines QoS priority and 
//  virtual channel mapping.
enum class MessageClass : uint8_t
{
    NPR     = 0,    // Non-Posted Request
    PR      = 1,    // Posted Request (e.g. memory write)
    CPL     = 2,    // Completion (read return / write status)
    RSVD    = 3     // Reserved for future extension
};

}


#endif