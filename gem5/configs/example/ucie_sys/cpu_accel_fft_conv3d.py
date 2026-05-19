"""
Test 3: CPU-Accelerator FFT + Conv3D Offload via UCIe
======================================================
Models a heterogeneous dual-chiplet system with two *different* workloads
running concurrently across the UCIe link:

  CPU Chiplet                         Accelerator Chiplet
  ─────────────────────────────       ──────────────────────────────────
  Workload: FFT (256-point complex)   Workload: Conv3D (16×16×16 volume)
  SystemXBar                          SystemXBar
  ├── CPU local DDR  (0–8 GiB)  ← direct, NO UCIe
  └── UCIe link TX ──────────────── UCIe link RX
                   [die-to-die]        └── Accelerator HBM (8–16 GiB)

FFT access pattern (CPU side):
  Phase 1: Read complex input array (stride-1, sequential)
  Phase 2: Bit-reversal permutation (irregular stride reads)
  Phase 3: Twiddle factor reads (small lookup table)
  Phase 4: Write output array

Conv3D access pattern (Accelerator side, modelled as HBM traffic):
  Phase 1: Read 3D input volume  (IFV, 3D sliding-window)
  Phase 2: Read 3D kernel weights
  Phase 3: IDLE — volumetric MAC compute
  Phase 4: Write 3D output volume (OFV)

Memory variants:
    UCIE_MEM_TYPE=DDR4  gem5.opt configs/example/ucie_sys/cpu_accel_fft_conv3d.py
    UCIE_MEM_TYPE=DDR3  gem5.opt configs/example/ucie_sys/cpu_accel_fft_conv3d.py
    UCIE_MEM_TYPE=HBM   gem5.opt configs/example/ucie_sys/cpu_accel_fft_conv3d.py
"""

import m5
from m5.objects import *
import os

MEM_TYPE = os.environ.get("UCIE_MEM_TYPE", "DDR4").upper()
BURST    = 64    # bytes per cache-line request
THROTTLE = 40_000  # ps between requests

# ── Address map ───────────────────────────────────────────────────────────────
# CPU local memory:  0x0000_0000_0000 – 0x0000_0002_0000_0000  (0 – 8 GiB)
# Accelerator HBM:   0x0000_0002_0000_0000 – 0x0000_0004_0000_0000  (8 – 16 GiB)
CPU_MEM_SIZE  = '8GiB'
ACC_MEM_START = 0x200000000   # 8 GiB
ACC_MEM_SIZE  = '8GiB'

# ── FFT workload layout (all in CPU-local DDR, 0–8 GiB range) ─────────────────
# 256-point complex FFT: each sample = 8 bytes (4B real + 4B imag)
FFT_N        = 256
FFT_SAMPLE_B = 8   # bytes per complex sample
FFT_ARRAY_B  = FFT_N * FFT_SAMPLE_B        # 2048 B — input / output array
TWIDDLE_B    = (FFT_N // 2) * FFT_SAMPLE_B # 1024 B — twiddle factor table

FFT_INPUT_BASE   = 0x0000_1000       # page-aligned, well inside 0–8GiB
FFT_OUTPUT_BASE  = FFT_INPUT_BASE  + FFT_ARRAY_B
FFT_TWIDDLE_BASE = FFT_OUTPUT_BASE + FFT_ARRAY_B

# ── Conv3D workload layout (Accelerator HBM, 8–16 GiB range) ─────────────────
# Conv3D on a 16×16×16 volume with a 3×3×3 kernel, 8 filters:
#   IFV:     16×16×16×1  float32 = 16,384 B = 16 KB
#   Weights: 3×3×3×1×8  float32 =  1,728 B ≈  2 KB
#   OFV:     14×14×14×8  float32 = 87,808 B ≈ 86 KB  (write only ~64 KB slice)
IFV_BASE    = ACC_MEM_START
WEIGHT3D_BASE = ACC_MEM_START + 16 * 1024
OFV_BASE    = ACC_MEM_START + 18 * 1024

# ── CPU TrafficGen: FFT pattern ───────────────────────────────────────────────
# The FFT is LOCAL to the CPU chiplet (0–8 GiB), so it goes through the local
# DDR, NOT over UCIe.  We model it here to stress the CPU memory subsystem
# and then send results over UCIe in the final write phase.
# The last state writes FFT output to Accelerator HBM OVER UCIe.
fft_cfg = f"/tmp/fft_{MEM_TYPE}.cfg"
with open(fft_cfg, "w") as f:
    # STATE 0: Sequential read of complex input (stride-1, cache-friendly)
    f.write(
        f"STATE 0 10000000 LINEAR 100 {FFT_INPUT_BASE} "
        f"{FFT_INPUT_BASE + FFT_ARRAY_B} {BURST} {THROTTLE} {THROTTLE} 0\n"
    )
    # STATE 1: Bit-reversal permutation (stride-2 reads simulated as RANDOM)
    f.write(
        f"STATE 1 10000000 RANDOM 100 {FFT_INPUT_BASE} "
        f"{FFT_INPUT_BASE + FFT_ARRAY_B} {BURST} {THROTTLE} {THROTTLE} 0\n"
    )
    # STATE 2: Twiddle factor lookup (small repeated reads)
    f.write(
        f"STATE 2 8000000 LINEAR 100 {FFT_TWIDDLE_BASE} "
        f"{FFT_TWIDDLE_BASE + TWIDDLE_B} {BURST} {THROTTLE} {THROTTLE} 0\n"
    )
    # STATE 3: Write FFT result to Accelerator HBM over UCIe (addresses 8–16 GiB)
    f.write(
        f"STATE 3 20000000 LINEAR 0 {IFV_BASE} "
        f"{IFV_BASE + FFT_ARRAY_B} {BURST} {THROTTLE} {THROTTLE} 0\n"
    )
    # STATE 4: Read Conv3D output from Accelerator HBM back over UCIe
    f.write(
        f"STATE 4 30000000 LINEAR 100 {OFV_BASE} "
        f"{OFV_BASE + 65536} {BURST} {THROTTLE} {THROTTLE} 0\n"
    )
    f.write("STATE 5 1000 EXIT\n")
    f.write("INIT 0\n")
    f.write("TRANSITION 0 1 1\n")
    f.write("TRANSITION 1 2 1\n")
    f.write("TRANSITION 2 3 1\n")
    f.write("TRANSITION 3 4 1\n")
    f.write("TRANSITION 4 5 1\n")
    f.write("TRANSITION 5 5 1\n")

# ── System ────────────────────────────────────────────────────────────────────
system = System()
system.clk_domain   = SrcClockDomain(clock='4GHz', voltage_domain=VoltageDomain())
system.mem_mode     = 'timing'
system.cache_line_size = 64
system.mem_ranges   = [AddrRange('0', size=CPU_MEM_SIZE),
                       AddrRange(str(ACC_MEM_START), size=ACC_MEM_SIZE)]

# ── Chiplet 0: CPU side ───────────────────────────────────────────────────────
system.cpu_traffic = TrafficGen(config_file=fft_cfg)
system.cpu_membus  = SystemXBar(max_routing_table_size=100_000)
system.cpu_traffic.port = system.cpu_membus.cpu_side_ports

# CPU local memory — direct connection, does NOT cross UCIe
system.cpu_mem_ctrl = MemCtrl()
if MEM_TYPE == "DDR3":
    system.cpu_mem_ctrl.dram = DDR3_1600_8x8()
else:
    system.cpu_mem_ctrl.dram = DDR4_2400_16x4()
system.cpu_mem_ctrl.dram.range = AddrRange('0', size=CPU_MEM_SIZE)
system.cpu_membus.mem_side_ports = system.cpu_mem_ctrl.port

# ── Chiplet 1: Accelerator side ───────────────────────────────────────────────
# Hosts the Conv3D workload data (IFV, weights, OFV) in HBM.
system.acc_membus = SystemXBar(max_routing_table_size=100_000)
system.acc_mem_ctrl = MemCtrl()
if MEM_TYPE == "HBM":
    system.acc_mem_ctrl.dram = HBM_2000_4H_1x64()
else:
    system.acc_mem_ctrl.dram = DDR4_2400_8x8()
system.acc_mem_ctrl.dram.range = AddrRange(str(ACC_MEM_START), size=ACC_MEM_SIZE)
system.acc_membus.mem_side_ports = system.acc_mem_ctrl.port

# ── UCIe Link pair ────────────────────────────────────────────────────────────
# Gem5 routes by AddrRange: only 8–16 GiB traffic goes to ucie_link_0.rx_port
# because the local DDR covers 0–8 GiB exclusively.
ucie_params = dict(
    retry_timeout='25ns',
    error_rate   = 1e-10,   # per-lane BER = 10^-10 (paper setting)
    data_rate    = 4.0,     # GT/s per lane
    num_lanes    = 16,
    phys_delay   = '2ns',
    credit_pool  = 32,
)
system.ucie_link_0 = UcieLink(**ucie_params)
system.cpu_membus.mem_side_ports = system.ucie_link_0.rx_port

system.ucie_link_1 = UcieLink(**ucie_params)
system.ucie_link_1.tx_port = system.acc_membus.cpu_side_ports
system.ucie_link_0.tx_port = system.ucie_link_1.rx_port

# ── Run ───────────────────────────────────────────────────────────────────────
root = Root(full_system=False, system=system)
m5.instantiate()

print(f"\n{'='*60}")
print(f"  UCIe FFT (CPU) + Conv3D (Accelerator) — {MEM_TYPE}")
print(f"{'='*60}")
print(f"  CPU workload : FFT 256-point complex (2KB data)")
print(f"                 Stages: seq-read → bit-reversal → twiddle → UCIe write")
print(f"  ACC workload : Conv3D 16×16×16 volume, 3×3×3 kernel, 8 filters")
print(f"                 Stages: UCIe read IFV → (compute) → UCIe read OFV")
print(f"  CPU memory   : {MEM_TYPE} (local, 0–8 GiB)")
print(f"  ACC memory   : {'HBM' if MEM_TYPE == 'HBM' else 'DDR4'} (remote, 8–16 GiB)")
print(f"  UCIe link    : 16 lanes × 4 GT/s  |  BER=1e-10  |  2ns phys delay")
print(f"{'='*60}\n")

exit_event = m5.simulate()
print(f"\nSimulation ended @ tick {m5.curTick()}: {exit_event.getCause()}")
print("\nKey stats (m5out/stats.txt):")
print("  system.ucie_link_0.UcieStats.throughputGbps")
print("  system.ucie_link_0.UcieStats.totalRetransmissions")
print("  system.ucie_link_0.UcieStats.payloadEfficiency")
print("  system.ucie_link_0.UcieStats.totalCrcErrors")
print("  system.ucie_link_0.UcieStats.tlpLatency::mean  (÷1000 = ns)")
