#!/usr/bin/env python3
# -*- coding: UTF-8 -*-

"""
Script to visualize running PipelineRuns over time from benchmark-stats.csv
This is particularly useful for the results-api-burst-test scenario to show
the burst pattern (1 -> 300 -> 1 concurrency).
"""

import argparse
import csv
import sys
from datetime import datetime
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

def parse_args():
    parser = argparse.ArgumentParser(
        description="Plot running PipelineRuns over time from benchmark-stats.csv"
    )
    parser.add_argument(
        "--stats-file",
        default="artifacts/benchmark-stats.csv",
        help="Path to benchmark-stats.csv file (default: artifacts/benchmark-stats.csv)",
    )
    parser.add_argument(
        "--output",
        default="artifacts/running-pipelineruns-over-time.png",
        help="Output image file path (default: artifacts/running-pipelineruns-over-time.png)",
    )
    parser.add_argument(
        "--title",
        default="Running PipelineRuns Over Time",
        help="Chart title (default: Running PipelineRuns Over Time)",
    )
    parser.add_argument(
        "--show",
        action="store_true",
        help="Display the plot interactively (default: save to file)",
    )
    parser.add_argument(
        "--namespace",
        default=None,
        help="Filter by specific namespace (default: show all namespaces)",
    )
    return parser.parse_args()


def load_stats_csv(file_path):
    """Load benchmark-stats.csv and return as DataFrame"""
    if not Path(file_path).exists():
        print(f"ERROR: File not found: {file_path}")
        print("Make sure you've run the benchmark and the stats file exists.")
        sys.exit(1)

    try:
        df = pd.read_csv(file_path)
        print(f"Loaded {len(df)} rows from {file_path}")
        return df
    except Exception as e:
        print(f"ERROR: Failed to load CSV file: {e}")
        sys.exit(1)


def prepare_data(df, namespace_filter=None):
    """Prepare data for plotting"""
    # Filter by namespace if specified
    if namespace_filter:
        df = df[df['namespace'] == namespace_filter]
        if len(df) == 0:
            print(f"WARNING: No data found for namespace '{namespace_filter}'")
    
    # Convert monitoring_now to datetime
    df['timestamp'] = pd.to_datetime(df['monitoring_now'])
    
    # Group by timestamp and sum running PipelineRuns across namespaces
    # (if multiple namespaces, we want total running across all)
    if 'namespace' in df.columns:
        grouped = df.groupby('timestamp')['prs_running'].sum().reset_index()
    else:
        grouped = df[['timestamp', 'prs_running']].copy()
    
    # Sort by timestamp
    grouped = grouped.sort_values('timestamp')
    
    return grouped


def plot_running_pipelineruns(df, output_path, title, show=False):
    """Create the plot"""
    # Set up the figure
    plt.figure(figsize=(14, 8))
    
    # Plot the data
    plt.plot(df['timestamp'], df['prs_running'], 
             linewidth=2, marker='o', markersize=3, 
             color='#2E86AB', label='Running PipelineRuns')
    
    # Add fill under the curve for better visibility
    plt.fill_between(df['timestamp'], df['prs_running'], 
                     alpha=0.3, color='#2E86AB')
    
    # Formatting
    plt.xlabel('Time', fontsize=12, fontweight='bold')
    plt.ylabel('Number of Running PipelineRuns', fontsize=12, fontweight='bold')
    plt.title(title, fontsize=14, fontweight='bold', pad=20)
    plt.grid(True, alpha=0.3, linestyle='--')
    plt.legend(fontsize=11)
    
    # Format x-axis to show time nicely
    plt.gcf().autofmt_xdate()
    
    # Add statistics text box
    max_running = df['prs_running'].max()
    avg_running = df['prs_running'].mean()
    min_running = df['prs_running'].min()
    stats_text = f'Max: {max_running:.0f}\nAvg: {avg_running:.1f}\nMin: {min_running:.0f}'
    plt.text(0.02, 0.98, stats_text, 
             transform=plt.gca().transAxes,
             fontsize=10,
             verticalalignment='top',
             bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.5))
    
    # Tight layout for better appearance
    plt.tight_layout()
    
    # Save or show
    if show:
        plt.show()
    else:
        plt.savefig(output_path, dpi=300, bbox_inches='tight')
        print(f"Plot saved to: {output_path}")
    
    plt.close()


def main():
    args = parse_args()
    
    # Load data
    df = load_stats_csv(args.stats_file)
    
    # Check required columns
    required_cols = ['monitoring_now', 'prs_running']
    missing_cols = [col for col in required_cols if col not in df.columns]
    if missing_cols:
        print(f"ERROR: Missing required columns: {missing_cols}")
        print(f"Available columns: {list(df.columns)}")
        sys.exit(1)
    
    # Prepare data
    plot_df = prepare_data(df, args.namespace)
    
    if len(plot_df) == 0:
        print("ERROR: No data to plot")
        sys.exit(1)
    
    # Create plot
    plot_running_pipelineruns(plot_df, args.output, args.title, args.show)
    
    print(f"Successfully created plot with {len(plot_df)} data points")
    print(f"Time range: {plot_df['timestamp'].min()} to {plot_df['timestamp'].max()}")


if __name__ == "__main__":
    main()
