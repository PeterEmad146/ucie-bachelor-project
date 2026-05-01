import m5
from m5.objects import *
import os

# -----------------------------------------------------------------------
# 1. GENERATE THE TRACE (This runs first and writes the .cfg file)
# -----------------------------------------------------------------------
with open("gemm_offload.cfg", "w") as f:
    HBM_BASE = 8589934592 # 8 GiB 
    A_BASE = HBM_BASE
    B_BASE = HBM_BASE + 1048576
    C_BASE = HBM_BASE + 2097152

    # Throttled to 40000 ticks (40ns) to respect the 32ns physical wire limit
    f.write(f"STATE 0 5000000 LINEAR 100 {A_BASE} {A_BASE + 65536} 64 40000 40000 0\n")
    f.write(f"STATE 1 5000000 LINEAR 100 {B_BASE} {B_BASE + 65536} 64 40000 40000 0\n")
    f.write("STATE 2 1000000 IDLE\n")
    f.write(f"STATE 3 5000000 LINEAR 0 {C_BASE} {C_BASE + 65536} 64 40000 40000 0\n")
    
    # EXIT state to naturally end the simulation
    f.write("STATE 4 1000 EXIT\n")

    f.write("INIT 0\n")
    f.write("TRANSITION 0 1 1\n")
    f.write("TRANSITION 1 2 1\n")
    f.write("TRANSITION 2 3 1\n")
    f.write("TRANSITION 3 4 1\n")
    f.write("TRANSITION 4 4 1\n")

# -----------------------------------------------------------------------
# 2. BUILD THE SYSTEM
# -----------------------------------------------------------------------
system = System()
system.clk_domain = SrcClockDomain(clock='1GHz', voltage_domain=VoltageDomain())
system.mem_mode = 'timing'
system.cache_line_size = 64 

# --- CHIPLET 0 (CPU Side) ---
# Read the trace we just generated above!
system.cpu_traffic = TrafficGen(config_file="gemm_offload.cfg")
# Expanded routing table to prevent crossbar tracking crashes
system.cpu_membus = SystemXBar(max_routing_table_size=100000)
system.cpu_traffic.port = system.cpu_membus.cpu_side_ports

# CPU Local Memory (DDR4)
system.cpu_mem_ctrl = MemCtrl()
system.cpu_mem_ctrl.dram = DDR4_2400_16x4() 
system.cpu_mem_ctrl.dram.range = AddrRange('0', size='8GiB')
system.cpu_membus.mem_side_ports = system.cpu_mem_ctrl.port

# --- CHIPLET 1 (Accelerator Side) ---
system.acc_membus = SystemXBar(max_routing_table_size=100000)

# Accelerator Local Memory (HBM)
system.acc_mem_ctrl = MemCtrl()
system.acc_mem_ctrl.dram = HBM_2000_4H_1x64()
system.acc_mem_ctrl.dram.range = AddrRange('8GiB', size='8GiB') 
system.acc_membus.mem_side_ports = system.acc_mem_ctrl.port

# --- THE UCIE INTERCONNECT ---
system.ucie_link_0 = UcieLink(retry_timeout='25ns', error_rate=0.0)
system.cpu_membus.mem_side_ports = system.ucie_link_0.rx_port

system.ucie_link_1 = UcieLink(retry_timeout='25ns', error_rate=0.0)
system.ucie_link_1.tx_port = system.acc_membus.cpu_side_ports

# Physical Die-to-Die connection
system.ucie_link_0.tx_port = system.ucie_link_1.rx_port

# -----------------------------------------------------------------------
# 3. RUN THE SIMULATION
# -----------------------------------------------------------------------
root = Root(full_system=False, system=system)
m5.instantiate()

print("Starting CPU-to-Accelerator Offload Simulation (Throttled for physical wire limits)...")

# NO LIMIT HERE. The EXIT state in the config will tell gem5 when to stop.
exit_event = m5.simulate() 

print(f"Exiting @ tick {m5.curTick()} because {exit_event.getCause()}")