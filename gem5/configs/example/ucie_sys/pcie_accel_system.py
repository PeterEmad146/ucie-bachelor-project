"""
Baseline A: PCIe Gen4 ×16 Comparison Test
==========================================
Uses gem5's `Bridge` object to model a PCIe Gen4 ×16 link as a comparison
baseline for the UCIe tests. The Bridge adds:
  - A configurable one-way latency (PCIe round-trip ~100–200 ns)
  - No flit-level framing, CRC, or credit flow-control overhead

This runs in SE (syscall-emulation) mode — no kernel required.

PCIe Gen4 ×16 reference parameters:
  - Raw BW: 64 GT/s × 16 lanes × (128b/130b encoding) ≈ 63.0 GB/s effective
  - One-way latency: ~100 ns (controller + serialization)

Supported workloads (set via WORKLOAD env var):
  WORKLOAD=gemm    — GEMM 256×256 float32
  WORKLOAD=conv2d  — Conv2D 128×128, 3×3 kernel, 32 filters
  WORKLOAD=fft     — FFT 256-point complex
  WORKLOAD=conv3d  — Conv3D 16×16×16, 3×3×3 kernel, 8 filters

Memory variants (set via UCIE_MEM_TYPE env var):
  DDR4 (default), DDR3, HBM

Run examples:
    WORKLOAD=gemm  UCIE_MEM_TYPE=DDR4  gem5.opt configs/example/ucie_sys/pcie_accel_system.py
    WORKLOAD=conv2d UCIE_MEM_TYPE=HBM  gem5.opt configs/example/ucie_sys/pcie_accel_system.py
    WORKLOAD=fft   UCIE_MEM_TYPE=DDR3  gem5.opt configs/example/ucie_sys/pcie_accel_system.py
    WORKLOAD=conv3d UCIE_MEM_TYPE=HBM  gem5.opt configs/example/ucie_sys/pcie_accel_system.py
"""

import m5
from m5.objects import *
import os

# ── Config ────────────────────────────────────────────────────────────────────
WORKLOAD = os.environ.get("WORKLOAD", "gemm").lower()
MEM_TYPE = os.environ.get("UCIE_MEM_TYPE", "DDR4").upper()
BURST    = 64
THROTTLE = 40_000  # ps

# PCIe Gen4 ×16 link parameters (modelled via Bridge)
# One-way latency: 100 ns = 100,000 ps
# Bandwidth: 63 GB/s ≈ no per-packet throttle needed (bridge is not BW-limited here;
#   the THROTTLE in the traffic pattern captures the effective access rate)
PCIE_LATENCY_NS = '100ns'

# ── Address map ───────────────────────────────────────────────────────────────
CPU_MEM_SIZE  = '8GiB'
ACC_MEM_START = 0x200000000   # 8 GiB
ACC_MEM_SIZE  = '8GiB'

# ── Workload traffic patterns ─────────────────────────────────────────────────
# All workloads send traffic to the Accelerator's HBM address range (8–16 GiB)
# crossing the PCIe Bridge. CPU-local accesses (0–8 GiB) go directly to local DDR.

A_BASE      = ACC_MEM_START
B_BASE      = ACC_MEM_START + 256 * 1024
C_BASE      = ACC_MEM_START + 512 * 1024
MATRIX_SZ   = 256 * 1024

IFM_BASE    = ACC_MEM_START
WEIGHT_BASE = ACC_MEM_START + 128 * 1024
OFM_BASE    = ACC_MEM_START + 160 * 1024

FFT_N        = 256
FFT_ARRAY_B  = FFT_N * 8
TWIDDLE_B    = (FFT_N // 2) * 8
FFT_IN_BASE  = 0x1000
FFT_OUT_BASE = FFT_IN_BASE + FFT_ARRAY_B
TWIDDLE_BASE = FFT_OUT_BASE + FFT_ARRAY_B

IFV_BASE     = ACC_MEM_START
W3D_BASE     = ACC_MEM_START + 16 * 1024
OFV_BASE     = ACC_MEM_START + 18 * 1024

cfg_file = f"/tmp/pcie_{WORKLOAD}_{MEM_TYPE}.cfg"
with open(cfg_file, "w") as f:
    if WORKLOAD == "gemm":
        f.write(f"STATE 0 0 LINEAR 100 {A_BASE} {A_BASE + MATRIX_SZ} {BURST} {THROTTLE} {THROTTLE} {MATRIX_SZ}\n")
        f.write(f"STATE 1 0 LINEAR 100 {B_BASE} {B_BASE + MATRIX_SZ} {BURST} {THROTTLE} {THROTTLE} {MATRIX_SZ}\n")
        f.write( "STATE 2 20000000 IDLE\n")
        f.write(f"STATE 3 0 LINEAR 0 {C_BASE} {C_BASE + MATRIX_SZ} {BURST} {THROTTLE} {THROTTLE} {MATRIX_SZ}\n")
        f.write( "STATE 4 1000 EXIT\n")
        f.write( "INIT 0\n")
        for i in range(4): f.write(f"TRANSITION {i} {i+1} 1\n")
        f.write( "TRANSITION 4 4 1\n")

    elif WORKLOAD == "conv2d":
        f.write(f"STATE 0 0 LINEAR 100 {IFM_BASE} {IFM_BASE + 131072} {BURST} {THROTTLE} {THROTTLE} 131072\n")
        f.write(f"STATE 1 0 LINEAR 100 {WEIGHT_BASE} {WEIGHT_BASE + 32768} {BURST} {THROTTLE} {THROTTLE} 32768\n")
        f.write( "STATE 2 15000000 IDLE\n")
        f.write(f"STATE 3 0 LINEAR 0 {OFM_BASE} {OFM_BASE + 65536} {BURST} {THROTTLE} {THROTTLE} 65536\n")
        f.write( "STATE 4 1000 EXIT\n")
        f.write( "INIT 0\n")
        for i in range(4): f.write(f"TRANSITION {i} {i+1} 1\n")
        f.write( "TRANSITION 4 4 1\n")

    elif WORKLOAD == "fft":
        f.write(f"STATE 0 0 LINEAR 100 {FFT_IN_BASE} {FFT_IN_BASE + FFT_ARRAY_B} {BURST} {THROTTLE} {THROTTLE} {FFT_ARRAY_B}\n")
        f.write(f"STATE 1 0 RANDOM 100 {FFT_IN_BASE} {FFT_IN_BASE + FFT_ARRAY_B} {BURST} {THROTTLE} {THROTTLE} {FFT_ARRAY_B}\n")
        f.write(f"STATE 2 0 LINEAR 100 {TWIDDLE_BASE} {TWIDDLE_BASE + TWIDDLE_B} {BURST} {THROTTLE} {THROTTLE} {TWIDDLE_B}\n")
        f.write(f"STATE 3 0 LINEAR 0 {IFV_BASE} {IFV_BASE + FFT_ARRAY_B} {BURST} {THROTTLE} {THROTTLE} {FFT_ARRAY_B}\n")
        f.write(f"STATE 4 0 LINEAR 100 {OFV_BASE} {OFV_BASE + 65536} {BURST} {THROTTLE} {THROTTLE} 65536\n")
        f.write( "STATE 5 1000 EXIT\n")
        f.write( "INIT 0\n")
        for i in range(5): f.write(f"TRANSITION {i} {i+1} 1\n")
        f.write( "TRANSITION 5 5 1\n")

    elif WORKLOAD == "conv3d":
        f.write(f"STATE 0 0 LINEAR 100 {IFV_BASE} {IFV_BASE + 16384} {BURST} {THROTTLE} {THROTTLE} 16384\n")
        f.write(f"STATE 1 0 LINEAR 100 {W3D_BASE} {W3D_BASE + 2048} {BURST} {THROTTLE} {THROTTLE} 2048\n")
        f.write( "STATE 2 20000000 IDLE\n")
        f.write(f"STATE 3 0 LINEAR 0 {OFV_BASE} {OFV_BASE + 65536} {BURST} {THROTTLE} {THROTTLE} 65536\n")
        f.write( "STATE 4 1000 EXIT\n")
        f.write( "INIT 0\n")
        for i in range(4): f.write(f"TRANSITION {i} {i+1} 1\n")
        f.write( "TRANSITION 4 4 1\n")

    else:
        raise ValueError(f"Unknown WORKLOAD='{WORKLOAD}'. Choose: gemm, conv2d, fft, conv3d")

# ── System ────────────────────────────────────────────────────────────────────
system = System()
system.clk_domain   = SrcClockDomain(clock='4GHz', voltage_domain=VoltageDomain())
system.mem_mode     = 'timing'
system.cache_line_size = 64
system.mem_ranges   = [AddrRange('0', size=CPU_MEM_SIZE),
                       AddrRange(str(ACC_MEM_START), size=ACC_MEM_SIZE)]

# ── Chiplet 0: CPU side ───────────────────────────────────────────────────────
system.cpu_traffic = TrafficGen(config_file=cfg_file)
system.cpu_membus  = SystemXBar(max_routing_table_size=100_000)
system.cpu_traffic.port = system.cpu_membus.cpu_side_ports

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
    system.acc_mem_ctrl.dram = DDR4_2400_8x8()
system.acc_mem_ctrl.dram.range = AddrRange(str(ACC_MEM_START), size=ACC_MEM_SIZE)
system.acc_membus.mem_side_ports = system.acc_mem_ctrl.port

# ── PCIe Bridge (replaces UCIe link) ─────────────────────────────────────────
# gem5's Bridge models a point-to-point timing link with configurable latency.
# delay = one-way serialisation + controller latency (100 ns for PCIe Gen4).
# No flit framing, CRC checks, or credit flow-control — only delay is modelled.
system.pcie_bridge = Bridge(delay=PCIE_LATENCY_NS)
system.pcie_bridge.ranges = [AddrRange(str(ACC_MEM_START), size=ACC_MEM_SIZE)]
system.pcie_bridge.mem_side_port  = system.acc_membus.cpu_side_ports
system.pcie_bridge.cpu_side_port  = system.cpu_membus.mem_side_ports

# ── Run ───────────────────────────────────────────────────────────────────────
root = Root(full_system=False, system=system)
m5.instantiate()

print(f"\n{'='*60}")
print(f"  PCIe Gen4 ×16 Baseline — Workload: {WORKLOAD.upper()} — {MEM_TYPE}")
print(f"{'='*60}")
print(f"  Link model : gem5 Bridge, one-way delay = {PCIE_LATENCY_NS}")
print(f"  (No flit framing, no CRC, no credit flow-control)")
print(f"  CPU memory : {MEM_TYPE} (local, 0–8 GiB)")
print(f"  ACC memory : {'HBM' if MEM_TYPE == 'HBM' else 'DDR4'} (remote, 8–16 GiB)")
print(f"{'='*60}\n")
print("  Compare these stats against UCIe equivalents:")
print("  (No UcieStats here — read system-level stats instead)")
print("  m5out/stats.txt → system.cpu_traffic.* for throughput estimation\n")

exit_event = m5.simulate()
print(f"\nSimulation ended @ tick {m5.curTick()}: {exit_event.getCause()}")
print("\nNote: For latency comparison, the Bridge adds a fixed one-way delay")
print(f"of {PCIE_LATENCY_NS} (no retransmission overhead unlike UCIe with BER=1e-10).")