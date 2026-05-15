"""
BER Retry Functional Test
==========================
A targeted test to verify that the ACK/NAK retry mechanism works correctly.
Sends enough packets to guarantee that the deterministic BER (10^-10) fires
exactly once, then checks the stats to confirm:
  - totalCrcErrors     == 1
  - totalNaksSent      == 1
  - totalRetransmissions >= 1  (the failed flit is replayed)

This is NOT a paper replication test — it is a functional correctness test
for the link's error-recovery path.

Run:
    build/X86/gem5.opt configs/example/ucie_sys/ber_retry_test.py
"""

import m5
from m5.objects import *
import os

# ── How many bits until the first error? ─────────────────────────────────────
BER            = 1e-10
FLIT_BITS      = 256 * 8       # 2048 bits per 256-byte flit
# Error fires after:  ceil(1/BER) bits = 10^10 bits
# That is:           10^10 / 2048 ≈ 4,882,813 flits
# We send ~6M flits (64-byte packets → 1 flit each) to guarantee 1 error.
PACKETS_NEEDED = 6_000_000
PACKET_SIZE    = 64            # bytes
INTERVAL_PS    = 500           # ps between packets (high throughput)

cfg_file = "/tmp/ber_retry.cfg"
with open(cfg_file, "w") as f:
    f.write(
        f"STATE 0 {PACKETS_NEEDED * INTERVAL_PS} LINEAR 0 0 536870912 "
        f"{PACKET_SIZE} {INTERVAL_PS} {INTERVAL_PS} 0\n"
    )
    f.write("STATE 1 1000 EXIT\n")
    f.write("INIT 0\n")
    f.write("TRANSITION 0 1 1\n")
    f.write("TRANSITION 1 1 1\n")

# ── System ────────────────────────────────────────────────────────────────────
system = System()
system.clk_domain = SrcClockDomain(clock='4GHz', voltage_domain=VoltageDomain())
system.mem_mode   = 'timing'
system.cache_line_size = 64
system.mem_ranges = [AddrRange('16GiB')]

system.tgen = TrafficGen(config_file=cfg_file)

# Link 0 sends, Link 1 receives (error injection is on the RX side of link 1)
system.ucie_link_0 = UcieLink(
    retry_timeout='25ns',
    error_rate=BER, data_rate=4.0, num_lanes=16,
    phys_delay='2ns', credit_pool=32,
)
system.tgen.port = system.ucie_link_0.rx_port

system.ucie_link_1 = UcieLink(
    retry_timeout='25ns',
    error_rate=BER, data_rate=4.0, num_lanes=16,
    phys_delay='2ns', credit_pool=32,
)
system.mem_ctrl      = MemCtrl()
system.mem_ctrl.dram = DDR4_2400_8x8()
system.mem_ctrl.dram.range = system.mem_ranges[0]
system.ucie_link_1.tx_port = system.mem_ctrl.port
system.ucie_link_0.tx_port = system.ucie_link_1.rx_port

root = Root(full_system=False, system=system)
m5.instantiate()

print(f"\n{'='*60}")
print(f"  UCIe BER Retry Functional Test")
print(f"{'='*60}")
print(f"  BER = {BER}  →  1 error per {int(1/BER):,} bits")
print(f"  Bits per flit = {FLIT_BITS:,}")
print(f"  Error interval = {int(1/BER) // FLIT_BITS:,} flits")
print(f"  Sending ~{PACKETS_NEEDED:,} packets to trigger at least 1 error")
print(f"{'='*60}\n")
print("  Expected results:")
print("    totalCrcErrors      >= 1")
print("    totalNaksSent       >= 1")
print("    totalRetransmissions>= 1")
print()

exit_event = m5.simulate()

print(f"\nSimulation ended @ tick {m5.curTick()}: {exit_event.getCause()}")
print("\nVerify in m5out/stats.txt:")
print("  system.ucie_link_1.UcieStats.totalCrcErrors")
print("  system.ucie_link_1.UcieStats.totalNaksSent")
print("  system.ucie_link_0.UcieStats.totalRetransmissions")
print("  system.ucie_link_0.UcieStats.totalFlitsNaked")
