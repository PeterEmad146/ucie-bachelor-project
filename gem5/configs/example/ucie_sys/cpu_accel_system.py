"""
Test 2a: CPU-Accelerator GEMM Offload via UCIe  (Table II Reproduction)
=======================================================================
Models a heterogeneous dual-chiplet system:

  CPU Chiplet                       Accelerator Chiplet
  ──────────────────────            ──────────────────────────────
  TrafficGen (GEMM pattern)         SystemXBar
  SystemXBar                        └── HBM (acc memory, 8–16 GiB)
  ├── CPU local DDR  (0–8 GiB)   ← direct, NO UCIe
  └── UCIe link TX ──────────────── UCIe link RX
                   [die-to-die]

The CPU offloads a GEMM workload (read A, read B, compute, write C) to
the Accelerator over the UCIe link.  BER = 10^-10 exercises the ACK/NAK
retry path, matching the paper's experimental conditions.

Paper Table II metrics (read from m5out/stats.txt):
  - system.ucie_link_0.UcieStats.throughputGbps
  - system.ucie_link_0.UcieStats.totalRetransmissions
  - system.ucie_link_0.UcieStats.payloadEfficiency
  - system.ucie_link_0.UcieStats.totalCrcErrors
  - system.ucie_link_0.UcieStats.tlpLatency::mean  (÷1000 = ns)

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
# Offload sequence (CPU → Accelerator over UCIe):
#   1. CPU reads matrix A from Accelerator HBM  (256KB reads)
#   2. CPU reads matrix B from Accelerator HBM  (256KB reads)
#   3. IDLE — represents the multiply-accumulate compute time on the accelerator
#   4. CPU writes result matrix C to Accelerator HBM  (256KB writes)
MEM_TYPE  = os.environ.get("UCIE_MEM_TYPE", "DDR4").upper()
BURST     = 64          # bytes per request (cache-line sized)
THROTTLE  = 40_000      # ps between requests — prevents crossbar overflow

# ── Address map ───────────────────────────────────────────────────────────────
# CPU local memory:  0x0000_0000 – 0x2_0000_0000  (0 – 8 GiB)
# Accelerator HBM:   0x2_0000_0000 – 0x4_0000_0000  (8 – 16 GiB)
CPU_MEM_SIZE  = '8GiB'
ACC_MEM_START = 0x200000000   # 8 GiB
ACC_MEM_SIZE  = '8GiB'

A_BASE    = ACC_MEM_START
B_BASE    = ACC_MEM_START + 256 * 1024
C_BASE    = ACC_MEM_START + 512 * 1024
MATRIX_SZ = 256 * 1024               # 256 KB per matrix

# ── TrafficGen: GEMM offload trace ────────────────────────────────────────────
cfg_file = f"/tmp/gemm_{MEM_TYPE}.cfg"
with open(cfg_file, "w") as f:
    # STATE 0: CPU reads matrix A from Accelerator HBM over UCIe (reads = cmd 100)
    f.write(
        f"STATE 0 0 LINEAR 100 {A_BASE} {A_BASE + MATRIX_SZ} "
        f"{BURST} {THROTTLE} {THROTTLE} {MATRIX_SZ}\n"
    )
    # STATE 1: CPU reads matrix B from Accelerator HBM over UCIe
    f.write(
        f"STATE 1 0 LINEAR 100 {B_BASE} {B_BASE + MATRIX_SZ} "
        f"{BURST} {THROTTLE} {THROTTLE} {MATRIX_SZ}\n"
    )
    # STATE 2: IDLE — represents the GEMM multiply-accumulate compute time
    f.write("STATE 2 20000000 IDLE\n")
    # STATE 3: CPU writes result matrix C back to Accelerator HBM over UCIe (writes = cmd 0)
    f.write(
        f"STATE 3 0 LINEAR 0 {C_BASE} {C_BASE + MATRIX_SZ} "
        f"{BURST} {THROTTLE} {THROTTLE} {MATRIX_SZ}\n"
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
# Declare BOTH address ranges so gem5 knows about the full memory map
system.mem_ranges   = [AddrRange('0', size=CPU_MEM_SIZE),
                       AddrRange(str(ACC_MEM_START), size=ACC_MEM_SIZE)]

# ── Chiplet 0: CPU side ───────────────────────────────────────────────────────
system.cpu_traffic = TrafficGen(config_file=cfg_file)
system.cpu_membus  = SystemXBar(max_routing_table_size=100_000)
system.cpu_traffic.port = system.cpu_membus.cpu_side_ports

# CPU local memory (DDR4 or DDR3, selectable via UCIE_MEM_TYPE).
# Connected DIRECTLY to the CPU-side bus — does NOT go over UCIe.
system.cpu_mem_ctrl = MemCtrl()
if MEM_TYPE == "DDR3":
    system.cpu_mem_ctrl.dram = DDR3_1600_8x8()
else:
    system.cpu_mem_ctrl.dram = DDR4_2400_16x4()
system.cpu_mem_ctrl.dram.range = AddrRange('0', size=CPU_MEM_SIZE)
system.cpu_membus.mem_side_ports = system.cpu_mem_ctrl.port

# ── Chiplet 1: Accelerator side ───────────────────────────────────────────────
system.acc_membus = SystemXBar(max_routing_table_size=100_000)

system.acc_mem_ctrl = MemCtrl()
if MEM_TYPE == "HBM":
    system.acc_mem_ctrl.dram = HBM_2000_4H_1x64()
else:
    system.acc_mem_ctrl.dram = DDR4_2400_8x8()     # DDR4 fallback for ACC side
system.acc_mem_ctrl.dram.range = AddrRange(str(ACC_MEM_START), size=ACC_MEM_SIZE)
system.acc_membus.mem_side_ports = system.acc_mem_ctrl.port

# ── UCIe Link pair (Chiplet 0 TX → Chiplet 1 RX) ─────────────────────────────
# Only traffic addressed to the Accelerator HBM range (8–16 GiB) flows over UCIe.
# error_rate = 1e-10 (per-lane BER as used in the paper).
ucie_params = dict(
    retry_timeout= '25ns',
    error_rate   = 1e-10,     # per-lane BER = 10^-10 as specified in the paper
    data_rate    = 4.0,       # GT/s per lane
    num_lanes    = 16,        # Standard UCIe package
    phys_delay   = '2ns',
    credit_pool  = 32,
)

# TX side: the CPU bus sends remote HBM-bound traffic out over UCIe link 0.
# (Gem5 routes by AddrRange: addresses 8–16 GiB automatically go to this port
#  because the local DDR only covers 0–8 GiB.)
system.ucie_link_0 = UcieLink(**ucie_params)
system.cpu_membus.mem_side_ports = system.ucie_link_0.rx_port

# RX side: UCIe link 1 delivers traffic into the Accelerator's memory bus.
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
print(f"  Workload   : GEMM 256×256 float32 (3×256KB matrix transfers)")
print(f"  CPU memory : {MEM_TYPE} (local, 0–8 GiB)")
print(f"  ACC memory : {'HBM' if MEM_TYPE == 'HBM' else 'DDR4'} (remote, 8–16 GiB)")
print(f"  UCIe link  : 16 lanes × 4 GT/s  |  BER=1e-10  |  2ns phys delay")
print(f"{'='*60}\n")

exit_event = m5.simulate()

print(f"\nSimulation ended @ tick {m5.curTick()}: {exit_event.getCause()}")
print("\nKey stats to read from m5out/stats.txt:")
print("  system.ucie_link_0.UcieStats.throughputGbps")
print("  system.ucie_link_0.UcieStats.totalRetransmissions")
print("  system.ucie_link_0.UcieStats.payloadEfficiency")
print("  system.ucie_link_0.UcieStats.totalCrcErrors")
print("  system.ucie_link_0.UcieStats.tlpLatency::mean  (÷1000 = ns)")