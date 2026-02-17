#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Query Prometheus for ONLY your test's PipelineRuns
# Since the metric doesn't track PipelineRun namespace, we use time-based filtering
# This is the best approximation possible with Prometheus

# Get test times from benchmark-tekton.json if available, or use provided times
if [ -f "artifacts/benchmark-tekton.json" ]; then
    START_TIME=$(jq -r '.results.started // empty' artifacts/benchmark-tekton.json)
    # Get first PipelineRun creation time as more accurate start
    FIRST_PR_TIME=$(jq -r '[.items[] | .metadata.creationTimestamp] | sort | first' artifacts/pipelineruns.json 2>/dev/null || echo "$START_TIME")
    # Get last PipelineRun creation time as end
    LAST_PR_TIME=$(jq -r '[.items[] | .metadata.creationTimestamp] | sort | last' artifacts/pipelineruns.json 2>/dev/null || echo "")
    
    if [ -n "$FIRST_PR_TIME" ] && [ "$FIRST_PR_TIME" != "null" ]; then
        START_TIME="$FIRST_PR_TIME"
    fi
    
    if [ -n "$LAST_PR_TIME" ] && [ "$LAST_PR_TIME" != "null" ]; then
        END_TIME="$LAST_PR_TIME"
    else
        END_TIME=$(jq -r '.results.ended // empty' artifacts/benchmark-tekton.json)
    fi
else
    # Use provided times or defaults
    START_TIME="${1:-2025-12-22T10:09:32Z}"
    END_TIME="${2:-2025-12-22T10:26:55Z}"
fi

if [ -z "$START_TIME" ] || [ -z "$END_TIME" ]; then
    echo "ERROR: Could not determine test time range"
    echo "Usage: $0 [start_time] [end_time]"
    exit 1
fi

PROM_HOST=$(kubectl -n openshift-monitoring get route -l app.kubernetes.io/name=thanos-query -o jsonpath='{.items[0].spec.host}')
TOKEN=$(oc whoami -t)

# Convert to Unix timestamps
if [[ "$OSTYPE" == "darwin"* ]]; then
    START_TS=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${START_TIME}" +%s 2>/dev/null || \
               date -u -j -f "%Y-%m-%dT%H:%M:%S" "${START_TIME%.*}Z" +%s 2>/dev/null || echo "$START_TIME")
    END_TS=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${END_TIME}" +%s 2>/dev/null || \
             date -u -j -f "%Y-%m-%dT%H:%M:%S" "${END_TIME%.*}Z" +%s 2>/dev/null || echo "$END_TIME")
else
    START_TS=$(date -u -d "${START_TIME}" +%s)
    END_TS=$(date -u -d "${END_TIME}" +%s)
fi

DURATION=$((END_TS - START_TS))

echo "=== Prometheus Query: Your Test PipelineRuns Only ==="
echo "⚠️  NOTE: Prometheus metric doesn't track PipelineRun namespace"
echo "   Using time-based filtering as best approximation"
echo ""
echo "Test Period:"
echo "  Start: $START_TIME ($START_TS)"
echo "  End: $END_TIME ($END_TS)"
echo "  Duration: ${DURATION}s ($(echo "scale=1; $DURATION/60" | bc) minutes)"
echo ""

# Query using the exact time range
QUERY="sum(increase(tekton_pipelines_controller_pipelinerun_total[${DURATION}s]))"
ENCODED=$(echo "$QUERY" | jq -sRr @uri)

echo "Query: $QUERY"
echo ""

# Execute at the end timestamp
RESPONSE=$(curl -s -k -H "Authorization: Bearer $TOKEN" \
    "https://${PROM_HOST}/api/v1/query?query=${ENCODED}&time=${END_TS}")

if echo "$RESPONSE" | jq -e '.status == "success"' > /dev/null 2>&1; then
    VALUE=$(echo "$RESPONSE" | jq -r '.data.result[0].value[1] // "N/A"')
    
    echo "Result: $VALUE PipelineRuns"
    echo ""
    echo "Expected: 1000 PipelineRuns (from your test)"
    echo "Prometheus: $VALUE PipelineRuns"
    
    if [ "$VALUE" != "N/A" ]; then
        DIFF=$(echo "$VALUE - 1000" | bc)
        PERCENT=$(echo "scale=2; ($DIFF * 100) / 1000" | bc)
        echo "Difference: $DIFF PipelineRuns ($PERCENT%)"
        echo ""
        echo "⚠️  This still includes PipelineRuns from other namespaces during this period"
        echo "   Prometheus cannot filter by PipelineRun namespace - only controller namespace"
    fi
    
    echo ""
    echo "=== Alternative: Query Results DB (More Accurate) ==="
    echo "For accurate count filtered by namespace, use:"
    echo "  ./tools/query-results-db.sh \"SELECT count(*) FROM records WHERE type LIKE '%PipelineRun%' AND parent = 'benchmark';\""
else
    echo "ERROR: Query failed"
    echo "$RESPONSE" | jq '.'
fi
