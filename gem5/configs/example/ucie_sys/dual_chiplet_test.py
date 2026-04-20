import m5
from m5.objects import *
import argparse
import os

# 1. Parse command-line arguments for TLP size
parser = argparse.ArgumentParser(description="UCIe Dual-Chiplet Latency Test")
parser.add_argument("--tlp_size", type=int, default=32, help="Size of the TLP in bytes")
parser.add_argument("--iterations", type=int, default=1000000, help="Number of packets to send")
args = parser.parse_args()

# The paper states TLP size includes a 16B header[cite: 157]. 
# TrafficGen payload size is (TLP size - 16).
payload_size = args.tlp_size - 16

# 2. Setup the System
system = System()
system.cache_line_size = 4096  # <--- ADD THIS LINE
system.clk_domain = SrcClockDomain(clock='1GHz', voltage_domain=VoltageDomain())
system.mem_mode = 'timing'

# 3. Create the Pkt Sender (Chiplet 1) 
system.traffic_gen = TrafficGen()

# 4. Create the UCIe Link (Configured for 64GT/s and 2ns delay) [cite: 134, 137]
system.ucie_link = UcieLink(
    link_latency='2ns',
    data_rate='64GT/s',
    data_rate_gbps=64.0,
    flit_size=256,
    link_width=16,
    error_rate=0.0, # Error rate is 0 for the pure latency test
    local_chiplet_id=0,
    remote_chiplet_id=1
)

# 5. Create the Receiver (Chiplet 2)
# We use SimpleMemory with 0ns latency to ensure we ONLY measure the link latency
system.mem_ctrl = SimpleMemory(latency='0ns')
# Setting total memory size to 4GB as specified in the experimental setup [cite: 144]
system.mem_ctrl.range = AddrRange('4GiB')

# 6. Wire the Ports together
# TrafficGen RequestPort -> UCIeLink rx_port (ResponsePort)
system.traffic_gen.port = system.ucie_link.rx_port
# UCIeLink tx_port (RequestPort) -> Memory Port (ResponsePort)
system.ucie_link.tx_port = system.mem_ctrl.port

# 7. Generate the Traffic Configuration dynamically
cfg_file = f"traffic_cfg_{args.tlp_size}B.cfg"
with open(cfg_file, "w") as f:
    f.write(f"STATE 0 {args.iterations} LINEAR 100 0 2147483648 {payload_size} 1000 1000\n")
    f.write("INIT 0\n")
    f.write("TRANSITION 0 0 1.0\n")  # <--- ADD THIS LINE

system.traffic_gen.config_file = cfg_file

# 8. Run the Simulation
root = Root(full_system=False, system=system)
m5.instantiate()

print(f"Starting UCIe Latency Test for TLP Size: {args.tlp_size}B over {args.iterations} iterations [cite: 152, 157]")
exit_event = m5.simulate()

print(f"Exiting @ tick {m5.curTick()} because {exit_event.getCause()}")