"""
Test 1: Latency Sweep — Table I Reproduction
=============================================
Sweeps all 10 TLP payload sizes from the paper's Table I and compares the
simulated latency (from the tlpLatency histogram) against the theoretical
formula:  t = t_tx + t_accumulation + t_physical

Paper configuration:
  - Clock  : 4 GHz  →  accumulation = 16 - 1/(2×4) = 15.875 ns
  - BW     : 64 Gb/s (16 lanes × 4 GT/s)
  - t_phys : 2 ns (fixed)
  - Error  : 0 (clean channel, no retransmissions)

Run as:
    build/X86/gem5.opt configs/example/ucie_sys/latency_validation.py

Stats to read from m5out/stats.txt:
    system.ucie_link_0.UcieStats.tlpLatency::mean   (in ps, divide by 1000 for ns)
"""

import m5
from m5.objects import *
import os
import sys

# ── Parameters ────────────────────────────────────────────────────────────────
# Table I payload sizes (bytes).  The C++ model adds TLP_HEADER_BYTES (16)
# internally, so we pass the raw data size here.
TABLE_I_SIZES = [16, 48, 80, 112, 240, 496, 880, 1008, 2032, 4080]

# Pick a single size for one run (override with --size= on the command line).
# To reproduce the full table, loop over TABLE_I_SIZES in a shell script.
DATA_SIZE = int(os.environ.get("UCIE_DATA_SIZE", 16))  # default 48 B → 64 B TLP

# UCIe physical parameters (match the UcieLink SimObject params below)
DATA_RATE    = 4.0    # GT/s per lane
NUM_LANES    = 16     # Standard UCIe package

# UCIe link clock = data_rate / num_lanes (GHz) — used in the accumulation formula.
# At 4 GT/s / 16 lanes = 0.25 GHz → t_acc = 16 - 1/(2×0.25) = 14 ns exactly.
CLOCK_GHZ    = DATA_RATE / NUM_LANES
BW_GBps      = (DATA_RATE * NUM_LANES) / 8.0   # bytes/ns = 8 GB/s

tlp_size_bytes = DATA_SIZE + 16
first_chunk    = min(tlp_size_bytes, 236)
t_tx_ns        = first_chunk / BW_GBps
t_acc_ns       = 16.0 - 1.0 / (2.0 * CLOCK_GHZ)
t_theoretical  = t_tx_ns + t_acc_ns   # no separate t_physical (absorbed into t_acc at 0.25GHz)

print(f"\n{'='*60}")
print(f"  UCIe Latency Validation — Table I")
print(f"{'='*60}")
print(f"  Payload  : {DATA_SIZE} B  |  TLP: {tlp_size_bytes} B")
print(f"  f_link   : {CLOCK_GHZ} GHz  ({DATA_RATE}GT/s / {NUM_LANES} lanes)")
print(f"  t_tx     : {t_tx_ns:.3f} ns  ({first_chunk}B / {BW_GBps}GB/s)")
print(f"  t_acc    : {t_acc_ns:.3f} ns  (16 - 1/(2×{CLOCK_GHZ}))")
print(f"  THEORY   : {t_theoretical:.3f} ns")
print(f"{'='*60}\n")

# ── TrafficGen config ─────────────────────────────────────────────────────────
# Send one packet every 100 µs (100,000,000 ps) so packets never queue.
# This isolates each packet's latency cleanly.
cfg_file = f"/tmp/latency_test_{DATA_SIZE}B.cfg"
with open(cfg_file, "w") as f:
    # LINEAR: read=0(write), start=0, end=512MiB, size=DATA_SIZE,
    #         min_period=100µs, max_period=100µs, data_limit=0
    f.write(
        f"STATE 0 1000000000000 LINEAR 0 0 536870912 "
        f"{DATA_SIZE} 100000000 100000000 0\n"
    )
    f.write("INIT 0\n")
    f.write("TRANSITION 0 0 1\n")

# ── System ────────────────────────────────────────────────────────────────────
system = System()

# 4 GHz is the gem5 SIMULATION clock (event scheduling granularity).
# It is SEPARATE from the UCIe link clock (0.25 GHz = DATA_RATE/NUM_LANES)
# which is used inside the C++ latency formula.
system.clk_domain = SrcClockDomain(
    clock='1GHz', voltage_domain=VoltageDomain()
)
system.mem_mode    = 'timing'
# cache_line_size must be >= the largest packet we send.
system.cache_line_size = 4096
system.mem_ranges  = [AddrRange('16GiB')]

# ── Chiplet A: Traffic source ─────────────────────────────────────────────────
system.tgen = TrafficGen(config_file=cfg_file)

system.ucie_link_0 = UcieLink(
    retry_timeout= '25ns',
    error_rate   = 0.0,           # clean channel for baseline measurement
    data_rate    = 4.0,           # GT/s per lane
    num_lanes    = 16,            # Standard UCIe
    phys_delay   = '2ns',         # 1 ns Adapter + 1 ns Electrical PHY
    credit_pool  = 32,
)
system.tgen.port = system.ucie_link_0.rx_port

# ── Chiplet B: Memory sink ────────────────────────────────────────────────────
system.ucie_link_1 = UcieLink(
    retry_timeout= '25ns',
    error_rate   = 0.0,
    data_rate    = 4.0,
    num_lanes    = 16,
    phys_delay   = '2ns',
    credit_pool  = 32,
)

system.mem_ctrl      = MemCtrl()
system.mem_ctrl.dram = DDR4_2400_8x8()
system.mem_ctrl.dram.range = system.mem_ranges[0]
system.ucie_link_1.tx_port = system.mem_ctrl.port

# ── Die-to-Die physical connection ────────────────────────────────────────────
system.ucie_link_0.tx_port = system.ucie_link_1.rx_port

# ── Run ───────────────────────────────────────────────────────────────────────
root = Root(full_system=False, system=system)
m5.instantiate()

# Run long enough to measure at least ~30 isolated packets.
# 30 × 100 µs = 3 ms = 3,000,000,000 ps
SIM_TICKS = 3_000_000_000
exit_event = m5.simulate(SIM_TICKS)

print(f"\nSimulation ended @ tick {m5.curTick()}: {exit_event.getCause()}")
print(f"\nTo get simulated latency, check:")
print(f"  m5out/stats.txt → system.ucie_link_0.UcieStats.tlpLatency::mean")
print(f"  (divide ps value by 1000 to get ns, compare to theoretical {t_theoretical:.4f} ns)")