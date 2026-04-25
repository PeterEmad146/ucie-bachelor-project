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
    # [REF-PAPER] Timeout before automatic single-retry retransmission.
    # Chosen large enough to cover typical ACK round-trip latency.
    retry_timeout = Param.Latency('25ns',
                                "Timeout before automatic retransmission")

    # [REF-PAPER] Bit error rate in the experiment was configured to 10^-10.
    error_rate    = Param.Float(1e-10,
                                "Per-flit CRC corruption probability (0=off)")