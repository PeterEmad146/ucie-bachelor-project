"""
Baseline B: Monolithic (No-Link) Comparison Test
=================================================
Mimics a monolithic chip where both the "CPU die" and "Accelerator die"
share a single unified memory bus — no inter-die link overhead at all.

This is the zero-overhead ideal baseline: both chiplets share one
SystemXBar and one flat address space. There is no serialization latency,
no flit framing, no CRC, and no credit flow-control.

Supported workloads (set via WORKLOAD env var):
  WORKLOAD=gemm    — GEMM 256×256 float32
  WORKLOAD=conv2d  — Conv2D 128×128, 3×3 kernel, 32 filters
  WORKLOAD=fft     — FFT 256-point complex
  WORKLOAD=conv3d  — Conv3D 16×16×16, 3×3×3 kernel, 8 filters

Memory variants (set via UCIE_MEM_TYPE env var):
  DDR4 (default), DDR3, HBM

Run examples:
    WORKLOAD=gemm  UCIE_MEM_TYPE=DDR4  gem5.opt configs/example/ucie_sys/monolithic_accel_system.py
    WORKLOAD=conv2d UCIE_MEM_TYPE=HBM  gem5.opt configs/example/ucie_sys/monolithic_accel_system.py
    WORKLOAD=fft   UCIE_MEM_TYPE=DDR3  gem5.opt configs/example/ucie_sys/monolithic_accel_system.py
    WORKLOAD=conv3d UCIE_MEM_TYPE=HBM  gem5.opt configs/example/ucie_sys/monolithic_accel_system.py
"""

import m5
from m5.objects import *
import os

# ── Config ────────────────────────────────────────────────────────────────────
WORKLOAD = os.environ.get("WORKLOAD", "gemm").lower()
MEM_TYPE = os.environ.get("UCIE_MEM_TYPE", "DDR4").upper()
BURST    = 64
THROTTLE = 40_000  # ps

# ── Flat address map (monolithic — no chiplet boundary) ───────────────────────
# "CPU" memory region:  0 – 8 GiB
# "ACC" memory region:  8 – 16 GiB   (same SoC, just different DRAM controller)
CPU_MEM_SIZE  = '8GiB'
ACC_MEM_START = 0x200000000   # 8 GiB
ACC_MEM_SIZE  = '8GiB'

# ── Workload address constants ─────────────────────────────────────────────────
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

# ── Traffic pattern (identical to UCIe / PCIe tests for fair comparison) ─────
cfg_file = f"/tmp/mono_{WORKLOAD}_{MEM_TYPE}.cfg"
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

# ── System: one unified bus, two memory controllers ───────────────────────────
system = System()
system.clk_domain   = SrcClockDomain(clock='4GHz', voltage_domain=VoltageDomain())
system.mem_mode     = 'timing'
system.cache_line_size = 64
system.mem_ranges   = [AddrRange('0', size=CPU_MEM_SIZE),
                       AddrRange(str(ACC_MEM_START), size=ACC_MEM_SIZE)]

# Single shared crossbar — no chiplet boundary, no link layer
system.membus = SystemXBar(max_routing_table_size=100_000)

system.cpu_traffic = TrafficGen(config_file=cfg_file)
system.cpu_traffic.port = system.membus.cpu_side_ports

# "CPU" local memory (0–8 GiB)
system.cpu_mem_ctrl = MemCtrl()
if MEM_TYPE == "DDR3":
    system.cpu_mem_ctrl.dram = DDR3_1600_8x8()
else:
    system.cpu_mem_ctrl.dram = DDR4_2400_16x4()
system.cpu_mem_ctrl.dram.range = AddrRange('0', size=CPU_MEM_SIZE)
system.membus.mem_side_ports = system.cpu_mem_ctrl.port

# "Accelerator" memory (8–16 GiB) — same bus, no link in between
system.acc_mem_ctrl = MemCtrl()
if MEM_TYPE == "HBM":
    system.acc_mem_ctrl.dram = HBM_2000_4H_1x64()
else:
    system.acc_mem_ctrl.dram = DDR4_2400_8x8()
system.acc_mem_ctrl.dram.range = AddrRange(str(ACC_MEM_START), size=ACC_MEM_SIZE)
system.membus.mem_side_ports = system.acc_mem_ctrl.port

# ── Run ───────────────────────────────────────────────────────────────────────
root = Root(full_system=False, system=system)
m5.instantiate()

print(f"\n{'='*60}")
print(f"  Monolithic Baseline — Workload: {WORKLOAD.upper()} — {MEM_TYPE}")
print(f"{'='*60}")
print(f"  Link model : NONE (single shared SystemXBar)")
print(f"  (Mimics a monolithic SoC — zero inter-die link overhead)")
print(f"  CPU mem  : {MEM_TYPE} (0–8 GiB)")
print(f"  ACC mem  : {'HBM' if MEM_TYPE == 'HBM' else 'DDR4'} (8–16 GiB, same bus)")
print(f"{'='*60}\n")
print("  This is the ideal upper-bound: compare throughput and latency")
print("  against UCIe and PCIe baselines.\n")

exit_event = m5.simulate()
print(f"\nSimulation ended @ tick {m5.curTick()}: {exit_event.getCause()}")
print("\nNote: No UcieStats here. Use system-level tick count and")
print("      mem_ctrl stats for throughput/latency estimation.")
