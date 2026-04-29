import m5
from m5.objects import *
import os

# --- TABLE I TEST CONFIGURATION ---
# Table I Data Sizes: 16, 48, 80, 112, 240, 496, 880, 1008, 2032, 4080
# Because your C++ code does 'tlpSize = pkt->getSize() + 16', 
# setting DATA_SIZE = 48 will correctly generate a 64B TLP.
DATA_SIZE = 4080

# Generate a heavily spaced-out TrafficGen config to prevent queueing
cfg_file = f"latency_test_{DATA_SIZE}B.cfg"
with open(cfg_file, "w") as f:
    # Send 1 request, wait 1000000 ticks (1000ns), then send the next.
    f.write(f"STATE 0 100000000 LINEAR 0 0 536870912 {DATA_SIZE} 1000000 1000000 0\n")
    f.write("INIT 0\n")
    f.write("TRANSITION 0 0 1\n")

system = System()

# The paper explicitly configures the digital data path to 250 MHz.
# This ensures our accumulation math (16 - 1/2f) yields exactly 14ns.
system.clk_domain = SrcClockDomain(clock='250MHz', voltage_domain=VoltageDomain())
system.mem_mode = 'timing'
system.cache_line_size = 4096 
system.mem_ranges = [AddrRange('16GiB')]

# --- CHIPLET A ---
system.tgen = TrafficGen(config_file=cfg_file)

system.ucie_link_0 = UcieLink(
    retry_timeout='25ns', 
    error_rate=0.0  # Perfect channel for baseline latency
)
system.tgen.port = system.ucie_link_0.rx_port

# --- CHIPLET B ---
system.ucie_link_1 = UcieLink(
    retry_timeout='25ns', 
    error_rate=0.0  # Perfect channel for baseline latency
)

system.mem_ctrl = MemCtrl()
system.mem_ctrl.dram = DDR4_2400_8x8()
system.mem_ctrl.dram.range = system.mem_ranges[0]

system.ucie_link_1.tx_port = system.mem_ctrl.port

# --- DIE-TO-DIE INTERFACE ---
system.ucie_link_0.tx_port = system.ucie_link_1.rx_port

root = Root(full_system=False, system=system)
m5.instantiate()

print(f"Starting Baseline Latency Test for Data Size: {DATA_SIZE}B (TLP: {DATA_SIZE+16}B)")
exit_event = m5.simulate(10000000) 
print(f"Exiting @ tick {m5.curTick()} because {exit_event.getCause()}")