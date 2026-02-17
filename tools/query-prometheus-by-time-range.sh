#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Query Prometheus for PipelineRun count in a specific time range
# Usage: ./query-prometheus-by-time-range.sh <start_time> <end_time>
# Times should be in RFC3339 format or Unix timestamp

START_TIME="${1:-}"
END_TIME="${2:-}"

if [ -z "$START_TIME" ] || [ -z "$END_TIME" ]; then
    echo "Usage: $0 <start_time> <end_time>"
    echo ""
    echo "Times can be:"
    echo "  - RFC3339: 2025-12-22T10:09:21Z"
    echo "  - Unix timestamp: 1766400962"
    echo ""
    echo "Example:"
    echo "  $0 2025-12-22T10:09:21Z 2025-12-22T10:43:41Z"
    exit 1
fi

PROM_HOST=$(kubectl -n openshift-monitoring get route -l app.kubernetes.io/name=thanos-query -o jsonpath='{.items[0].spec.host}')
TOKEN=$(oc whoami -t)

# Convert times to Unix timestamp if needed
if [[ "$START_TIME" =~ ^[0-9]{4}- ]]; then
    # RFC3339 format - convert to Unix
    START_TS=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${START_TIME}" +%s 2>/dev/null || \
               date -u -d "${START_TIME}" +%s 2>/dev/null || echo "$START_TIME")
else
    START_TS="$START_TIME"
fi

if [[ "$END_TIME" =~ ^[0-9]{4}- ]]; then
    END_TS=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${END_TIME}" +%s 2>/dev/null || \
             date -u -d "${END_TIME}" +%s 2>/dev/null || echo "$END_TIME")
else
    END_TS="$END_TIME"
fi

# Calculate duration
DURATION=$((END_TS - START_TS))
DURATION_DAYS=$(echo "scale=2; $DURATION / 86400" | bc)

echo "=== Querying Prometheus for Specific Time Range ==="
echo "Start: $START_TIME (Unix: $START_TS)"
echo "End: $END_TIME (Unix: $END_TS)"
echo "Duration: ${DURATION}s (${DURATION_DAYS} days)"
echo ""

# Query 1: Get value at start time
echo "1. PipelineRun counter at START time:"
QUERY_START="sum(tekton_pipelines_controller_pipelinerun_total) @ $START_TS"
ENCODED_START=$(echo "$QUERY_START" | jq -sRr @uri)
RESPONSE_START=$(curl -s -k -H "Authorization: Bearer $TOKEN" \
    "https://${PROM_HOST}/api/v1/query?query=${ENCODED_START}")
VALUE_START=$(echo "$RESPONSE_START" | jq -r '.data.result[0].value[1] // "0"')
echo "   Value: $VALUE_START"
echo ""

# Query 2: Get value at end time
echo "2. PipelineRun counter at END time:"
QUERY_END="sum(tekton_pipelines_controller_pipelinerun_total) @ $END_TS"
ENCODED_END=$(echo "$QUERY_END" | jq -sRr @uri)
RESPONSE_END=$(curl -s -k -H "Authorization: Bearer $TOKEN" \
    "https://${PROM_HOST}/api/v1/query?query=${ENCODED_END}")
VALUE_END=$(echo "$RESPONSE_END" | jq -r '.data.result[0].value[1] // "0"')
echo "   Value: $VALUE_END"
echo ""

# Calculate difference
DIFF=$(echo "$VALUE_END - $VALUE_START" | bc)
echo "3. Increase during test period:"
echo "   $VALUE_END - $VALUE_START = $DIFF PipelineRuns"
echo ""

# Also try range query
echo "4. Using range query (increase over test duration):"
RANGE_DURATION="${DURATION}s"
QUERY_RANGE="sum(increase(tekton_pipelines_controller_pipelinerun_total[${RANGE_DURATION}])) @ $END_TS"
ENCODED_RANGE=$(echo "$QUERY_RANGE" | jq -sRr @uri)
RESPONSE_RANGE=$(curl -s -k -H "Authorization: Bearer $TOKEN" \
    "https://${PROM_HOST}/api/v1/query?query=${ENCODED_RANGE}")
VALUE_RANGE=$(echo "$RESPONSE_RANGE" | jq -r '.data.result[0].value[1] // "0"')
echo "   Increase over ${RANGE_DURATION}: $VALUE_RANGE PipelineRuns"
