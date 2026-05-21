#!/usr/bin/env python3
import sys
import os

def parse_stats(filepath):
    stats = {}
    if not os.path.exists(filepath):
        print(f"Error: File not found - {filepath}")
        return stats

    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            # Skip empty lines, header lines, and lines that are purely comments
            if not line or line.startswith('---') or line.startswith('#'):
                continue
            
            parts = line.split()
            if len(parts) >= 2:
                name = parts[0]
                value = parts[1]
                stats[name] = value
    return stats

def main():
    # Default to the 3 files requested by the user if no arguments are provided
    if len(sys.argv) < 2:
        files = [
            "m5out_results/mono_conv2d_DDR3/stats.txt",
            "m5out_results/pcie_conv2d_DDR3/stats.txt",
            "m5out_results/ucie_conv2d_DDR3/stats.txt"
        ]
    else:
        files = sys.argv[1:]

    print(f"Comparing stats across {len(files)} files:")
    for f in files:
        print(f" - {f}")
    print()

    all_stats = []
    for f in files:
        parsed = parse_stats(f)
        if not parsed:
            print("Aborting due to missing file(s).")
            sys.exit(1)
        all_stats.append(parsed)

    # Find common keys across all parsed stat files
    common_keys = set(all_stats[0].keys())
    for s in all_stats[1:]:
        common_keys = common_keys.intersection(set(s.keys()))

    # Print the table header
    header_names = ["Mono", "PCIe", "UCIe"] if len(files) == 3 else [f"File {i+1}" for i in range(len(files))]
    
    header = f"{'Stat Name':<60} | " + " | ".join([f"{name:<20}" for name in header_names])
    print(header)
    print("-" * len(header))

    # Print stats that have different values
    diff_count = 0
    for key in sorted(common_keys):
        values = [s[key] for s in all_stats]
        
        # If there is more than 1 unique value, then they are not all the same
        if len(set(values)) > 1:
            diff_count += 1
            row = f"{key:<60} | " + " | ".join([f"{val:<20}" for val in values])
            print(row)
            
    print("-" * len(header))
    print(f"Found {diff_count} common statistics with differing values.")

if __name__ == "__main__":
    main()
