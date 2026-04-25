import re
import matplotlib.pyplot as plt
import pandas as pd
import os

def parse_stats(file_path):
    stats = {0: {}, 1: {}}
    
    if not os.path.exists(file_path):
        print(f"Error: {file_path} not found.")
        return None

    with open(file_path, "r") as f:
        for line in f:
            # Look specifically for our custom UcieStats group
            match = re.search(r'system\.ucie_link_(\d)\.UcieStats\.(\w+)\s+([\d\.nan]+)', line)
            if match:
                chiplet_id = int(match.group(1))
                metric = match.group(2)
                val_str = match.group(3)
                
                # Handle gem5's 'nan' outputs for empty ratios
                val = float(val_str) if val_str != 'nan' else 0.0
                stats[chiplet_id][metric] = val
                
    return stats

def generate_report(stats):
    # Extract Sender (0) and Receiver (1) Metrics
    tlps_sent = stats[0].get('totalTLPsSent', 0)
    flits_sent = stats[0].get('totalFlitsSent', 0)
    payload_bytes = stats[0].get('totalPayloadBytes', 0)
    padding_bytes = stats[0].get('totalPaddingBytes', 0)
    
    crc_errors = stats[1].get('totalCrcErrors', 0)
    retransmissions = stats[0].get('totalRetransmissions', 0)
    efficiency = stats[0].get('payloadEfficiency', 0) * 100

    # Create Visualizations
    fig, axs = plt.subplots(1, 3, figsize=(16, 6))

    # 1. Accumulation
    bars1 = axs[0].bar(['Original TLPs', 'Packed Flits'], [tlps_sent, flits_sent], color=['#3498db', '#e74c3c'])
    axs[0].set_title('Data Accumulation & Segmentation', fontsize=14, pad=15)
    axs[0].set_ylabel('Count', fontsize=12)
    for bar in bars1:
        yval = bar.get_height()
        axs[0].text(bar.get_x() + bar.get_width()/2, yval + (yval*0.02), int(yval), ha='center', va='bottom', fontweight='bold')

    # 2. Efficiency
    if payload_bytes > 0:
        axs[1].pie([payload_bytes, padding_bytes], labels=['Payload (Real Data)', 'Padding (Wasted)'], 
                   autopct='%1.1f%%', colors=['#2ecc71', '#95a5a6'], startangle=90, explode=(0.1, 0), shadow=True)
    axs[1].set_title(f'UCIe Payload Efficiency ({efficiency:.1f}%)', fontsize=14, pad=15)

    # 3. Retransmissions
    bars3 = axs[2].bar(['CRC Errors\n(Drops)', 'Total Retransmissions\n(Go-Back-N Window)'], 
                       [crc_errors, retransmissions], color=['#f39c12', '#c0392b'])
    axs[2].set_title('Protocol Error Recovery', fontsize=14, pad=15)
    axs[2].set_ylabel('Count', fontsize=12)
    for bar in bars3:
        yval = bar.get_height()
        axs[2].text(bar.get_x() + bar.get_width()/2, yval + (yval*0.02), int(yval), ha='center', va='bottom', fontweight='bold')

    plt.tight_layout()
    plt.savefig('ucie_performance_analysis.png', dpi=300, bbox_inches='tight')
    print("✅ Generated chart: ucie_performance_analysis.png")

    # Export CSV Data
    penalty = (retransmissions / crc_errors) if crc_errors > 0 else 0
    df_export = pd.DataFrame([
        {"Metric": "Total TLPs Packed", "Value": tlps_sent, "Unit": "Count"},
        {"Metric": "Total Flits Sent", "Value": flits_sent, "Unit": "Count"},
        {"Metric": "Payload Efficiency", "Value": f"{efficiency:.2f}%", "Unit": "Percentage"},
        {"Metric": "CRC Errors (Drops)", "Value": crc_errors, "Unit": "Count"},
        {"Metric": "Retransmitted Flits", "Value": retransmissions, "Unit": "Count"},
        {"Metric": "Go-Back-N Penalty Multiplier", "Value": f"{penalty:.1f}x", "Unit": "Ratio"}
    ])
    df_export.to_csv('ucie_extracted_metrics.csv', index=False)
    print("✅ Generated summary: ucie_extracted_metrics.csv")

if __name__ == "__main__":
    stats_data = parse_stats("trafficgen_stats.txt")
    if stats_data:
        generate_report(stats_data)