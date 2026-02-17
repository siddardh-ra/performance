#!/bin/bash

# Quick helper script to visualize the burst pattern from results-api-burst-test scenario

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$SCRIPT_DIR/../artifacts}"
STATS_FILE="${STATS_FILE:-$ARTIFACTS_DIR/benchmark-stats.csv}"
OUTPUT_FILE="${OUTPUT_FILE:-$ARTIFACTS_DIR/running-pipelineruns-over-time.png}"

if [ ! -f "$STATS_FILE" ]; then
    echo "ERROR: Stats file not found: $STATS_FILE"
    echo ""
    echo "Make sure you've run the benchmark test first."
    echo "The stats file should be generated at: artifacts/benchmark-stats.csv"
    exit 1
fi

echo "Generating visualization of running PipelineRuns over time..."
echo "Input:  $STATS_FILE"
echo "Output: $OUTPUT_FILE"
echo ""

python3 "$SCRIPT_DIR/plot-running-pipelineruns.py" \
    --stats-file "$STATS_FILE" \
    --output "$OUTPUT_FILE" \
    --title "Results API Burst Test - Running PipelineRuns Over Time" \
    "$@"

echo ""
echo "✓ Visualization complete!"
echo "Open the image to see the burst pattern: $OUTPUT_FILE"
