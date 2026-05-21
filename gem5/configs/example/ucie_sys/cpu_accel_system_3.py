"""
Test 2c: CPU-Accelerator FFT Offload via UCIe
==============================================
Same dual-chiplet topology as cpu_accel_system.py but with an FFT
memory-access pattern instead of GEMM:
  - Read complex input array (local DDR, 0-8 GiB)
  - Bit-reversal permutation (local DDR, 0-8 GiB)
  - Twiddle factor lookup (local DDR, 0-8 GiB)
  - Write FFT result to Accelerator HBM (remote, over UCIe, 8-16 GiB)
  - Read output/other data from Accelerator HBM (remote, over UCIe, 8-16 GiB)

This models the FFT row of the paper's Table II.

Address map:
  CPU local DDR : 0 – 8 GiB    (direct, does NOT cross UCIe)
  Accelerator HBM: 8 – 16 GiB  (all UCIe-bound traffic goes here)

Run variants:
    UCIE_MEM_TYPE=DDR4  gem5.opt configs/example/ucie_sys/cpu_accel_system_3.py
    UCIE_MEM_TYPE=DDR3  gem5.opt configs/example/ucie_sys/cpu_accel_system_3.py
    UCIE_MEM_TYPE=HBM   gem5.opt configs/example/ucie_sys/cpu_accel_system_3.py
"""

import m5
from m5.objects import *
import os

MEM_TYPE  = os.environ.get("UCIE_MEM_TYPE", "DDR4").upper()
BURST     = 64          # bytes per request (cache-line sized)
THROTTLE  = 40_000      # ps between requests — prevents crossbar overflow

# ── Address map ───────────────────────────────────────────────────────────────
CPU_MEM_SIZE  = '8GiB'
ACC_MEM_START = 0x200000000   # 8 GiB
ACC_MEM_SIZE  = '8GiB'

FFT_N        = 256
FFT_ARRAY_B  = FFT_N * 8
TWIDDLE_B    = (FFT_N // 2) * 8
FFT_IN_BASE  = 0x1000
FFT_OUT_BASE = FFT_IN_BASE + FFT_ARRAY_B
TWIDDLE_BASE = FFT_OUT_BASE + FFT_ARRAY_B

IFV_BASE     = ACC_MEM_START
OFV_BASE     = ACC_MEM_START + 18 * 1024

# ── TrafficGen: FFT offload trace ────────────────────────────────────────────
cfg_file = f"/tmp/fft_{MEM_TYPE}.cfg"
with open(cfg_file, "w") as f:
    f.write(f"STATE 0 0 LINEAR 100 {FFT_IN_BASE} {FFT_IN_BASE + FFT_ARRAY_B} {BURST} {THROTTLE} {THROTTLE} {FFT_ARRAY_B}\n")
    f.write(f"STATE 1 0 RANDOM 100 {FFT_IN_BASE} {FFT_IN_BASE + FFT_ARRAY_B} {BURST} {THROTTLE} {THROTTLE} {FFT_ARRAY_B}\n")
    f.write(f"STATE 2 0 LINEAR 100 {TWIDDLE_BASE} {TWIDDLE_BASE + TWIDDLE_B} {BURST} {THROTTLE} {THROTTLE} {TWIDDLE_B}\n")
    f.write(f"STATE 3 0 LINEAR 0 {IFV_BASE} {IFV_BASE + FFT_ARRAY_B} {BURST} {THROTTLE} {THROTTLE} {FFT_ARRAY_B}\n")
    f.write(f"STATE 4 0 LINEAR 100 {OFV_BASE} {OFV_BASE + 65536} {BURST} {THROTTLE} {THROTTLE} 65536\n")
    f.write("STATE 5 1000 EXIT\n")
    f.write("INIT 0\n")
    for i in range(5):
        f.write(f"TRANSITION {i} {i+1} 1\n")
    f.write("TRANSITION 5 5 1\n")

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

# CPU local memory — connected DIRECTLY, does NOT go over UCIe
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

# ── UCIe Link pair ────────────────────────────────────────────────────────────
ucie_params = dict(
    retry_timeout='25ns', error_rate=1e-10,
    data_rate=4.0, num_lanes=16, phys_delay='2ns', credit_pool=32,
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
print(f"  UCIe CPU-Accelerator FFT Offload — {MEM_TYPE}")
print(f"{'='*60}")
print(f"  Workload   : FFT 256-point complex")
print(f"  CPU memory : {MEM_TYPE} (local, 0–8 GiB)")
print(f"  ACC memory : {'HBM' if MEM_TYPE == 'HBM' else 'DDR4'} (remote, 8–16 GiB)")
print(f"  UCIe link  : 16 lanes × 4 GT/s  |  BER=1e-10  |  2ns phys delay")
print(f"{'='*60}\n")

exit_event = m5.simulate()
print(f"\nSimulation ended @ tick {m5.curTick()}: {exit_event.getCause()}")
print("\nKey stats (m5out/stats.txt):")
print("  system.ucie_link_0.UcieStats.throughputGbps")
print("  system.ucie_link_0.UcieStats.totalRetransmissions")
print("  system.ucie_link_0.UcieStats.payloadEfficiency")
print("  system.ucie_link_0.UcieStats.totalCrcErrors")
print("  system.ucie_link_0.UcieStats.tlpLatency::mean  (÷1000 = ns)")
