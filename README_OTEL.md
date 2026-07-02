# OpenTelemetry Metrics Validation

Validation scripts for Tekton Pipelines and Tekton Chains OpenTelemetry metrics in OpenShift Pipelines.

## Prerequisites

### Required Tools
- `oc` CLI (OpenShift command-line tool)
- `jq` (JSON processor)
- `python3` (version 3.8+)
- `bash` shell

### Required Access
- OpenShift cluster with OSP v1.23.0 installed
- Cluster admin or monitoring access
- Access to Prometheus/Thanos (openshift-monitoring namespace)

### Python Dependencies

Install dependencies from `requirements-otel.txt`:

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements-otel.txt
```

**Required packages**:
- `requests` - HTTP library for Prometheus queries
- `prometheus-api-client` - Prometheus Python client
- `kubernetes` - Kubernetes Python client
- `pyyaml` - YAML parser

## Pipelines OTEL Validation

Validates 38 Tekton Pipelines OpenTelemetry metrics.

### Quick Start

```bash
# 1. Login to cluster
oc login <cluster-url> --username <user> --password <pass>

# 2. Activate virtual environment
source venv/bin/activate

# 3. Run validation (all-in-one: setup + test + validate)
./run-otel-validation.sh all
```

### Step-by-Step Execution

```bash
# Setup cluster with OSP v1.23.0
./run-otel-validation.sh setup

# Run test workload (1000+ PipelineRuns)
./run-otel-validation.sh test

# Collect and validate metrics
./run-otel-validation.sh validate

# Cleanup test resources (optional)
./run-otel-validation.sh cleanup
```

### Configuration Variables

**Deployment Settings**:
```bash
export DEPLOYMENT_TYPE="downstream"           # "downstream" or "upstream"
export DEPLOYMENT_VERSION="1.23"              # OSP version
export CUSTOM_BUILD="true"                    # Use custom build
export CUSTOM_BUILD_TAG="v1.23.0"            # Custom build tag
```

**Pipelines Performance Tuning**:
```bash
export DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS="3"
export DEPLOYMENT_PIPELINES_KUBE_API_QPS="100"
export DEPLOYMENT_PIPELINES_KUBE_API_BURST="200"
export DEPLOYMENT_PIPELINES_THREADS_PER_CONTROLLER="32"
```

**Test Parameters**:
```bash
export TEST_SCENARIO="math"                   # Test scenario name
export TEST_TOTAL="1000"                      # Total PipelineRuns
export TEST_CONCURRENT="20"                   # Concurrent execution
export TEST_NAMESPACE="5"                     # Number of namespaces
export TEST_TIMEOUT="18000"                   # Timeout in seconds
```

### Output Files

After validation:
- `artifacts/otel-metrics-raw.json` - Raw metric values from Prometheus
- `artifacts/otel-validation-report.json` - Validation results
- `artifacts/benchmark-tekton.json` - Performance test results

### Expected Metrics (38 total)

**Core Metrics (16)**:
- `pipelinerun_total`, `pipelinerun_duration_seconds`
- `taskrun_total`, `taskrun_duration_seconds`
- `running_pipelineruns_count`, `running_taskruns_count`
- Pod latency metrics (4 histograms)
- CloudEvents metrics (2 counters)

**Workqueue Metrics (8)**:
- `kn_workqueue_adds_total`, `kn_workqueue_depth`
- `kn_workqueue_process_duration_seconds`, `kn_workqueue_queue_duration_seconds`
- `kn_workqueue_retries_total`, `kn_workqueue_unfinished_work_seconds`

**Runtime Metrics (14)**:
- Process: `process_cpu_seconds_total`, `process_resident_memory_bytes`
- Go: `go_goroutines`, `go_gc_duration_seconds`, `go_memstats_*`

## Chains OTEL Validation

Validates 26 Tekton Chains OpenTelemetry metrics.

### Quick Start

```bash
# 1. Login to cluster
oc login <cluster-url> --username <user> --password <pass>

# 2. Activate virtual environment
source venv/bin/activate

# 3. Run full test with validation
./run-chains-otel-test.sh all
```

### Step-by-Step Execution

```bash
# Setup cluster with Chains enabled
./run-chains-otel-test.sh setup

# Run signing test workload
./run-chains-otel-test.sh test

# Collect and validate Chains metrics
./run-chains-otel-test.sh collect
```

### Standalone Validation

If Chains is already running with signing workload:

```bash
./run-chains-otel-validation.sh
```

### Configuration Variables

**Deployment Settings**:
```bash
export DEPLOYMENT_TYPE="downstream"
export DEPLOYMENT_VERSION="1.23"
export CUSTOM_BUILD="true"
export CUSTOM_BUILD_TAG="v1.23.0"
```

**Chains Performance Tuning**:
```bash
export DEPLOYMENT_CHAINS_KUBE_API_QPS="50"
export DEPLOYMENT_CHAINS_KUBE_API_BURST="50"
export DEPLOYMENT_CHAINS_THREADS_PER_CONTROLLER="32"
```

**Test Parameters**:
```bash
export TEST_SCENARIO="signing-tr-tekton-bigbang"  # Signing scenario
export TEST_TOTAL="200"                           # Total PipelineRuns
export TEST_CONCURRENT="10"                       # Concurrent execution
export TEST_NAMESPACE="5"                         # Number of namespaces
export TEST_TIMEOUT="36000"                       # Timeout in seconds
```

### Output Files

After validation:
- `artifacts/chains-otel-metrics-raw.json` - Raw Chains metrics
- `artifacts/chains-otel-metrics-complete.json` - Complete dataset
- `artifacts/chains-otel-metrics-report.txt` - Validation report

### Expected Metrics (26 total)

**Signing Metrics (6)**:
- PipelineRun: `watcher_pipelinerun_sign_created_total`, `watcher_pipelinerun_payload_stored_total`, `watcher_pipelinerun_marked_signed_total`
- TaskRun: `watcher_taskrun_sign_created_total`, `watcher_taskrun_payload_stored_total`, `watcher_taskrun_marked_signed_total`

**Workqueue Metrics (8)**: Same as Pipelines

**Runtime Metrics (12+)**: Same as Pipelines

## Troubleshooting

### "Not logged into cluster"

```bash
oc login <cluster-url> --username <user> --password <pass>
oc whoami  # Verify connection
```

### "jq: command not found"

```bash
# macOS
brew install jq

# RHEL/CentOS
sudo yum install jq
```

### "ModuleNotFoundError: No module named 'kubernetes'"

```bash
source venv/bin/activate
pip install -r requirements-otel.txt
```

### "Prometheus route not found"

Ensure you have access to openshift-monitoring:

```bash
oc get route -n openshift-monitoring
oc whoami  # Must have monitoring access
```

### "All metrics showing null"

**For Pipelines**: Ensure test workload has completed:
```bash
oc get pipelineruns -n benchmark --no-headers | wc -l
```

**For Chains**: Ensure signing is enabled and PipelineRuns are signed:
```bash
oc get pipelineruns -n benchmark1 -o json | jq '.items[].metadata.annotations["chains.tekton.dev/signed"]'
```

### Metrics not in Prometheus

Metrics may take 1-2 minutes to be scraped. For immediate validation, query the controller pod directly:

```bash
# Pipelines controller
oc exec -n openshift-pipelines deployment/tekton-pipelines-controller -- curl -s localhost:9090/metrics | grep pipelinerun_total

# Chains controller
oc exec -n openshift-pipelines $(oc get pod -n openshift-pipelines -l app=tekton-chains-controller -o name | head -1) -- curl -s localhost:9090/metrics | grep watcher_pipelinerun_sign_created_total
```

## CI/CD Integration

### Prow Job Integration

Add to `.prow.yaml`:

```yaml
- name: otel-validation
  interval: 24h
  spec:
    containers:
    - image: registry.ci.openshift.org/ocp/builder:rhel-8-golang-1.21-openshift-4.16
      command:
      - /bin/bash
      - -c
      - |
        ./run-otel-validation.sh all
        ./run-chains-otel-test.sh all
```

### Manual CI Run

```bash
# Run both validations
./run-otel-validation.sh all && ./run-chains-otel-test.sh all

# Check results
cat artifacts/otel-validation-report.json
cat artifacts/chains-otel-metrics-report.txt
```

## Metric Reference Files

**Pipelines**: `config/otel-metrics-reference.json`
- Defines expected 38 metrics for Tekton Pipelines
- Based on https://github.com/tektoncd/pipeline/pull/10355

**Chains**: `config/chains-otel-metrics-reference.json`
- Defines expected 26 metrics for Tekton Chains
- Based on https://github.com/tektoncd/chains/pull/1735

## Success Criteria

### Pipelines Validation

✅ **PASS**: All 38 metrics present and collecting data  
✅ **PASS**: `pipelinerun_total` > 0  
✅ **PASS**: `kn_workqueue_*` metrics present (new naming)  
✅ **PASS**: Coverage ≥ 95%

### Chains Validation

✅ **PASS**: All 6 signing metrics present  
✅ **PASS**: `watcher_*_sign_created_total` > 0  
✅ **PASS**: `sign_created == marked_signed` (100% success rate)  
✅ **PASS**: Coverage = 100%

## Related Documentation

- Pipelines OTEL PR: https://github.com/tektoncd/pipeline/pull/10355
- Chains OTEL PR: https://github.com/tektoncd/chains/pull/1735
- OpenShift Pipelines: https://docs.openshift.com/pipelines/

## Support

For issues or questions:
1. Check artifacts in `artifacts/` directory
2. Review controller logs: `oc logs -n openshift-pipelines deployment/tekton-pipelines-controller`
3. Verify Prometheus access: `oc get route -n openshift-monitoring`
