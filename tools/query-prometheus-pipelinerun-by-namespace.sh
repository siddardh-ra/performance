#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Query Prometheus for tekton_pipelines_controller_pipelinerun_total breakdown by namespace
# This shows which namespaces contributed to the PipelineRun count

DURATION="${1:-7d}"  # Default: 7 days

# Get Prometheus/Thanos Query route
PROM_HOST=$(kubectl -n openshift-monitoring get route -l app.kubernetes.io/name=thanos-query -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

if [ -z "$PROM_HOST" ]; then
    echo "ERROR: Could not find Thanos Query route"
    exit 1
fi

# Get authentication token
TOKEN=$(oc whoami -t)

if [ -z "$TOKEN" ]; then
    echo "ERROR: Could not get authentication token"
    exit 1
fi

echo "=== Prometheus Query: PipelineRun Count by Namespace ==="
echo "Host: $PROM_HOST"
echo "Duration: $DURATION"
echo ""

# Query 1: Total increase (same as before)
echo "1. Total PipelineRuns (all namespaces):"
echo "   Query: sum by (service) (increase(tekton_pipelines_controller_pipelinerun_total[${DURATION}]))"
TOTAL_QUERY="sum by (service) (increase(tekton_pipelines_controller_pipelinerun_total[${DURATION}]))"
TOTAL_ENCODED=$(echo "$TOTAL_QUERY" | jq -sRr @uri)
TOTAL_RESPONSE=$(curl -s -k -H "Authorization: Bearer $TOKEN" \
    "https://${PROM_HOST}/api/v1/query?query=${TOTAL_ENCODED}")

TOTAL_VALUE=$(echo "$TOTAL_RESPONSE" | jq -r '.data.result[0].value[1] // "0"')
echo "   Result: $TOTAL_VALUE PipelineRuns"
echo ""

# Query 2: Breakdown by namespace
echo "2. Breakdown by Namespace:"
echo "   Query: sum by (namespace) (increase(tekton_pipelines_controller_pipelinerun_total[${DURATION}]))"
NS_QUERY="sum by (namespace) (increase(tekton_pipelines_controller_pipelinerun_total[${DURATION}]))"
NS_ENCODED=$(echo "$NS_QUERY" | jq -sRr @uri)
NS_RESPONSE=$(curl -s -k -H "Authorization: Bearer $TOKEN" \
    "https://${PROM_HOST}/api/v1/query?query=${NS_ENCODED}")

if echo "$NS_RESPONSE" | jq -e '.data.result | length > 0' > /dev/null 2>&1; then
    echo "$NS_RESPONSE" | jq -r '.data.result[] | "   Namespace: \(.metric.namespace // "unknown") = \(.value[1]) PipelineRuns"'
    
    # Calculate sum to verify
    NS_SUM=$(echo "$NS_RESPONSE" | jq '[.data.result[].value[1] | tonumber] | add')
    echo ""
    echo "   Sum of namespaces: $NS_SUM PipelineRuns"
else
    echo "   ⚠️  No namespace breakdown available (metric might not have namespace label)"
    echo "   Trying alternative: sum by (service, namespace)..."
    
    # Try with service and namespace together
    ALT_QUERY="sum by (service, namespace) (increase(tekton_pipelines_controller_pipelinerun_total[${DURATION}]))"
    ALT_ENCODED=$(echo "$ALT_QUERY" | jq -sRr @uri)
    ALT_RESPONSE=$(curl -s -k -H "Authorization: Bearer $TOKEN" \
        "https://${PROM_HOST}/api/v1/query?query=${ALT_ENCODED}")
    
    if echo "$ALT_RESPONSE" | jq -e '.data.result | length > 0' > /dev/null 2>&1; then
        echo "$ALT_RESPONSE" | jq -r '.data.result[] | "   Service: \(.metric.service // "unknown"), Namespace: \(.metric.namespace // "unknown") = \(.value[1]) PipelineRuns"'
    else
        echo "   ⚠️  Could not get namespace breakdown"
        echo "   Raw response:"
        echo "$ALT_RESPONSE" | jq '.'
    fi
fi

echo ""

# Query 3: Check what labels are available on this metric
echo "3. Available labels on tekton_pipelines_controller_pipelinerun_total:"
LABELS_QUERY="tekton_pipelines_controller_pipelinerun_total"
LABELS_ENCODED=$(echo "$LABELS_QUERY" | jq -sRr @uri)
LABELS_RESPONSE=$(curl -s -k -H "Authorization: Bearer $TOKEN" \
    "https://${PROM_HOST}/api/v1/query?query=${LABELS_ENCODED}")

if echo "$LABELS_RESPONSE" | jq -e '.data.result[0].metric' > /dev/null 2>&1; then
    echo "   Labels found:"
    echo "$LABELS_RESPONSE" | jq -r '.data.result[0].metric | to_entries[] | "     - \(.key): \(.value)"'
else
    echo "   ⚠️  Could not fetch label information"
fi

echo ""
echo "=== Full JSON Responses ==="
echo ""
echo "Total query response:"
echo "$TOTAL_RESPONSE" | jq '.'
echo ""
echo "Namespace breakdown response:"
echo "$NS_RESPONSE" | jq '.'
