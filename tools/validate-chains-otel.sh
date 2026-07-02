#!/bin/bash
#
# Chains OpenTelemetry Metrics Validation
#
# Validates Chains OTEL metrics based on PR #1735
# Source: https://github.com/tektoncd/chains/pull/1735
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
    echo -e "${GREEN}INFO${NC}: $*" >&2
}

error() {
    echo -e "${RED}ERROR${NC}: $*" >&2
}

fatal() {
    echo -e "${RED}FATAL${NC}: $*" >&2
    exit 1
}

# Parse arguments
PROMETHEUS_HOST=""
PROMETHEUS_TOKEN=""
OUTPUT_FILE="artifacts/chains-otel-metrics-validation.json"
RAW_FILE="artifacts/chains-otel-metrics-raw.json"
REPORT_FILE="artifacts/chains-otel-metrics-report.txt"

while [[ $# -gt 0 ]]; do
    case $1 in
        --prometheus-host)
            PROMETHEUS_HOST="$2"
            shift 2
            ;;
        --prometheus-token)
            PROMETHEUS_TOKEN="$2"
            shift 2
            ;;
        --output-file)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate required parameters
[ -z "$PROMETHEUS_HOST" ] && fatal "Missing --prometheus-host"
[ -z "$PROMETHEUS_TOKEN" ] && fatal "Missing --prometheus-token"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
REFERENCE_FILE="$REPO_ROOT/config/chains-otel-metrics-reference.json"

[ ! -f "$REFERENCE_FILE" ] && fatal "Reference file not found: $REFERENCE_FILE"

info "Chains OpenTelemetry Metrics Validation"
info "Prometheus Host: $PROMETHEUS_HOST"
info "Reference File: $REFERENCE_FILE"
echo ""

# Query Prometheus for a metric
query_prometheus() {
    local metric="$1"
    local query="${2:-$metric}"

    curl -sk -H "Authorization: Bearer $PROMETHEUS_TOKEN" \
        "${PROMETHEUS_HOST}/api/v1/query?query=${query}" 2>/dev/null | \
        jq -r '.data.result[0].value[1]? // "null"'
}

info "Collecting Chains signing metrics..."

# Signing counters (PipelineRun)
pr_sign_created=$(query_prometheus "watcher_pipelinerun_sign_created_total" "watcher_pipelinerun_sign_created_total")
pr_payload_stored=$(query_prometheus "watcher_pipelinerun_payload_stored_total" "watcher_pipelinerun_payload_stored_total")
pr_marked_signed=$(query_prometheus "watcher_pipelinerun_marked_signed_total" "watcher_pipelinerun_marked_signed_total")

# Signing counters (TaskRun)
tr_sign_created=$(query_prometheus "watcher_taskrun_sign_created_total" "watcher_taskrun_sign_created_total")
tr_payload_stored=$(query_prometheus "watcher_taskrun_payload_stored_total" "watcher_taskrun_payload_stored_total")
tr_marked_signed=$(query_prometheus "watcher_taskrun_marked_signed_total" "watcher_taskrun_marked_signed_total")

info "Collecting workqueue metrics (kn_workqueue_*)..."

# Workqueue metrics (shared with Pipelines, but scoped to Chains controller)
wq_adds=$(query_prometheus "kn_workqueue_adds_total" 'sum(kn_workqueue_adds_total{namespace="openshift-pipelines"})')
wq_depth=$(query_prometheus "kn_workqueue_depth" 'sum(kn_workqueue_depth{namespace="openshift-pipelines"})')
wq_proc_sum=$(query_prometheus "kn_workqueue_process_duration_seconds_sum" 'sum(kn_workqueue_process_duration_seconds_sum{namespace="openshift-pipelines"})')
wq_proc_count=$(query_prometheus "kn_workqueue_process_duration_seconds_count" 'sum(kn_workqueue_process_duration_seconds_count{namespace="openshift-pipelines"})')
wq_queue_sum=$(query_prometheus "kn_workqueue_queue_duration_seconds_sum" 'sum(kn_workqueue_queue_duration_seconds_sum{namespace="openshift-pipelines"})')
wq_queue_count=$(query_prometheus "kn_workqueue_queue_duration_seconds_count" 'sum(kn_workqueue_queue_duration_seconds_count{namespace="openshift-pipelines"})')
wq_retries=$(query_prometheus "kn_workqueue_retries_total" 'sum(kn_workqueue_retries_total{namespace="openshift-pipelines"})')
wq_unfinished=$(query_prometheus "kn_workqueue_unfinished_work_seconds" 'sum(kn_workqueue_unfinished_work_seconds{namespace="openshift-pipelines"})')

info "Collecting runtime metrics..."

# Runtime metrics (from Chains controller pod)
cpu=$(query_prometheus "process_cpu_seconds_total" 'sum(process_cpu_seconds_total{job=~".*chains.*"})')
mem_resident=$(query_prometheus "process_resident_memory_bytes" 'sum(process_resident_memory_bytes{job=~".*chains.*"})')
mem_virtual=$(query_prometheus "process_virtual_memory_bytes" 'sum(process_virtual_memory_bytes{job=~".*chains.*"})')
fds_open=$(query_prometheus "process_open_fds" 'sum(process_open_fds{job=~".*chains.*"})')
fds_max=$(query_prometheus "process_max_fds" 'sum(process_max_fds{job=~".*chains.*"})')
goroutines=$(query_prometheus "go_goroutines" 'sum(go_goroutines{job=~".*chains.*"})')
threads=$(query_prometheus "go_threads" 'sum(go_threads{job=~".*chains.*"})')
gc_sum=$(query_prometheus "go_gc_duration_seconds_sum" 'sum(go_gc_duration_seconds_sum{job=~".*chains.*"})')
gc_count=$(query_prometheus "go_gc_duration_seconds_count" 'sum(go_gc_duration_seconds_count{job=~".*chains.*"})')
mem_alloc=$(query_prometheus "go_memstats_alloc_bytes" 'sum(go_memstats_alloc_bytes{job=~".*chains.*"})')
mem_heap_alloc=$(query_prometheus "go_memstats_heap_alloc_bytes" 'sum(go_memstats_heap_alloc_bytes{job=~".*chains.*"})')
mem_heap_inuse=$(query_prometheus "go_memstats_heap_inuse_bytes" 'sum(go_memstats_heap_inuse_bytes{job=~".*chains.*"})')

# Build raw JSON
cat > "$RAW_FILE" << EOF
{
  "_metadata": {
    "validation_date": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "source_pr": "https://github.com/tektoncd/chains/pull/1735",
    "component": "tekton-chains-controller",
    "note": "OSP v1.23.0 uses watcher_<type>_<metric>_total naming (more granular than PR #1735)"
  },
  "signing_metrics": {
    "pipelinerun": {
      "sign_created": $pr_sign_created,
      "payload_stored": $pr_payload_stored,
      "marked_signed": $pr_marked_signed
    },
    "taskrun": {
      "sign_created": $tr_sign_created,
      "payload_stored": $tr_payload_stored,
      "marked_signed": $tr_marked_signed
    }
  },
  "workqueue": {
    "kn_workqueue_adds_total": $wq_adds,
    "kn_workqueue_depth": $wq_depth,
    "kn_workqueue_process_duration_seconds_sum": $wq_proc_sum,
    "kn_workqueue_process_duration_seconds_count": $wq_proc_count,
    "kn_workqueue_queue_duration_seconds_sum": $wq_queue_sum,
    "kn_workqueue_queue_duration_seconds_count": $wq_queue_count,
    "kn_workqueue_retries_total": $wq_retries,
    "kn_workqueue_unfinished_work_seconds": $wq_unfinished
  },
  "runtime": {
    "process_cpu_seconds_total": $cpu,
    "process_resident_memory_bytes": $mem_resident,
    "process_virtual_memory_bytes": $mem_virtual,
    "process_open_fds": $fds_open,
    "process_max_fds": $fds_max,
    "go_goroutines": $goroutines,
    "go_threads": $threads,
    "go_gc_duration_seconds_sum": $gc_sum,
    "go_gc_duration_seconds_count": $gc_count,
    "go_memstats_alloc_bytes": $mem_alloc,
    "go_memstats_heap_alloc_bytes": $mem_heap_alloc,
    "go_memstats_heap_inuse_bytes": $mem_heap_inuse
  }
}
EOF

info "Raw metrics written to: $RAW_FILE"

# Generate validation report
cat > "$REPORT_FILE" << 'EOF'
================================================================================
Tekton Chains OpenTelemetry Metrics Validation Report
Source: https://github.com/tektoncd/chains/pull/1735
Validation Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Note: OSP v1.23.0 uses watcher_<type>_<metric>_total naming (more granular)
================================================================================

SIGNING METRICS (6 counters: 3 for PipelineRuns + 3 for TaskRuns)
--------------------------------------------------------------------------------
EOF

# Check signing metrics (6 total: 3 for PRs + 3 for TRs)
signing_count=0
[ "$pr_sign_created" != "null" ] && signing_count=$((signing_count + 1))
[ "$pr_payload_stored" != "null" ] && signing_count=$((signing_count + 1))
[ "$pr_marked_signed" != "null" ] && signing_count=$((signing_count + 1))
[ "$tr_sign_created" != "null" ] && signing_count=$((signing_count + 1))
[ "$tr_payload_stored" != "null" ] && signing_count=$((signing_count + 1))
[ "$tr_marked_signed" != "null" ] && signing_count=$((signing_count + 1))

cat >> "$REPORT_FILE" << EOF
Expected: 6 (3 for PipelineRuns + 3 for TaskRuns)
Found: $signing_count

PipelineRun Signing Metrics:
EOF

[ "$pr_sign_created" != "null" ] && echo "✅ watcher_pipelinerun_sign_created_total: $pr_sign_created" >> "$REPORT_FILE" || echo "❌ watcher_pipelinerun_sign_created_total: MISSING" >> "$REPORT_FILE"
[ "$pr_payload_stored" != "null" ] && echo "✅ watcher_pipelinerun_payload_stored_total: $pr_payload_stored" >> "$REPORT_FILE" || echo "❌ watcher_pipelinerun_payload_stored_total: MISSING" >> "$REPORT_FILE"
[ "$pr_marked_signed" != "null" ] && echo "✅ watcher_pipelinerun_marked_signed_total: $pr_marked_signed" >> "$REPORT_FILE" || echo "❌ watcher_pipelinerun_marked_signed_total: MISSING" >> "$REPORT_FILE"

cat >> "$REPORT_FILE" << EOF

TaskRun Signing Metrics:
EOF

[ "$tr_sign_created" != "null" ] && echo "✅ watcher_taskrun_sign_created_total: $tr_sign_created" >> "$REPORT_FILE" || echo "❌ watcher_taskrun_sign_created_total: MISSING" >> "$REPORT_FILE"
[ "$tr_payload_stored" != "null" ] && echo "✅ watcher_taskrun_payload_stored_total: $tr_payload_stored" >> "$REPORT_FILE" || echo "❌ watcher_taskrun_payload_stored_total: MISSING" >> "$REPORT_FILE"
[ "$tr_marked_signed" != "null" ] && echo "✅ watcher_taskrun_marked_signed_total: $tr_marked_signed" >> "$REPORT_FILE" || echo "❌ watcher_taskrun_marked_signed_total: MISSING" >> "$REPORT_FILE"

cat >> "$REPORT_FILE" << EOF

WORKQUEUE METRICS (8 metrics via kn_workqueue_*)
--------------------------------------------------------------------------------
Expected: 8
Found: $([ "$wq_adds" != "null" ] && echo -n "1" || echo -n "0")$([ "$wq_depth" != "null" ] && echo -n "+" || echo -n "")$([ "$wq_proc_sum" != "null" ] && echo -n "1" || echo -n "")... (calculated)

EOF

[ "$wq_adds" != "null" ] && echo "✅ kn_workqueue_adds_total: $wq_adds" >> "$REPORT_FILE" || echo "❌ kn_workqueue_adds_total: MISSING" >> "$REPORT_FILE"
[ "$wq_depth" != "null" ] && echo "✅ kn_workqueue_depth: $wq_depth" >> "$REPORT_FILE" || echo "❌ kn_workqueue_depth: MISSING" >> "$REPORT_FILE"
[ "$wq_retries" != "null" ] && echo "✅ kn_workqueue_retries_total: $wq_retries" >> "$REPORT_FILE" || echo "❌ kn_workqueue_retries_total: MISSING" >> "$REPORT_FILE"

cat >> "$REPORT_FILE" << EOF

RUNTIME METRICS (12 metrics)
--------------------------------------------------------------------------------
Expected: 12
Found: (see below)

Process Metrics:
EOF

[ "$cpu" != "null" ] && echo "✅ process_cpu_seconds_total: $cpu" >> "$REPORT_FILE" || echo "❌ process_cpu_seconds_total: MISSING" >> "$REPORT_FILE"
[ "$mem_resident" != "null" ] && echo "✅ process_resident_memory_bytes: $mem_resident ($(echo "$mem_resident / 1024 / 1024 / 1024" | bc)GB)" >> "$REPORT_FILE" || echo "❌ process_resident_memory_bytes: MISSING" >> "$REPORT_FILE"

cat >> "$REPORT_FILE" << EOF

Go Runtime Metrics:
EOF

[ "$goroutines" != "null" ] && echo "✅ go_goroutines: $goroutines" >> "$REPORT_FILE" || echo "❌ go_goroutines: MISSING" >> "$REPORT_FILE"
[ "$gc_sum" != "null" ] && [ "$gc_count" != "null" ] && echo "✅ go_gc_duration_seconds: sum=$gc_sum, count=$gc_count" >> "$REPORT_FILE" || echo "❌ go_gc_duration_seconds: MISSING" >> "$REPORT_FILE"

# Calculate GC overhead if available
if [ "$cpu" != "null" ] && [ "$gc_sum" != "null" ] && [ "$cpu" != "0" ]; then
    gc_overhead=$(echo "scale=2; ($gc_sum / $cpu) * 100" | bc 2>/dev/null || echo "N/A")
    cat >> "$REPORT_FILE" << EOF

PERFORMANCE ANALYSIS
--------------------------------------------------------------------------------
GC Overhead: ${gc_overhead}%
EOF
fi

cat >> "$REPORT_FILE" << EOF

================================================================================
VALIDATION STATUS
================================================================================
EOF

# Overall validation
total_expected=26  # 6 signing (3 PR + 3 TR) + 8 workqueue + 12 runtime
total_found=0

[ "$pr_sign_created" != "null" ] && total_found=$((total_found + 1))
[ "$pr_payload_stored" != "null" ] && total_found=$((total_found + 1))
[ "$pr_marked_signed" != "null" ] && total_found=$((total_found + 1))
[ "$tr_sign_created" != "null" ] && total_found=$((total_found + 1))
[ "$tr_payload_stored" != "null" ] && total_found=$((total_found + 1))
[ "$tr_marked_signed" != "null" ] && total_found=$((total_found + 1))
[ "$wq_adds" != "null" ] && total_found=$((total_found + 1))
[ "$wq_depth" != "null" ] && total_found=$((total_found + 1))
[ "$cpu" != "null" ] && total_found=$((total_found + 1))
[ "$goroutines" != "null" ] && total_found=$((total_found + 1))

coverage=$(echo "scale=1; ($total_found / $total_expected) * 100" | bc 2>/dev/null || echo "0")

if [ "$signing_count" -eq 6 ]; then
    echo "✅ SIGNING METRICS: PASS (6/6)" >> "$REPORT_FILE"
else
    echo "❌ SIGNING METRICS: FAIL ($signing_count/6)" >> "$REPORT_FILE"
fi

echo "Coverage: ~${coverage}% (${total_found}/${total_expected} key metrics validated)" >> "$REPORT_FILE"
echo "=================================================================================" >> "$REPORT_FILE"

info "Validation report written to: $REPORT_FILE"
cat "$REPORT_FILE"

# Return success if all signing metrics are present
[ "$signing_count" -eq 6 ]
