from m5.params import *
from m5.objects.ClockedObject import ClockedObject

class UcieLink(ClockedObject):
    type = 'UcieLink'
    cxx_header = "mem/ucie/ucie_link.hh"
    cxx_class  = "gem5::UcieLink"

    # ── Ports ──────────────────────────────────────────────────────────────
    tx_port = RequestPort("Transmit port to the adjacent chiplet")
    rx_port = ResponsePort("Receive port from the local protocol stack")

    # ── Reliability ────────────────────────────────────────────────────────
    # [REF-PAPER] Timeout before automatic retransmission probe.
    retry_timeout = Param.Latency('25ns', "Timeout before retransmission")

    # [REF-PAPER §IV] BER = 10^-10. Deterministic: 1 error per 1/BER bits.
    error_rate    = Param.Float(1e-10,  "Bit error rate (0 = disabled)")

    # ── Physical layer ─────────────────────────────────────────────────────
    # [REF-PAPER §III-A] Standard UCIe: 4/8/16/32 GT/s per lane.
    data_rate     = Param.Float(4.0,   "Data rate per lane in GT/s")

    # [REF-PAPER §III-A] Standard package = 16 lanes, Advanced = 64 lanes.
    num_lanes     = Param.Int(16,      "Number of mainband data lanes")

    # [REF-PAPER §III-B] 1 ns Adapter+LogPHY + 1 ns Electrical PHY = 2 ns.
    # Independent of the data-path clock frequency.
    phys_delay    = Param.Latency('2ns', "Fixed physical layer delay")

    # ── Flow control ───────────────────────────────────────────────────────
    credit_pool   = Param.Int(32,      "Flow-control credits advertised to peer")