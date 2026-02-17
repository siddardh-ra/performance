#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Script to analyze discrepancy between expected PipelineRun count,
# Prometheus metrics, and Tekton Results API/DB counts

INPUT_FILE="${1:-artifacts/benchmark-tekton.json}"

if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: File not found: $INPUT_FILE"
    echo "Usage: $0 [path-to-benchmark-tekton.json]"
    exit 1
fi

echo "=== PipelineRun Count Discrepancy Analysis ==="
echo "Source file: $INPUT_FILE"
echo ""

# Extract expected count from test parameters
EXPECTED_COUNT=$(jq -r '.parameters.test.total // "unknown"' "$INPUT_FILE")
echo "1. Expected PipelineRun Count (TEST_TOTAL): $EXPECTED_COUNT"
echo ""

# Extract Results API count
RESULTS_API_COUNT=$(jq -r '.results.ResultsAPI.pipelineruns.count // "unknown"' "$INPUT_FILE")
RESULTS_API_TIMESTAMP=$(jq -r '.results.ResultsAPI.timestamp // "unknown"' "$INPUT_FILE")
echo "2. Tekton Results API Count (Console Dashboard): $RESULTS_API_COUNT"
echo "   Timestamp: $RESULTS_API_TIMESTAMP"
echo ""

# Extract Results DB counts
echo "3. Tekton Results DB Counts:"
DB_QUERIES=$(jq -r '.results.ResultsDB.queries // []' "$INPUT_FILE")
if [ "$DB_QUERIES" != "[]" ] && [ "$DB_QUERIES" != "null" ]; then
    # Find PipelineRun count from DB queries
    echo "$DB_QUERIES" | jq -r '.[] | select(.query | contains("PipelineRun")) | "   Query: \(.query)\n   Result: \(.result)"'
else
    echo "   No DB queries found"
fi
echo ""

# Extract Prometheus metrics (if available)
PROM_TOTAL=$(jq -r '.measurements.tekton_pipelines_controller_pipelinerun_total // "unknown"' "$INPUT_FILE" 2>/dev/null || echo "unknown")
echo "4. Prometheus Metrics:"
if [ "$PROM_TOTAL" != "unknown" ] && [ "$PROM_TOTAL" != "null" ]; then
    echo "   tekton_pipelines_controller_pipelinerun_total: $PROM_TOTAL"
else
    echo "   tekton_pipelines_controller_pipelinerun_total: Not available"
    echo "   (Add this metric to config/cluster_read_config.yaml to collect it)"
fi
echo ""

# Calculate discrepancies
echo "=== Discrepancy Analysis ==="

if [ "$EXPECTED_COUNT" != "unknown" ] && [ "$EXPECTED_COUNT" != "null" ] && [ "$RESULTS_API_COUNT" != "unknown" ] && [ "$RESULTS_API_COUNT" != "null" ]; then
    EXPECTED_NUM=$EXPECTED_COUNT
    RESULTS_NUM=$RESULTS_API_COUNT
    
    if [ "$EXPECTED_NUM" -gt 0 ] 2>/dev/null && [ "$RESULTS_NUM" -ge 0 ] 2>/dev/null; then
        DIFF=$((EXPECTED_NUM - RESULTS_NUM))
        PERCENT_DIFF=$(echo "scale=2; ($DIFF * 100) / $EXPECTED_NUM" | bc)
        
        echo "Expected vs Results API:"
        echo "  Difference: $DIFF PipelineRuns"
        echo "  Percentage: ${PERCENT_DIFF}%"
        
        if (( $(echo "$PERCENT_DIFF > 5" | bc -l) )); then
            echo "  ⚠️  WARNING: Significant discrepancy detected (>5%)"
        elif (( $(echo "$PERCENT_DIFF > 0" | bc -l) )); then
            echo "  ⚠️  NOTE: Some discrepancy detected"
        else
            echo "  ✓ Counts match"
        fi
    fi
fi

# Compare Prometheus vs Results API if both available
if [ "$PROM_TOTAL" != "unknown" ] && [ "$PROM_TOTAL" != "null" ] && [ "$RESULTS_API_COUNT" != "unknown" ] && [ "$RESULTS_API_COUNT" != "null" ]; then
    PROM_NUM=$(echo "$PROM_TOTAL" | jq -r 'if type == "object" then .mean // .value // . else . end' 2>/dev/null || echo "$PROM_TOTAL")
    
    # Try to extract numeric value
    if echo "$PROM_NUM" | grep -qE '^[0-9]+\.?[0-9]*$'; then
        PROM_VAL=$(echo "$PROM_NUM" | awk '{print int($1)}')
        RESULTS_VAL=$RESULTS_API_COUNT
        
        if [ "$PROM_VAL" -gt 0 ] 2>/dev/null && [ "$RESULTS_VAL" -ge 0 ] 2>/dev/null; then
            DIFF=$((PROM_VAL - RESULTS_VAL))
            PERCENT_DIFF=$(echo "scale=2; ($DIFF * 100) / $PROM_VAL" | bc)
            
            echo ""
            echo "Prometheus vs Results API:"
            echo "  Prometheus: $PROM_VAL"
            echo "  Results API: $RESULTS_VAL"
            echo "  Difference: $DIFF PipelineRuns"
            echo "  Percentage: ${PERCENT_DIFF}%"
            
            if (( $(echo "$PERCENT_DIFF > 5" | bc -l) )); then
                echo "  ⚠️  WARNING: Significant discrepancy detected (>5%)"
                echo "  This matches the customer-reported ~10% discrepancy!"
            elif (( $(echo "$PERCENT_DIFF > 0" | bc -l) )); then
                echo "  ⚠️  NOTE: Some discrepancy detected"
            else
                echo "  ✓ Counts match"
            fi
        fi
    fi
fi

echo ""
echo "=== Recommendations ==="
echo "1. Check if Pruner deleted PipelineRuns before Results captured them"
echo "2. Check Results watcher logs for errors or lag"
echo "3. Verify Results API connectivity during test execution"
echo "4. Compare Results DB counts with Results API counts"
echo ""
echo "For detailed analysis, check:"
echo "  - Results API logs: artifacts/results-api-logs.json"
echo "  - Results DB queries: artifacts/benchmark-tekton.json (ResultsDB section)"
echo "  - Prometheus metrics: artifacts/benchmark-tekton.json (measurements section)"
echo "  - Postgres dump: artifacts/tekton-results-postgres-pgdump.dump"
echo ""
echo "To query the Results database directly:"
echo "  ./tools/query-results-db.sh \"SELECT type, count(*) FROM records WHERE type LIKE '%PipelineRun%' GROUP BY type;\""
echo ""
echo "To query the dump file (requires local PostgreSQL):"
echo "  ./tools/query-results-dump.sh artifacts/tekton-results-postgres-pgdump.dump \"<SQL_QUERY>\""

