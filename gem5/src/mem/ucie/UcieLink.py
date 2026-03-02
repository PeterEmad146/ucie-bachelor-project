# Import the core parameter types (Latency, MemorySize, Int, etc.)
from m5.params import *
# Import ClockedObject, which gives our hardware a clock domain and power state
from m5.objects.ClockedObject import ClockedObject

class UcieLink(ClockedObject):
    # The name of this SimObject in the gem5 ecosystem
    type = 'UcieLink'

    # Tells the Python interpreter exactly where to find the C++ class
    # that implements the actual behavior for this hardware.
    cxx_header = "mem/ucie/ucie_link.hh"
    cxx_class = "gem5::UcieLink"

    # ==========================================================        
    # HARDWARE PORTS
    # ==========================================================
    # RequestPort acts as the "Master" interface (sends requests out)
    tx_port = RequestPort("Transmit port to the adjacent chiplet")
    # ResponsePort acts as the "Slave" interface (receives requests in)
    rx_port = ResponsePort("Receive port from the adjacent chiplet")

    # ==========================================================
    # HARDWARE PARAMTERS (Knobs for the simulation script)
    # ==========================================================
    # These match the exact specifications from the referece paper.
    # When gem5 copmiles, it creates a C++ variable for each of these.
    link_latency = Param.Latency('2ns', "Physical Link Latency")
    retry_buffer_capacity = Param.MemorySize('32kB', "Adapter Buffer Size")
    flit_size = Param.Int(256, "UCIe Flit Size in Bytes")
    link_width = Param.Int(16, "Link Width in Lanes")
    data_rate = Param.String('16GT/s', "Data Rate per pin")