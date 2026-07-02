#!/bin/bash
#
# Chains OpenTelemetry Validation - Quick Runner
#
# Runs validation for Tekton Chains OTEL metrics
# Based on PR: https://github.com/tektoncd/chains/pull/1735
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

# Check prerequisites
info "Checking prerequisites..."
command -v oc >/dev/null 2>&1 || fatal "oc CLI not found"
command -v jq >/dev/null 2>&1 || fatal "jq not found"

# Check cluster connectivity
if ! oc whoami >/dev/null 2>&1; then
    fatal "Not logged into OpenShift cluster. Please run 'oc login' first"
fi

info "Connected to cluster: $(oc whoami --show-server)"
echo ""

# Check if Chains is installed
step "Checking Tekton Chains installation..."

if ! oc get pods -n openshift-pipelines -l app=tekton-chains-controller >/dev/null 2>&1; then
    fatal "Tekton Chains controller not found! Is Chains installed?"
fi

chains_pod=$(oc get pods -n openshift-pipelines -l app=tekton-chains-controller -o name | head -1)
if [ -z "$chains_pod" ]; then
    fatal "No Chains controller pods running"
fi

info "Chains controller found: $chains_pod"

# Check OSP version
osp_version=$(oc get csv -n openshift-operators -o json | jq -r '.items[] | select(.metadata.name | startswith("openshift-pipelines-operator")) | .spec.version')
info "OpenShift Pipelines version: $osp_version"

if [[ ! "$osp_version" =~ ^1\.23 ]]; then
    fatal "This validation requires OSP v1.23.x (found: $osp_version)"
fi

echo ""

# Configuration
cat <<EOF
${BOLD}Chains OTEL Validation Configuration${NC}
================================================================================
Cluster:                $(oc whoami --show-server)
OpenShift Pipelines:    v${osp_version}
Chains Controller:      Running ✅
Expected Metrics:       23 (3 signing + 8 workqueue + 12 runtime)
Source PR:              https://github.com/tektoncd/chains/pull/1735
================================================================================

EOF

read -p "Proceed with Chains OTEL validation? (yes/no): " -r
echo
if [[ ! $REPLY =~ ^[Yy](es)?$ ]]; then
    info "Aborted by user"
    exit 0
fi

# Create artifacts directory
mkdir -p artifacts

# Get Prometheus connection details
step "Connecting to Prometheus..."

mhost=$(oc -n openshift-monitoring get route -l app.kubernetes.io/name=thanos-query -o json | jq --raw-output '.items[0].spec.host')
mtoken=$(oc whoami -t)

if [ -z "$mhost" ] || [ "$mhost" == "null" ]; then
    fatal "Could not get Prometheus route"
fi

info "Prometheus host: $mhost"
echo ""

# Run validation
step "Collecting Chains OTEL metrics from Prometheus..."

tools/validate-chains-otel.sh \
    --prometheus-host "https://$mhost" \
    --prometheus-token "$mtoken" \
    --output-file "artifacts/chains-otel-metrics-validation.json"

validation_result=$?

echo ""
step "Validation Complete!"
echo ""

# Show results
if [ -f "artifacts/chains-otel-metrics-report.txt" ]; then
    info "Full report saved to: artifacts/chains-otel-metrics-report.txt"
fi

if [ -f "artifacts/chains-otel-metrics-raw.json" ]; then
    info "Raw metrics saved to: artifacts/chains-otel-metrics-raw.json"
    echo ""
    info "Sample data:"
    jq '.signing_metrics' artifacts/chains-otel-metrics-raw.json
fi

echo ""

if [ $validation_result -eq 0 ]; then
    echo -e "${GREEN}✅ VALIDATION PASSED${NC}"
    echo ""
    info "All Chains signing metrics are present!"
    info "Next: Review artifacts/chains-otel-metrics-report.txt for details"
else
    echo -e "${RED}❌ VALIDATION FAILED${NC}"
    echo ""
    info "Some metrics are missing. Check artifacts/chains-otel-metrics-report.txt"
    exit 1
fi
