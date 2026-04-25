import m5
from m5.objects import *
import os

system = System()
system.clk_domain = SrcClockDomain(clock='1GHz', voltage_domain=VoltageDomain())
system.mem_mode = 'timing'
system.cache_line_size = 64 
system.mem_ranges = [AddrRange('16GiB')]

# --- CHIPLET 0 (CPU Side) ---
system.cpu = X86TimingSimpleCPU()
system.membus = SystemXBar() 

system.cpu.icache_port = system.membus.cpu_side_ports
system.cpu.dcache_port = system.membus.cpu_side_ports

# Updated to only use our optimized parameters
system.ucie_link_0 = UcieLink(
    retry_timeout='25ns', 
    error_rate=0.0
)

# Wire CPU out to Link 0 in
system.membus.mem_side_ports = system.ucie_link_0.rx_port


# --- CHIPLET 1 (Memory Side) ---
# Updated to only use our optimized parameters
system.ucie_link_1 = UcieLink(
    retry_timeout='25ns', 
    error_rate=0.0
)

system.mem_ctrl = MemCtrl()
system.mem_ctrl.dram = DDR4_2400_8x8()
system.mem_ctrl.dram.range = system.mem_ranges[0]

# Wire Link 1 out to Memory in
system.ucie_link_1.tx_port = system.mem_ctrl.port


# --- DIE-TO-DIE INTERFACE ---
# Wire Link 0 to Link 1 across the physical boundary
system.ucie_link_0.tx_port = system.ucie_link_1.rx_port


# Required x86 System Port Connections
system.cpu.createInterruptController()
system.cpu.interrupts[0].pio = system.membus.mem_side_ports
system.cpu.interrupts[0].int_requestor = system.membus.cpu_side_ports
system.cpu.interrupts[0].int_responder = system.membus.mem_side_ports
system.system_port = system.membus.cpu_side_ports

process = Process()
binary_path = 'tests/test-progs/hello/bin/x86/linux/hello'

if not os.path.exists(binary_path):
    print(f"Error: Could not find the gem5 hello binary at {binary_path}")
    exit(1)

process.executable = binary_path
process.cmd = [binary_path]
system.workload = SEWorkload.init_compatible(binary_path)
system.cpu.workload = process
system.cpu.createThreads()

root = Root(full_system=False, system=system)
m5.instantiate()

print("Starting UCIe Split CPU-Memory Test...")
exit_event = m5.simulate()
print(f"Exiting @ tick {m5.curTick()} because {exit_event.getCause()}")