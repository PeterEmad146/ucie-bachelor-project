# generate_gemm_trace.py
# Generates a synthetic gem5 trace for a small GEMM workload

def generate_trace(filename, num_operations, base_addr):
    with open(filename, 'w') as f:
        tick = 0
        addr = base_addr
        
        for _ in range(num_operations):
            # Phase 1: Read Input Matrix A (64 bytes)
            f.write(f"r {addr} 64 {tick} 0\n")
            tick += 2000 # Wait 2ns
            
            # Phase 2: Read Weight Matrix B (64 bytes)
            f.write(f"r {addr + 1024} 64 {tick} 0\n")
            tick += 10000 # Compute delay (10ns for MAC operations)
            
            # Phase 3: Write Output Matrix C (64 bytes)
            f.write(f"w {addr + 2048} 64 {tick} 0\n")
            tick += 5000 # Wait before next operation
            
            addr += 64

generate_trace("gemm_workload.trc", 1000, 0x10000000)
print("gemm_workload.trc generated successfully!")