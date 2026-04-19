# Import the core parameter types (Latency, MemorySize, Int, etc.)
from m5.params import *
# Import ClockedObject, which gives our hardware a clock domain and power state
from m5.objects.ClockedObject import ClockedObject

class UcieLink(ClockedObject):
    # The name of this SimObject in the gem5 ecosystem
    type = 'UcieLink'

    # Tells the Python interpreter exactly where to find the C++ class
    cxx_header = "mem/ucie/ucie_link.hh"
    cxx_class  = "gem5::UcieLink"

    # ==========================================================
    # HARDWARE PORTS
    # ==========================================================
    # RequestPort – sends flits out to the adjacent chiplet
    tx_port = RequestPort("Transmit port to the adjacent chiplet")
    # ResponsePort – receives TLPs from the local chiplet's protocol stack
    rx_port = ResponsePort("Receive port from the adjacent chiplet")

    # ==========================================================
    # HARDWARE PARAMETERS
    # ==========================================================
    link_latency          = Param.Latency('2ns',
                                "Point-to-point propagation delay")

    # [REF-PAPER] Timeout before automatic single-retry retransmission.
    # Chosen large enough to cover typical ACK round-trip latency.
    retry_timeout_delay   = Param.Latency('100ns',
                                "Timeout before automatic retransmission")

    # Number of flits held in the retry buffer pending ACK (count, not bytes)
    retry_buffer_capacity = Param.Unsigned(128,
                                "Retry buffer capacity in flits")

    flit_size             = Param.Int(256,
                                "UCIe flit size in bytes (spec-mandated 256)")

    link_width            = Param.Int(16,
                                "Link width in lanes")

    data_rate             = Param.String('16GT/s',
                                "Negotiated data rate string (informational)")

    # Bit-error rate injected per flit for testing. 0.0 = error-free.
    error_rate            = Param.Float(0.0,
                                "Per-flit CRC corruption probability (0=off)")

    data_rate_gbps        = Param.Float(32.0,
                                "Per-lane data rate in Gbps")

    rx_buffer_depth       = Param.Unsigned(64,
                                "Max TLPs in the RX buffer")

    local_chiplet_id      = Param.Unsigned(0,
                                "This chiplet's identifier")

    remote_chiplet_id     = Param.Unsigned(1,
                                "Remote chiplet's identifier")