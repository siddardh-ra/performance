#!/bin/bash
#
# OpenTelemetry Metrics Validation - Quick Start Script
#
# This script provides a simple way to run the complete OTEL validation workflow
# for OpenShift Pipelines v1.23.0
#
# Usage:
#   ./run-otel-validation.sh [install|test|collect|all]
#
# Options:
#   install  - Setup cluster with OSP v1.23.0
#   test     - Run load test
#   collect  - Collect results and validate OTEL metrics
#   all      - Run complete workflow (default)
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

warning() {
    echo -e "${YELLOW}WARNING${NC}: $*"
}

error() {
    echo -e "${RED}ERROR${NC}: $*"
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
command -v oc >/dev/null 2>&1 || fatal "oc CLI not found. Please install OpenShift CLI."
command -v python3 >/dev/null 2>&1 || fatal "python3 not found. Please install Python 3."
command -v jq >/dev/null 2>&1 || fatal "jq not found. Please install jq."

# Activate virtual environment if it exists
if [ -d "venv" ]; then
    info "Activating Python virtual environment..."
    source venv/bin/activate
else
    warning "Virtual environment not found. Run ./setup-otel-validation.sh first"
    fatal "Please run: ./setup-otel-validation.sh"
fi

# Check cluster connectivity
if ! oc whoami >/dev/null 2>&1; then
    fatal "Not logged into OpenShift cluster. Please run 'oc login' first."
fi

info "Connected to cluster: $(oc whoami --show-server)"
info "Current user: $(oc whoami)"
echo ""

# Configuration
cat <<EOF
${BOLD}OpenTelemetry Validation Configuration${NC}
================================================================================
OCP Version:              ${OCP_VERSION:-4.21}
Custom Build Tag:         ${CUSTOM_BUILD_TAG:-v1.23.0}
Deployment Version:       ${DEPLOYMENT_VERSION:-1.23}
Install Results:          ${INSTALL_RESULTS:-false}

Test Scenario:            ${TEST_SCENARIO:-math}
Total PipelineRuns:       ${TEST_TOTAL:-100}
Concurrent Runs:          ${TEST_CONCURRENT:-10}
Test Namespace Count:     ${TEST_NAMESPACE:-1}
================================================================================

EOF

read -p "Proceed with this configuration? (yes/no): " -r
echo
if [[ ! $REPLY =~ ^[Yy](es)?$ ]]; then
    info "Aborted by user"
    exit 0
fi

# Set required environment variables
export CUSTOM_BUILD="${CUSTOM_BUILD:-true}"
export CUSTOM_BUILD_TAG="${CUSTOM_BUILD_TAG:-v1.23.0}"
export OCP_VERSION="${OCP_VERSION:-4.21}"
export OTEL_VALIDATION_MODE="true"
export DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-downstream}"
export DEPLOYMENT_VERSION="${DEPLOYMENT_VERSION:-1.23}"
export INSTALL_RESULTS="${INSTALL_RESULTS:-false}"

export TEST_SCENARIO="${TEST_SCENARIO:-math}"
export TEST_TOTAL="${TEST_TOTAL:-700}"
export TEST_CONCURRENT="${TEST_CONCURRENT:-20}"
export TEST_NAMESPACE="${TEST_NAMESPACE:-5}"
export TEST_TIMEOUT="${TEST_TIMEOUT:-18000}"
export TEST_DO_CLEANUP="${TEST_DO_CLEANUP:-false}"

# Verify image accessibility (optional, can be skipped)
step "Verifying v1.23.0 image accessibility..."
if [ -f "tools/verify-otel-image.sh" ]; then
    if ./tools/verify-otel-image.sh "$CUSTOM_BUILD_TAG"; then
        info "Image verification successful"
    else
        warning "Image verification failed, but continuing anyway..."
    fi
else
    warning "Image verification script not found, skipping..."
fi

# Function to run installation
run_install() {
    step "Installing OpenShift Pipelines v1.23.0..."

    info "Running setup-cluster.sh..."
    ci-scripts/setup-cluster.sh

    info "Installation complete!"
    info "Verifying pods..."
    oc get pods -n openshift-pipelines
}

# Function to run test
run_test() {
    step "Running load test..."

    info "Test configuration:"
    info "  Scenario: $TEST_SCENARIO"
    info "  Total: $TEST_TOTAL PipelineRuns"
    info "  Concurrent: $TEST_CONCURRENT"
    info "  Namespace count: $TEST_NAMESPACE"

    ci-scripts/load-test.sh

    info "Load test complete!"
    info "Checking PipelineRuns..."
    if [ "$TEST_NAMESPACE" == "1" ]; then
        oc get pipelineruns -n benchmark | head -20
    else
        for ns in benchmark{1..${TEST_NAMESPACE}}; do
            info "PipelineRuns in $ns:"
            oc get pipelineruns -n "$ns" 2>/dev/null | head -10 || true
        done
    fi
}

# Function to collect results
run_collect() {
    step "Collecting results and validating OpenTelemetry metrics..."

    info "Running collect-results.sh (includes OTEL validation)..."
    ci-scripts/collect-results.sh

    info "Collection complete!"
    echo ""

    # Show validation results
    if [ -f "artifacts/otel-metrics-report.txt" ]; then
        step "OpenTelemetry Validation Report"
        cat artifacts/otel-metrics-report.txt
    else
        warning "OTEL validation report not found"
    fi
}

# Execute based on action
case "$ACTION" in
    install)
        run_install
        ;;
    test)
        run_test
        ;;
    collect)
        run_collect
        ;;
    all)
        run_install
        echo ""
        step "Waiting 30 seconds for cluster to stabilize..."
        sleep 30
        run_test
        echo ""
        run_collect
        ;;
    *)
        error "Unknown action: $ACTION"
        echo "Usage: $0 [install|test|collect|all]"
        exit 1
        ;;
esac

# Final summary
echo ""
step "Validation Complete!"
echo ""
info "Output files:"
info "  - Raw metrics:       artifacts/otel-metrics-raw.json"
info "  - Validation JSON:   artifacts/otel-metrics-validation.json"
info "  - Text report:       artifacts/otel-metrics-report.txt"
info "  - Standard results:  artifacts/benchmark-tekton.json"
echo ""
info "Next steps:"
info "  1. Review artifacts/otel-metrics-report.txt for validation status"
info "  2. Check artifacts/otel-metrics-validation.json for detailed results"
info "  3. If metrics are missing, see OTEL_VALIDATION_README.md Troubleshooting"
echo ""
