import m5
from m5.objects import *
import os

# -----------------------------------------------------------------------
# 1. GENERATE THE CONV2D TRACE (Mimicking a sliding window CNN)
# -----------------------------------------------------------------------
with open("conv2d_offload.cfg", "w") as f:
    HBM_BASE = 8589934592 # 8 GiB 
    IFM_BASE = HBM_BASE                # Input Feature Maps
    WEIGHT_BASE = HBM_BASE + 2097152   # CNN Kernels
    OFM_BASE = HBM_BASE + 4194304      # Output Feature Maps

    # STATE 0: Read IFM Window (Slightly larger bursts for image rows)
    # 40ns throttling maintained to prevent crossbar overflow
    f.write(f"STATE 0 5000000 LINEAR 100 {IFM_BASE} {IFM_BASE + 131072} 64 40000 40000 0\n")    
    
    # STATE 1: Read Kernel Weights (Smaller bursts, highly reused in CNNs)
    f.write(f"STATE 1 2000000 LINEAR 100 {WEIGHT_BASE} {WEIGHT_BASE + 32768} 64 40000 40000 0\n")
    
    # STATE 2: Compute IDLE (Longer delay to simulate 2D sliding window MACs)
    f.write("STATE 2 1500000 IDLE\n")
    
    # STATE 3: Write OFM Pixel (Writing the convolution result)
    f.write(f"STATE 3 5000000 LINEAR 0 {OFM_BASE} {OFM_BASE + 65536} 64 40000 40000 0\n")
    
    # STATE 4: EXIT to terminate cleanly
    f.write("STATE 4 1000 EXIT\n")

    f.write("INIT 0\n")
    f.write("TRANSITION 0 1 1\n")
    f.write("TRANSITION 1 2 1\n")
    f.write("TRANSITION 2 3 1\n")
    f.write("TRANSITION 3 4 1\n") # Loop terminates and exits
    f.write("TRANSITION 4 4 1\n") # Dummy transition to satisfy parser

# -----------------------------------------------------------------------
# 2. BUILD THE SYSTEM (Keep this exactly the same as before!)
# -----------------------------------------------------------------------
system = System()
system.clk_domain = SrcClockDomain(clock='1GHz', voltage_domain=VoltageDomain())
system.mem_mode = 'timing'
system.cache_line_size = 64 

# ... [KEEP ALL THE SYSTEM AND CROSSBAR CODE EXACTLY THE SAME] ...

# --- CHIPLET 0 (CPU Side) ---
# Update this line to read the new Conv2D config!
system.cpu_traffic = TrafficGen(config_file="conv2d_offload.cfg")
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

print("Starting CNN Conv2D Offload Simulation (Throttled for physical wire limits)...")
exit_event = m5.simulate() 
print(f"Exiting @ tick {m5.curTick()} because {exit_event.getCause()}")