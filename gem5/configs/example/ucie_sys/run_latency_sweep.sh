#!/bin/bash

# Array of TLP sizes to test (32B to 4096B)
TLP_SIZES=(32 64 128 256 512 1024 2048 4096)

# Using 1M iterations as per the paper, but ensure your .py script 
# uses the 100ns period fix to avoid PC crashes!
ITERATIONS=1000000

echo "Starting UCIe Link Latency Validation Sweep..."
echo "Simulations are running silently. This may take a few minutes."

for size in "${TLP_SIZES[@]}"; do
    echo " -> Simulating ${size}B..."
    
    # 1. --outdir creates the folder for stats.txt
    # 2. > /dev/null discards standard output
    # 3. 2>&1 discards all warnings/errors
    build/X86/gem5.opt \
        --outdir=m5out/ucie_latency_${size}B \
        configs/example/ucie_sys/dual_chiplet_test.py \
        --tlp_size=$size \
        --iterations=$ITERATIONS > /dev/null 2>&1
        
done

echo "=========================================================="
echo "All simulations complete."
echo "You can now run: python3 results/ucie_performance_report.py"
echo "=========================================================="