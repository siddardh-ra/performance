#!/bin/bash
#
# Chains OTEL Validation Test Runner
#
# Runs Chains performance test with OTEL metric collection
# Lighter configuration: 200 total, 10 concurrent, 5 namespaces
#

set -o nounset
set -o errexit
set -o pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info() {
    echo -e "${GREEN}INFO${NC}: $*"
}

step() {
    echo -e "\n${BLUE}${BOLD}==>${NC} $*${NC}\n"
}

fatal() {
    echo -e "${RED}FATAL${NC}: $*"
    exit 1
}

# Default action
ACTION="${1:-all}"

# Verify we're in the right directory
if [ ! -f "CLAUDE.md" ]; then
    fatal "Must run from the performance repository root directory"
fi

# Check prerequisites
info "Checking prerequisites..."
command -v oc >/dev/null 2>&1 || fatal "oc CLI not found"
command -v jq >/dev/null 2>&1 || fatal "jq not found"

# Check cluster connectivity
if ! oc whoami >/dev/null 2>&1; then
    fatal "Not logged into OpenShift cluster. Please run 'oc login' first"
fi

info "Connected to cluster: $(oc whoami --show-server)"
info "Current user: $(oc whoami)"
echo ""

# Configuration
cat <<EOF
${BOLD}Chains OTEL Performance Test Configuration${NC}
================================================================================
CHAINS PERFORMANCE TUNING:
  Kube API QPS:           ${DEPLOYMENT_CHAINS_KUBE_API_QPS:-50}
  Kube API Burst:         ${DEPLOYMENT_CHAINS_KUBE_API_BURST:-50}
  Threads per Controller: ${DEPLOYMENT_CHAINS_THREADS_PER_CONTROLLER:-32}

TEST CONFIGURATION:
  Deployment Version:     ${DEPLOYMENT_VERSION:-1.23}
  Test Scenario:          ${TEST_SCENARIO:-signing-tr-tekton-bigbang}
  Total PipelineRuns:     ${TEST_TOTAL:-200}
  Concurrent Runs:        ${TEST_CONCURRENT:-10}
  Test Namespace Count:   ${TEST_NAMESPACE:-5}
  Test Timeout:           ${TEST_TIMEOUT:-36000}

OTEL VALIDATION:
  Mode:                   ${OTEL_VALIDATION_MODE:-true}
================================================================================

EOF

read -p "Proceed with this configuration? (yes/no): " -r
echo
if [[ ! $REPLY =~ ^[Yy](es)?$ ]]; then
    info "Aborted by user"
    exit 0
fi

# Set environment variables for Chains performance tuning
export DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-downstream}"
export DEPLOYMENT_VERSION="${DEPLOYMENT_VERSION:-1.23}"
export CUSTOM_BUILD="${CUSTOM_BUILD:-true}"
export CUSTOM_BUILD_TAG="${CUSTOM_BUILD_TAG:-v1.23.0}"

# Chains-specific performance settings
export DEPLOYMENT_CHAINS_KUBE_API_QPS="${DEPLOYMENT_CHAINS_KUBE_API_QPS:-50}"
export DEPLOYMENT_CHAINS_KUBE_API_BURST="${DEPLOYMENT_CHAINS_KUBE_API_BURST:-50}"
export DEPLOYMENT_CHAINS_THREADS_PER_CONTROLLER="${DEPLOYMENT_CHAINS_THREADS_PER_CONTROLLER:-32}"

# Test configuration
export TEST_SCENARIO="${TEST_SCENARIO:-signing-tr-tekton-bigbang}"
export TEST_TOTAL="${TEST_TOTAL:-200}"
export TEST_CONCURRENT="${TEST_CONCURRENT:-10}"
export TEST_NAMESPACE="${TEST_NAMESPACE:-5}"
export TEST_TIMEOUT="${TEST_TIMEOUT:-36000}"  # 10 hours
export TEST_DO_CLEANUP="${TEST_DO_CLEANUP:-false}"

# Enable OTEL validation
export OTEL_VALIDATION_MODE="true"

# Function to setup cluster
run_setup() {
    step "Setting up OpenShift Pipelines v1.23.0 with Chains..."

    info "Running setup-cluster.sh with Chains configuration..."
    ci-scripts/setup-cluster.sh

    info "Verifying Chains controller..."
    oc get pods -n openshift-pipelines -l app=tekton-chains-controller

    # Verify Chains configuration was applied
    info "Checking Chains controller configuration..."
    chains_pod=$(oc get pods -n openshift-pipelines -l app=tekton-chains-controller -o name | head -1)
    if [ -n "$chains_pod" ]; then
        info "Chains pod: $chains_pod"
        oc get "$chains_pod" -n openshift-pipelines -o json | jq -r '.spec.containers[0].env[] | select(.name | startswith("KUBE_API")) | "\(.name)=\(.value)"'
    fi
}

# Function to run test
run_test() {
    step "Running Chains signing test..."

    info "Test configuration:"
    info "  Scenario: $TEST_SCENARIO"
    info "  Total: $TEST_TOTAL PipelineRuns"
    info "  Concurrent: $TEST_CONCURRENT"
    info "  Namespace count: $TEST_NAMESPACE"
    info "  Expected signing operations: $TEST_TOTAL"

    ci-scripts/load-test.sh

    info "Load test complete!"

    # Show PipelineRuns across namespaces
    for ns in benchmark{1..${TEST_NAMESPACE}}; do
        if oc get ns "$ns" >/dev/null 2>&1; then
            pr_count=$(oc get pipelineruns -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
            info "PipelineRuns in $ns: $pr_count"
        fi
    done

    # Show Chains signing activity
    info "Checking Chains signing status..."
    chains_pod=$(oc get pods -n openshift-pipelines -l app=tekton-chains-controller -o name | head -1)
    if [ -n "$chains_pod" ]; then
        info "Recent Chains controller logs:"
        oc logs "$chains_pod" -n openshift-pipelines --tail=20 | grep -i "sign" || true
    fi
}

# Function to collect results and validate OTEL metrics
run_collect() {
    step "Collecting results and validating Chains OTEL metrics..."

    # Standard results collection
    info "Running standard collect-results.sh..."
    ci-scripts/collect-results.sh

    # Chains-specific OTEL validation
    step "Validating Chains OpenTelemetry metrics..."

    # Get Prometheus connection details
    mhost=$(oc -n openshift-monitoring get route -l app.kubernetes.io/name=thanos-query -o json | jq --raw-output '.items[0].spec.host')
    mtoken=$(oc whoami -t)

    if [ -z "$mhost" ] || [ "$mhost" == "null" ]; then
        fatal "Could not get Prometheus route"
    fi

    info "Prometheus host: $mhost"

    # Run Chains OTEL validation
    tools/validate-chains-otel.sh \
        --prometheus-host "https://$mhost" \
        --prometheus-token "$mtoken" \
        --output-file "artifacts/chains-otel-metrics-validation.json"

    info "Chains OTEL validation complete!"
    echo ""

    # Show validation results
    if [ -f "artifacts/chains-otel-metrics-report.txt" ]; then
        step "Chains OpenTelemetry Validation Report"
        cat artifacts/chains-otel-metrics-report.txt
    else
        warning "Chains OTEL validation report not found"
    fi

    # Show signing metrics summary
    if [ -f "artifacts/chains-otel-metrics-raw.json" ]; then
        echo ""
        step "Chains Signing Metrics Summary"
        jq -r '.signing_metrics | to_entries | .[] | "\(.key): \(.value)"' artifacts/chains-otel-metrics-raw.json || true
    fi
}

# Execute based on action
case "$ACTION" in
    setup)
        run_setup
        ;;
    test)
        run_test
        ;;
    collect)
        run_collect
        ;;
    all)
        run_setup
        echo ""
        step "Waiting 60 seconds for Chains controller to stabilize..."
        sleep 60
        run_test
        echo ""
        step "Waiting 30 seconds before collecting metrics..."
        sleep 30
        run_collect
        ;;
    *)
        error "Unknown action: $ACTION"
        echo "Usage: $0 [setup|test|collect|all]"
        exit 1
        ;;
esac

# Final summary
echo ""
step "Chains OTEL Validation Complete!"
echo ""
info "Output files:"
info "  - Standard results:  artifacts/benchmark-tekton.json"
info "  - Chains raw:        artifacts/chains-otel-metrics-raw.json"
info "  - Chains validation: artifacts/chains-otel-metrics-validation.json"
info "  - Chains report:     artifacts/chains-otel-metrics-report.txt"
echo ""
info "Next steps:"
info "  1. Review artifacts/chains-otel-metrics-report.txt for signing metrics"
info "  2. Check artifacts/chains-otel-metrics-raw.json for detailed data"
info "  3. Compare signing metrics (sign_created, payload_stored, marked_signed)"
echo ""
