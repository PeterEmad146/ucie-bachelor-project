#!/bin/bash

# Array of TLP sizes to test (32B to 4096B)
TLP_SIZES=(32 64 128 256 512 1024 2048 4096)

# The paper averages over 1,000,000 iterations 
ITERATIONS=1000000

echo "Starting UCIe Link Latency Validation Sweep..."

for size in "${TLP_SIZES[@]}"; do
    echo "======================================"
    echo "Testing TLP Size: ${size}B"
    echo "======================================"
    
    # Run the gem5 script and output stats to a specific directory
    build/X86/gem5.opt \
        --outdir=m5out/ucie_latency_${size}B \
        configs/example/ucie_sys/dual_chiplet_test.py \
        --tlp_size=$size \
        --iterations=$ITERATIONS
        
    echo "Done with ${size}B. Stats saved to m5out/ucie_latency_${size}B/stats.txt"
done

echo "All simulations complete. Check stats files to calculate average latency."