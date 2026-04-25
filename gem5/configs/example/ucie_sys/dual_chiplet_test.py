import m5
from m5.objects import *
import argparse
import os

# 1. Parse command-line arguments for TLP size
parser = argparse.ArgumentParser(description="UCIe Dual-Chiplet Latency Test")
parser.add_argument("--tlp_size", type=int, default=32, help="Size of the TLP in bytes")
parser.add_argument("--iterations", type=int, default=10000, help="Number of packets to send")
args = parser.parse_args()

# The paper states TLP size includes a 16B header[cite: 157]. 
# TrafficGen payload size is (TLP size - 16).
payload_size = args.tlp_size - 16

# 2. Setup the System
system = System()
system.cache_line_size = 4096  
system.clk_domain = SrcClockDomain(clock='1GHz', voltage_domain=VoltageDomain())
system.mem_mode = 'timing'

# 3. Create the Pkt Sender (Chiplet 1) 
system.traffic_gen = TrafficGen()

# 4. Create the TX UCIe Link (Chiplet 1 -> Chiplet 2)
# Configured for 64GT/s and 2ns delay [cite: 134, 137]
system.ucie_link_tx = UcieLink(
    link_latency='2ns',
    data_rate='64GT/s',
    data_rate_gbps=64.0,
    flit_size=256,
    link_width=16,
    error_rate=0.0, 
    local_chiplet_id=0,
    remote_chiplet_id=1
)

# 5. Create the RX UCIe Link (Chiplet 2 -> Chiplet 1)
# Latency is 0ns here because the 2ns delay is already modeled on the TX side
system.ucie_link_rx = UcieLink(
    link_latency='0ns',
    data_rate='64GT/s',
    data_rate_gbps=64.0,
    flit_size=256,
    link_width=16,
    error_rate=0.0,
    local_chiplet_id=1,
    remote_chiplet_id=0
)

# 6. Create the Receiver (Chiplet 2 Memory)
system.mem_ctrl = SimpleMemory(latency='0ns')
# Shrunk to 256MB to prevent Out-Of-Memory crashes on local execution
system.mem_ctrl.range = AddrRange('256MiB')

# 7. Wire the Ports together across the Die-to-Die boundary
# TrafficGen -> TX Link -> RX Link -> Memory
system.traffic_gen.port = system.ucie_link_tx.rx_port
system.ucie_link_tx.tx_port = system.ucie_link_rx.rx_port
system.ucie_link_rx.tx_port = system.mem_ctrl.port

# 8. Generate the Traffic Configuration dynamically
# TARGET BANDWIDTH: 100 GB/s (Safe zone to prevent queue deadlock)
# 100 GB/s = 1 byte every 10 picoseconds (ticks).
# Therefore, the perfect period for ANY packet size is (size * 10) ticks.
injection_period = args.tlp_size * 128

# Calculate total duration based on dynamic period
duration_ticks = args.iterations * injection_period

cfg_file = f"traffic_cfg_{args.tlp_size}B.cfg"
with open(cfg_file, "w") as f:
    f.write(f"STATE 0 {duration_ticks} RANDOM 0 0 268435456 {payload_size} {injection_period} {injection_period}\n")
    f.write("STATE 1 100000 IDLE\n")
    f.write("INIT 0\n")
    f.write("TRANSITION 0 1 1.0\n")
    f.write("TRANSITION 1 1 1.0\n")

system.traffic_gen.config_file = cfg_file

# 9. Run the Simulation
root = Root(full_system=False, system=system)
m5.instantiate()

if args.iterations == 0:
    exit(0)

# Massive tick buffer to allow the final 4096B packets to finish their round trip
max_sim_ticks = duration_ticks + 50000000 
exit_event = m5.simulate(max_sim_ticks)

print(f"Exiting @ tick {m5.curTick()} because {exit_event.getCause()} (or reached tick limit)")