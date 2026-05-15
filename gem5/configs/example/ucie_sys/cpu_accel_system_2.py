"""
Test 2b: CNN Conv2D Offload via UCIe
=====================================
Same topology as cpu_accel_system.py but with a Conv2D memory access pattern
instead of GEMM — reads Input Feature Maps + Kernel Weights, writes Output
Feature Maps.  This reproduces the Conv2d row of the paper's Table II.

Run:
    build/X86/gem5.opt configs/example/ucie_sys/cpu_accel_system_2.py
"""

import m5
from m5.objects import *
import os

# ── Workload: Conv2D sliding-window pattern ───────────────────────────────────
HBM_BASE    = 8 * 1024 * 1024 * 1024   # 8 GiB
IFM_BASE    = HBM_BASE                  # Input Feature Maps  (128 KB)
WEIGHT_BASE = HBM_BASE + 128 * 1024    # Kernel Weights      (32 KB)
OFM_BASE    = HBM_BASE + 160 * 1024    # Output Feature Maps (64 KB)
BURST       = 64
THROTTLE    = 40_000  # ps

cfg_file = "/tmp/conv2d_offload.cfg"
with open(cfg_file, "w") as f:
    # STATE 0: Read Input Feature Maps (image rows)
    f.write(
        f"STATE 0 50000000 LINEAR 100 {IFM_BASE} {IFM_BASE + 131072} "
        f"{BURST} {THROTTLE} {THROTTLE} 0\n"
    )
    # STATE 1: Read Kernel Weights (small, highly reused)
    f.write(
        f"STATE 1 20000000 LINEAR 100 {WEIGHT_BASE} {WEIGHT_BASE + 32768} "
        f"{BURST} {THROTTLE} {THROTTLE} 0\n"
    )
    # STATE 2: IDLE — 2D sliding-window MAC compute
    f.write("STATE 2 15000000 IDLE\n")
    # STATE 3: Write Output Feature Maps
    f.write(
        f"STATE 3 50000000 LINEAR 0 {OFM_BASE} {OFM_BASE + 65536} "
        f"{BURST} {THROTTLE} {THROTTLE} 0\n"
    )
    f.write("STATE 4 1000 EXIT\n")
    f.write("INIT 0\n")
    f.write("TRANSITION 0 1 1\n")
    f.write("TRANSITION 1 2 1\n")
    f.write("TRANSITION 2 3 1\n")
    f.write("TRANSITION 3 4 1\n")
    f.write("TRANSITION 4 4 1\n")

# ── System ────────────────────────────────────────────────────────────────────
system = System()
system.clk_domain   = SrcClockDomain(clock='4GHz', voltage_domain=VoltageDomain())
system.mem_mode     = 'timing'
system.cache_line_size = 64

# Chiplet 0 — CPU
system.cpu_traffic = TrafficGen(config_file=cfg_file)
system.cpu_membus  = SystemXBar(max_routing_table_size=100_000)
system.cpu_traffic.port = system.cpu_membus.cpu_side_ports

system.cpu_mem_ctrl = MemCtrl()
system.cpu_mem_ctrl.dram = DDR4_2400_16x4()
system.cpu_mem_ctrl.dram.range = AddrRange('0', size='8GiB')
system.cpu_membus.mem_side_ports = system.cpu_mem_ctrl.port

# Chiplet 1 — Accelerator
system.acc_membus = SystemXBar(max_routing_table_size=100_000)
system.acc_mem_ctrl = MemCtrl()
system.acc_mem_ctrl.dram = HBM_2000_4H_1x64()
system.acc_mem_ctrl.dram.range = AddrRange('8GiB', size='8GiB')
system.acc_membus.mem_side_ports = system.acc_mem_ctrl.port

# UCIe Link pair
ucie_params = dict(
    retry_timeout='25ns', error_rate=1e-10,
    data_rate=4.0, num_lanes=16, phys_delay='2ns', credit_pool=32,
)
system.ucie_link_0 = UcieLink(**ucie_params)
system.cpu_membus.mem_side_ports = system.ucie_link_0.rx_port

system.ucie_link_1 = UcieLink(**ucie_params)
system.ucie_link_1.tx_port = system.acc_membus.cpu_side_ports
system.ucie_link_0.tx_port = system.ucie_link_1.rx_port

root = Root(full_system=False, system=system)
m5.instantiate()

print("\nStarting Conv2D Offload via UCIe (4GHz, 16×4GT/s, BER=1e-10)...")
exit_event = m5.simulate()
print(f"\nExiting @ tick {m5.curTick()}: {exit_event.getCause()}")