from m5.params import *
from m5.objects.ClockedObject import ClockedObject

class UcieLink(ClockedObject):
    type = 'UcieLink'
    cxx_header = "ucie/ucie_link.hh"
    cxx_class = "gem5::UcieLink"

    # Bidirectional Ports
    tx_port = RequestPort("Transmit port to the adjacent chiplet")
    rx_port = ResponsePort("Receive port from the adjacent chiplet")

    # Parameters strictly matching the paper's configuration
    link_latency = Param.Latency('2ns', "Physical Link Latency")
    retry_buffer_capacity = Param.MemorySize('32kB', "Adapter Buffer Size")
    flit_size = Param.Int(256, "UCIe Flit Size in Bytes")
    link_width = Param.Int(16, "Link Width in Lanes")
    data_rate = Param.String('16GT/s', "Data Rate per pin")