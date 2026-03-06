import m5
from m5.objects import *

# 1. Basic System Setup
system = System()
system.clk_domain = SrcClockDomain(clock='1GHz', voltage_domain=VoltageDomain())
system.mem_range = [AddrRange('512MB')] # Required for the Traffic Generator

# 2. Instantiate the Components
# The CPU (Traffic Generator) on Die A
system.tgen = TrafficGen(config_file="tgen.cfg")

# The UCIe Interconnect
system.chiplet_A = UcieLink(link_latency='2ns', retry_buffer_capacity='32kB', flit_size=256)
system.chiplet_B = UcieLink(link_latency='2ns', retry_buffer_capacity='32kB', flit_size=256)

# The RAM on Die B
system.mem_ctrl = SimpleMemory(range=system.mem_range[0])

# 3. Wire the Pipeline End-to-End
# TrafficGen -> Chiplet A -> Chiplet B -> Memory
system.tgen.port = system.chiplet_A.rx_port
system.chiplet_A.tx_port = system.chiplet_B.rx_port
system.chiplet_B.tx_port = system.mem_ctrl.port

# 4. Initialize and Run
root = Root(full_system=False, system=system)
m5.instantiate()

print("=====================================================")
print("Starting Traffic Generation Test...")
print("Injecting 64-Byte TLPs into the UCIe pipeline...")
print("=====================================================")

# Run the simulation for 10,000 ticks
m5.simulate(10000)