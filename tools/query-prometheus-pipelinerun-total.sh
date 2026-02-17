#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Query Prometheus for tekton_pipelines_controller_pipelinerun_total increase over 7 days
# This matches the customer's query: sum by (service) (increase(tekton_pipelines_controller_pipelinerun_total[7d]))

DURATION="${1:-7d}"  # Default: 7 days, can be changed to 1d, 30d, etc.

# Get Prometheus/Thanos Query route
PROM_HOST=$(kubectl -n openshift-monitoring get route -l app.kubernetes.io/name=thanos-query -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

if [ -z "$PROM_HOST" ]; then
    echo "ERROR: Could not find Thanos Query route in openshift-monitoring namespace"
    echo "Trying alternative: checking for prometheus route..."
    PROM_HOST=$(kubectl -n openshift-monitoring get route -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
    
    if [ -z "$PROM_HOST" ]; then
        echo "ERROR: Could not find Prometheus or Thanos Query route"
        exit 1
    fi
fi

# Get authentication token
TOKEN=$(oc whoami -t)

if [ -z "$TOKEN" ]; then
    echo "ERROR: Could not get authentication token. Make sure you're logged in with 'oc login'"
    exit 1
fi

# Build the query (URL encode it)
QUERY="sum by (service) (increase(tekton_pipelines_controller_pipelinerun_total[${DURATION}]))"
ENCODED_QUERY=$(echo "$QUERY" | jq -sRr @uri)

echo "=== Prometheus Query ==="
echo "Host: $PROM_HOST"
echo "Query: $QUERY"
echo "Duration: $DURATION"
echo ""
echo "Executing query..."
echo ""

# Execute the query
RESPONSE=$(curl -s -k \
    -H "Authorization: Bearer $TOKEN" \
    "https://${PROM_HOST}/api/v1/query?query=${ENCODED_QUERY}")

# Check if we got a valid response
if echo "$RESPONSE" | jq empty 2>/dev/null; then
    STATUS=$(echo "$RESPONSE" | jq -r '.status // "unknown"')
    
    if [ "$STATUS" == "success" ]; then
        echo "✓ Query successful"
        echo ""
        echo "=== Results ==="
        
        # Extract and display results
        RESULT_COUNT=$(echo "$RESPONSE" | jq '.data.result | length')
        
        if [ "$RESULT_COUNT" -eq 0 ]; then
            echo "No results found. This might mean:"
            echo "  1. The metric doesn't exist or has a different name"
            echo "  2. No data in the specified time range"
            echo "  3. The service label doesn't match"
            echo ""
            echo "Raw response:"
            echo "$RESPONSE" | jq '.'
        else
            echo "Found $RESULT_COUNT service(s):"
            echo ""
            
            # Display results in a readable format
            echo "$RESPONSE" | jq -r '.data.result[] | "Service: \(.metric.service // "unknown")\nValue: \(.value[1])\nTimestamp: \(.value[0])\n"'
            
            # Calculate total if multiple services
            if [ "$RESULT_COUNT" -gt 1 ]; then
                TOTAL=$(echo "$RESPONSE" | jq '[.data.result[].value[1] | tonumber] | add')
                echo "---"
                echo "Total across all services: $TOTAL"
            fi
        fi
        
        echo ""
        echo "=== Full Response (JSON) ==="
        echo "$RESPONSE" | jq '.'
    else
        echo "✗ Query failed"
        echo "Status: $STATUS"
        echo "Error: $(echo "$RESPONSE" | jq -r '.error // .errorType // "Unknown error"')"
        echo ""
        echo "Full response:"
        echo "$RESPONSE" | jq '.'
        exit 1
    fi
else
    echo "ERROR: Invalid JSON response from Prometheus"
    echo "Response:"
    echo "$RESPONSE"
    exit 1
fi
