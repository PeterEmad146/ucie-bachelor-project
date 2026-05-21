#!/bin/bash

# Move to the correct gem5 directory
cd /home/peter-emad/workspace/ucie-project/gem5 || exit 1

# Create a central directory to hold all the results
RESULTS_DIR="m5out_results"
echo "Creating output directory: $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

# Define the variants
MEMORIES=("DDR3" "DDR4" "HBM")
WORKLOADS=("gemm" "conv2d" "fft" "conv3d")

# Map workload to its corresponding UCIe script
declare -A UCIE_SCRIPTS=(
    ["gemm"]="configs/example/ucie_sys/cpu_accel_system.py"
    ["conv2d"]="configs/example/ucie_sys/cpu_accel_system_2.py"
    ["fft"]="configs/example/ucie_sys/cpu_accel_system_3.py"
    ["conv3d"]="configs/example/ucie_sys/cpu_accel_system_4.py"
)

TOTAL=36
CURRENT=1

echo "Starting $TOTAL simulations sequentially. This may take a few minutes..."
echo "Standard output will be logged to ${RESULTS_DIR}/<variant>_stdout.log"

for mem in "${MEMORIES[@]}"; do
    for wl in "${WORKLOADS[@]}"; do
        
        # 1. UCIe test
        script=${UCIE_SCRIPTS[$wl]}
        outdir="${RESULTS_DIR}/ucie_${wl}_${mem}"
        echo "[$CURRENT/$TOTAL] Running UCIe | Workload: $wl | Memory: $mem"
        UCIE_MEM_TYPE=$mem build/X86/gem5.opt -d "$outdir" "$script" > "${outdir}_stdout.log" 2>&1
        ((CURRENT++))

        # 2. PCIe test
        outdir="${RESULTS_DIR}/pcie_${wl}_${mem}"
        echo "[$CURRENT/$TOTAL] Running PCIe | Workload: $wl | Memory: $mem"
        WORKLOAD=$wl UCIE_MEM_TYPE=$mem build/X86/gem5.opt -d "$outdir" configs/example/ucie_sys/pcie_accel_system.py > "${outdir}_stdout.log" 2>&1
        ((CURRENT++))

        # 3. Monolithic test
        outdir="${RESULTS_DIR}/mono_${wl}_${mem}"
        echo "[$CURRENT/$TOTAL] Running Monolithic | Workload: $wl | Memory: $mem"
        WORKLOAD=$wl UCIE_MEM_TYPE=$mem build/X86/gem5.opt -d "$outdir" configs/example/ucie_sys/monolithic_accel_system.py > "${outdir}_stdout.log" 2>&1
        ((CURRENT++))

    done
done

echo "============================================================"
echo "All $TOTAL simulations completed successfully!"
echo "You can find all your stats.txt files grouped by test variant in:"
echo "/home/peter-emad/workspace/ucie-project/gem5/m5out_results/"
echo "============================================================"
