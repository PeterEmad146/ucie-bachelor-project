"""
Test 2: CPU-Accelerator System Performance — Table II Reproduction
==================================================================
Models a heterogeneous chiplet system:
  CPU Chiplet  ──[UCIe Link]──  Accelerator Chiplet
  DDR4 / DDR3  (CPU memory)     HBM (Accelerator memory)

The CPU offloads a GEMM workload (read A, read B, compute, write C) to
the Accelerator over the UCIe link.  BER = 10^-10 is injected to exercise
the ACK/NAK retry path, matching the paper's experimental conditions.

Paper Table II metrics:
  - Execution cycles (from m5out/stats.txt → system.ticks / clk_period)
  - Throughput (Gb/s) → system.ucie_link_0.UcieStats.throughputGbps
  - Retransmissions   → system.ucie_link_0.UcieStats.totalRetransmissions
  - Payload efficiency→ system.ucie_link_0.UcieStats.payloadEfficiency

Run variants:
    UCIE_MEM_TYPE=DDR4  gem5.opt configs/example/ucie_sys/cpu_accel_system.py
    UCIE_MEM_TYPE=DDR3  gem5.opt configs/example/ucie_sys/cpu_accel_system.py
    UCIE_MEM_TYPE=HBM   gem5.opt configs/example/ucie_sys/cpu_accel_system.py
"""

import m5
from m5.objects import *
import os

# ── Workload parameters ────────────────────────────────────────────────────────
# GEMM: 256×256 float32 matrices → 256KB each.
# The offload sequence: read A (256KB), read B (256KB), write C (256KB).
MEM_TYPE  = os.environ.get("UCIE_MEM_TYPE", "DDR4").upper()
BURST     = 64          # bytes per request (cache-line sized)
THROTTLE  = 40_000      # ps between requests — prevents crossbar overflow
                        # (40 ns >> any single-flit latency)

# HBM base address (CPU memory occupies 0–8 GiB)
HBM_BASE  = 8 * 1024 * 1024 * 1024   # 8 GiB in bytes
A_BASE    = HBM_BASE
B_BASE    = HBM_BASE + 256 * 1024
C_BASE    = HBM_BASE + 512 * 1024
MATRIX_SZ = 256 * 1024               # 256 KB per matrix

# ── TrafficGen: GEMM offload trace ────────────────────────────────────────────
cfg_file = f"/tmp/gemm_{MEM_TYPE}.cfg"
with open(cfg_file, "w") as f:
    # STATE 0: CPU reads matrix A from Accelerator HBM over UCIe
    f.write(
        f"STATE 0 50000000 LINEAR 100 {A_BASE} {A_BASE + MATRIX_SZ} "
        f"{BURST} {THROTTLE} {THROTTLE} 0\n"
    )
    # STATE 1: CPU reads matrix B from Accelerator HBM over UCIe
    f.write(
        f"STATE 1 50000000 LINEAR 100 {B_BASE} {B_BASE + MATRIX_SZ} "
        f"{BURST} {THROTTLE} {THROTTLE} 0\n"
    )
    # STATE 2: IDLE — represents the GEMM multiply-accumulate compute time
    f.write("STATE 2 20000000 IDLE\n")
    # STATE 3: CPU writes result matrix C back to Accelerator HBM over UCIe
    f.write(
        f"STATE 3 50000000 LINEAR 0 {C_BASE} {C_BASE + MATRIX_SZ} "
        f"{BURST} {THROTTLE} {THROTTLE} 0\n"
    )
    # EXIT state — simulation terminates cleanly
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

# ── Chiplet 0: CPU side ───────────────────────────────────────────────────────
system.cpu_traffic = TrafficGen(config_file=cfg_file)
system.cpu_membus  = SystemXBar(max_routing_table_size=100_000)
system.cpu_traffic.port = system.cpu_membus.cpu_side_ports

# CPU local memory (DDR4 or DDR3, selectable)
system.cpu_mem_ctrl = MemCtrl()
if MEM_TYPE == "DDR3":
    system.cpu_mem_ctrl.dram = DDR3_1600_8x8()
else:
    system.cpu_mem_ctrl.dram = DDR4_2400_16x4()
system.cpu_mem_ctrl.dram.range = AddrRange('0', size='8GiB')
system.cpu_membus.mem_side_ports = system.cpu_mem_ctrl.port

# ── Chiplet 1: Accelerator side ───────────────────────────────────────────────
system.acc_membus = SystemXBar(max_routing_table_size=100_000)

system.acc_mem_ctrl = MemCtrl()
if MEM_TYPE == "HBM":
    system.acc_mem_ctrl.dram = HBM_2000_4H_1x64()
else:
    system.acc_mem_ctrl.dram = DDR4_2400_8x8()     # DDR4 fallback for ACC
system.acc_mem_ctrl.dram.range = AddrRange('8GiB', size='8GiB')
system.acc_membus.mem_side_ports = system.acc_mem_ctrl.port

# ── UCIe Link pair (Chiplet 0 TX → Chiplet 1 RX) ─────────────────────────────
# error_rate = 1e-10 (BER as used in the paper).
# The deterministic injection will fire once every ~4.88M flits.
ucie_params = dict(
    retry_timeout= '25ns',
    error_rate   = 1e-10,     # BER = 10^-10 as specified in the paper
    data_rate    = 4.0,       # GT/s per lane
    num_lanes    = 16,        # Standard UCIe package
    phys_delay   = '2ns',
    credit_pool  = 32,
)

system.ucie_link_0 = UcieLink(**ucie_params)
system.cpu_membus.mem_side_ports = system.ucie_link_0.rx_port

system.ucie_link_1 = UcieLink(**ucie_params)
system.ucie_link_1.tx_port = system.acc_membus.cpu_side_ports

# Physical die-to-die connection
system.ucie_link_0.tx_port = system.ucie_link_1.rx_port

# ── Run ───────────────────────────────────────────────────────────────────────
root = Root(full_system=False, system=system)
m5.instantiate()

print(f"\n{'='*60}")
print(f"  UCIe CPU-Accelerator GEMM Offload — {MEM_TYPE}")
print(f"{'='*60}")
print("  BER = 1e-10,  16 lanes × 4 GT/s,  2 ns physical delay")
print(f"{'='*60}\n")

exit_event = m5.simulate()

print(f"\nSimulation ended @ tick {m5.curTick()}: {exit_event.getCause()}")
print("\nKey stats to read from m5out/stats.txt:")
print("  system.ucie_link_0.UcieStats.throughputGbps")
print("  system.ucie_link_0.UcieStats.totalRetransmissions")
print("  system.ucie_link_0.UcieStats.payloadEfficiency")
print("  system.ucie_link_0.UcieStats.totalCrcErrors")
print("  system.ucie_link_0.UcieStats.tlpLatency::mean  (÷1000 = ns)")