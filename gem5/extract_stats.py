#!/usr/bin/env python3
import sys
import os

def parse_stat(filepath, stat_name):
    if not os.path.exists(filepath):
        return "N/A"
    
    with open(filepath, 'r') as f:
        for line in f:
            if line.startswith(stat_name):
                parts = line.strip().split()
                if len(parts) >= 2:
                    return parts[1]
    return "N/A"

def main():
    workloads = ["gemm", "conv2d", "fft", "conv3d"]
    interconnects = ["mono", "pcie", "ucie"]
    memories = ["DDR3", "DDR4", "HBM"]

    stats_to_extract = {
        "avgReadLatency": "system.cpu_traffic.avgReadLatency",
        "avgWriteLatency": "system.cpu_traffic.avgWriteLatency",
        "avgMemAccLat": "system.acc_mem_ctrl.dram.avgMemAccLat",
        "writeBW": "system.cpu_traffic.writeBW"
    }

    results_dir = "m5out_results"
    output_file = "summary_stats.txt"

    with open(output_file, 'w') as out:
        for wl in workloads:
            out.write("=" * 90 + "\n")
            out.write(f" WORKLOAD: {wl.upper()}\n")
            out.write("=" * 90 + "\n")
            
            # Table Header
            header = f"{'Memory':<10} | {'Statistic':<25} | {'Monolithic':<15} | {'PCIe':<15} | {'UCIe':<15}"
            out.write(header + "\n")
            out.write("-" * len(header) + "\n")
            
            for mem in memories:
                first_stat = True
                for short_name, full_name in stats_to_extract.items():
                    
                    # Get the value for each interconnect
                    vals = []
                    for ic in interconnects:
                        # Construct the path to the stats.txt file for this combination
                        file_path = os.path.join(results_dir, f"{ic}_{wl}_{mem}", "stats.txt")
                        vals.append(parse_stat(file_path, full_name))
                    
                    mem_label = mem if first_stat else ""
                    first_stat = False
                    
                    row = f"{mem_label:<10} | {short_name:<25} | {vals[0]:<15} | {vals[1]:<15} | {vals[2]:<15}"
                    out.write(row + "\n")
                    
                out.write("-" * len(header) + "\n")
            
            out.write("\n\n")

    print(f"Extraction complete. Results saved to {output_file}")

if __name__ == "__main__":
    main()
