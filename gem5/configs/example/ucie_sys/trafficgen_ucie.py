import m5
from m5.objects import *
import os

# 1. Dynamically generate a High-Bandwidth Traffic Configuration
cfg_file = "dma_blast.cfg"
with open(cfg_file, "w") as f:
    # Blast 64B writes continuously. Interval: 1000 ticks (1ns)
    f.write("STATE 0 10000000 LINEAR 0 0 536870912 64 1000 1000 0\n")
    f.write("INIT 0\n")
    f.write("TRANSITION 0 0 1\n")

system = System()
system.clk_domain = SrcClockDomain(clock='4GHz', voltage_domain=VoltageDomain())
system.mem_mode = 'timing'
system.cache_line_size = 64
system.mem_ranges = [AddrRange('16GiB')]


# --- CHIPLET 0 (DMA/TrafficGen Side) ---
system.tgen = TrafficGen(config_file=cfg_file)

system.ucie_link_0 = UcieLink(
    retry_timeout='25ns',
    error_rate=0.0,
    data_rate=4.0,
    num_lanes=16,
    phys_delay='2ns',
    credit_pool=32,
)

system.tgen.port = system.ucie_link_0.rx_port

# --- CHIPLET 1 (Memory Side) ---
# error_rate=1e-10 injects BER as in the paper; the retry buffer handles recovery.
system.ucie_link_1 = UcieLink(
    retry_timeout='25ns',
    error_rate=1e-10,
    data_rate=4.0,
    num_lanes=16,
    phys_delay='2ns',
    credit_pool=32,
)

system.mem_ctrl = MemCtrl()
system.mem_ctrl.dram = DDR4_2400_8x8()
system.mem_ctrl.dram.range = system.mem_ranges[0]

system.ucie_link_1.tx_port = system.mem_ctrl.port

# --- DIE-TO-DIE INTERFACE ---
system.ucie_link_0.tx_port = system.ucie_link_1.rx_port

root = Root(full_system=False, system=system)
m5.instantiate()

print("Starting High-Bandwidth UCIe DMA Test...")
# Run for a set amount of time to gather stats
exit_event = m5.simulate(10000000) 
print(f"Exiting @ tick {m5.curTick()} because {exit_event.getCause()}") 