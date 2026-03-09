import m5
from m5.objects import *
import os

# 1. Create the System Root
system = System()

# 2. Set the Clock and Voltage Domain
system.clk_domain = SrcClockDomain()
system.clk_domain.clock = '2GHz'    # Standard CPU speed
system.clk_domain.voltage_domain = VoltageDomain()

system.ucie_clk_domain = SrcClockDomain(clock='800MHz', voltage_domain=system.clk_domain.voltage_domain)

# 3. Configure the Memory Space (Using 512MB for testing)
system.mem_mode = 'timing'
system.mem_ranges = [AddrRange('512MB')]

# 4. Create the CPU (A cycle-accurate Timing CPU)
# system.cpu = X86TimingSimpleCPU()
system.cpu = X86O3CPU()
# system.cpu = X86MinorCPU()


# Create L1 Caches to burst 64-Byte blocks across the UCIe link
system.cpu.icache = Cache(size='1kB', assoc=2, tag_latency=2, data_latency=2, response_latency=2, mshrs=4, tgts_per_mshr=20)
system.cpu.dcache = Cache(size='1kB', assoc=2, tag_latency=2, data_latency=2, response_latency=2, mshrs=4, tgts_per_mshr=20)

# --- NEW: Attach a Hardware Prefetcher to aggressively flood the UCIe link! ---
system.cpu.dcache.prefetcher = StridePrefetcher(degree=8)

# 5. Create a System Crossbar (Bus) to merge CPU Instruction & Data ports
system.cpu_bus = SystemXBar()

# Wire the CPU to the Caches
system.cpu.icache.cpu_side = system.cpu.icache_port
system.cpu.dcache.cpu_side = system.cpu.dcache_port

# Wire the Caches to the Bus
system.cpu.icache.mem_side = system.cpu_bus.cpu_side_ports
system.cpu.dcache.mem_side = system.cpu_bus.cpu_side_ports

# 6. INSTANTIATE CUSTOM UCIE CHIPLETS
# Setting a realistic 1% error rate for standard operation
system.chiplet_A = UcieLink(clk_domain=system.ucie_clk_domain, link_latency='2ns', retry_buffer_capacity='32kB', flit_size=256, error_rate=0.0)
system.chiplet_B = UcieLink(clk_domain=system.ucie_clk_domain, link_latency='2ns', retry_buffer_capacity='32kB', flit_size=256, error_rate=0.0)

# 7. WIRE THE INTERCONNECT PIPELINE
# CPU Bus -> Chiplet A (TX) -> Chiplet B (RX) -> Memory
system.cpu_bus.mem_side_ports = system.chiplet_A.rx_port
system.chiplet_A.tx_port = system.chiplet_B.rx_port

# 8. Configure the DDR4 Memory Controller (Matching the reference paper)
system.mem_ctrl = MemCtrl()
system.mem_ctrl.dram = DDR4_2400_16x4()
system.mem_ctrl.dram.range = system.mem_ranges[0]

# Tell the DRAM it is a 512MB stick to stop the warning
system.mem_ctrl.dram.device_size = '512MB'

# Wire Chiplet B to the Memory Controller
system.chiplet_B.tx_port = system.mem_ctrl.port

# Wire up the system port (required for gem5 memory initialization)
system.system_port = system.cpu_bus.cpu_side_ports

# ==========================================================
# 9. SET UP THE WORKLOAD (The actual program to run)
# ==========================================================

# We will use the standard 'hello' binary compiled for X86 that comes with gem5
binary_0 = 'tests/test-progs/hello/bin/x86/linux/hello'
binary_1 = 'configs/example/ucie_sys/workload/gemm_test'

# Check if the binary exists
if not os.path.exists(binary_1):
    print(f"Error: Could not find the binary at {binary_1}")
    print("Please ensure you are running this from the gem5 root directory.")
    sys.exit(1)

# Create a process for the binary
process = Process()
process.cmd = [binary_1]

# Assign the workload to the CPU
system.cpu.workload = process
system.cpu.createThreads()

# X86 explicitly requires an interrupt controller
system.cpu.createInterruptController()
system.cpu.interrupts[0].pio = system.cpu_bus.mem_side_ports
system.cpu.interrupts[0].int_requestor = system.cpu_bus.cpu_side_ports
system.cpu.interrupts[0].int_responder = system.cpu_bus.mem_side_ports

system.workload = SEWorkload.init_compatible(binary_1)

# ==========================================================
# 10. RUN THE SIMULATION
# ==========================================================
root = Root(full_system=False, system=system)
m5.instantiate()

print ("Beginning real CPU workload simulation across the UCIe link!")
exit_event = m5.simulate()

print(f"Exiting @ tick {m5.curTick()} because {exit_event.getCause()}")