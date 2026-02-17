# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains performance and scale testing infrastructure for OpenShift Pipelines (downstream) and Tekton Pipelines (upstream). The test framework orchestrates load testing against OpenShift clusters, collects metrics from Prometheus, and pushes results to Horreum (change detection) and OpenSearch (historical analysis).

## Key Commands

### Running Tests Manually

1. **Setup the cluster** (install OpenShift Pipelines operator):
   ```bash
   export DEPLOYMENT_TYPE="downstream"
   export DEPLOYMENT_VERSION="1.15"
   export DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES="1/2Gi/1/2Gi"
   ci-scripts/setup-cluster.sh
   ```

2. **Run a load test**:
   ```bash
   export TEST_NAMESPACE="1"
   export TEST_DO_CLEANUP="false"
   export TEST_TOTAL="100"
   export TEST_CONCURRENT="10"
   export TEST_TIMEOUT=18000
   export TEST_SCENARIO="math"
   ci-scripts/load-test.sh
   ```

3. **Collect results**:
   ```bash
   ci-scripts/collect-results.sh
   ```

### Development Tools

- **Create PipelineRun YAML**: `tools/create-pipeline-yaml.py`
- **Show PipelineRun status**: `tools/show-pipelineruns.py`
- **Generate plots**: `tools/generate-plots.sh`
- **Query Prometheus**: `tools/query-prometheus-*.sh` scripts
- **Query Results DB**: `tools/query-results-db.sh`
- **Benchmark core script**: `tests/scaling-pipelines/benchmark-tekton.sh --total 100 --concurrent 10`

### Grafana Dashboard Generation

Dashboards are code-generated using Jsonnet and Grafonnet:

```bash
cd config/grafonnet-workdir
jb init
jb install  # Install dependencies from jsonnetfile.json
./build.sh  # Build all dashboards
```

For single dashboard: `jsonnet -J vendor dashboard.jsonnet > dashboard.json`

## Architecture

### Test Execution Flow

1. **CI Scripts** (`ci-scripts/`):
   - `setup-cluster.sh`: Deploys OpenShift Pipelines operator via OLM subscription, configures HA replicas, controller resources, and optionally installs Tekton Results API
   - `load-test.sh`: Orchestrates test execution by calling the benchmark script with environment variables
   - `collect-results.sh`: Gathers artifacts, queries Prometheus for metrics, and enriches benchmark data
   - `prow-to-storage.sh`: Pulls results from Prow CI, uploads to Horreum and OpenSearch (runs via Jenkins hourly)
   - `lib.sh`: Shared functions for logging, entity waiting, and results database queries

2. **Test Scenarios** (`tests/scaling-pipelines/scenario/`):
   - Each scenario represents a different workload type (e.g., `math`, `signing-bigbang`, `cluster-resolver`)
   - Structure per scenario:
     - `pipeline.yaml`: Tekton Pipeline and Task definitions
     - `run.yaml`: PipelineRun template with scenario-specific parameters
     - `setup.sh`: Pre-test setup (e.g., configure Tekton Chains for signing scenarios)
     - `tierdown.sh`: Post-test cleanup
     - `README.md`: Scenario description
   - Common scenario utilities in `tests/scaling-pipelines/scenario/common/lib.sh` (Chains setup, cosign key generation)

3. **Benchmark Engine** (`tests/scaling-pipelines/benchmark-tekton.sh` and `tools/benchmark.py`):
   - Uses GNU Parallel to create PipelineRuns with controlled concurrency
   - Python watcher monitors PipelineRun/TaskRun events via Kubernetes API
   - Captures completion times, annotations (Chains signing, Results API), and status
   - Outputs JSON with timestamps and CSV files with statistics

4. **Monitoring & Metrics** (`config/`):
   - `cluster_read_config.yaml`: Prometheus query definitions for CPU, memory, network metrics
   - Scenarios can override with custom `cluster_read_config.yaml`
   - Uses `opl` library (`status_data.py`) to query Prometheus and enrich JSON results

5. **Visualization** (`tools/plots/`, `config/grafonnet-workdir/`):
   - Python plotting tools in `tools/plots/`
   - Jsonnet-based Grafana dashboard generation using Grafonnet library
   - Dashboards backed up in Git after generation

### Key Data Flows

**Test Data Path**:
```
Benchmark Script → PipelineRuns created → Watcher captures events → benchmark-tekton.json
→ collect-results.sh queries Prometheus → enriched JSON with metrics
→ Horreum (change detection) + OpenSearch (historical storage)
```

**CI/CD Integration**:
- Prow jobs defined in `openshift/release` repo trigger tests twice daily
- Jenkins puller runs hourly via `prow-to-storage.sh` to upload results
- Change detection in Horreum marks results as PASS/FAIL based on regression thresholds

### Important Patterns

1. **Multi-namespace testing**: Set `TEST_NAMESPACE=N` to spread load across N namespaces (`benchmark0`, `benchmark1`, ..., `benchmarkN-1`)

2. **Deployment configurations**:
   - Regular builds: Set `DEPLOYMENT_VERSION` (e.g., "1.15")
   - Nightly builds: Set `NIGHTLY_BUILD=true` (no version needed)
   - Custom builds: Set `CUSTOM_BUILD=true` and `CUSTOM_BUILD_TAG="1.20"`

3. **Tekton Chains scenarios**: Scenarios with `signing-*` prefix test artifact signing with Tekton Chains
   - Chains configuration via `chains_setup_*()` functions in `common/lib.sh`
   - Cosign keys stored in `signing-secrets` secret in `openshift-pipelines` namespace

4. **Results API scenarios**: Scenarios with `results-api-*` test Tekton Results API for result persistence
   - Installed when `INSTALL_RESULTS=true` in setup-cluster.sh
   - DB queries via PostgreSQL in `tekton-results-postgres-0` pod

5. **Annotations tracking**: Benchmark captures specific Tekton annotations (chains.tekton.dev/signed, results.tekton.dev/*) to measure feature impact on latency

## Environment Variables Reference

**Setup variables** (setup-cluster.sh):
- `DEPLOYMENT_TYPE`: "downstream" or "upstream"
- `DEPLOYMENT_VERSION`: Version string (e.g., "1.15") - required for regular builds
- `NIGHTLY_BUILD`: "true" for nightly builds
- `CUSTOM_BUILD`: "true" for custom builds
- `CUSTOM_BUILD_TAG`: Tag for custom builds (e.g., "1.20")
- `DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS`: HA replicas count
- `DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES`: "requests.cpu/requests.memory/limits.cpu/limits.memory"
- `DEPLOYMENT_PIPELINES_KUBE_API_QPS`: kube-apiserver QPS
- `DEPLOYMENT_PIPELINES_KUBE_API_BURST`: kube-apiserver burst
- `DEPLOYMENT_PIPELINES_THREADS_PER_CONTROLLER`: Controller threads
- `INSTALL_RESULTS`: "true" to install Tekton Results API

**Test variables** (load-test.sh):
- `TEST_SCENARIO`: Scenario name (e.g., "math", "signing-bigbang")
- `TEST_TOTAL`: Total PipelineRuns to create
- `TEST_CONCURRENT`: Concurrent PipelineRuns
- `TEST_NAMESPACE`: Number of namespaces (default "1")
- `TEST_DO_CLEANUP`: "true"/"false" to cleanup after test
- `TEST_TIMEOUT`: Test timeout in seconds

**Artifact variables**:
- `ARTIFACT_DIR`: Output directory for results (default "artifacts")

## External Integrations

**Horreum** (https://horreum.corp.redhat.com/):
- Test: [openshift-pipelines-perfscale-scalingPipelines](https://horreum.corp.redhat.com/test/295)
- Schema: [urn:openshift-pipelines-perfscale-scalingPipelines:0.1](https://horreum.corp.redhat.com/schema/177)
- Change detection configuration identifies performance regressions

**OpenSearch/Kibana** (http://kibana.intlab.perf-infra.lab.eng.rdu2.redhat.com/):
- Index: `pipelines_ci_status_data`
- Dashboard JSON backed up in `config/kibana/`

**Prow CI**:
- Jobs: `periodic-ci-openshift-pipelines-performance-master-scaling-pipelines-daily`
- History: https://prow.ci.openshift.org/job-history/gs/origin-ci-test/logs/periodic-ci-openshift-pipelines-performance-master-scaling-pipelines-daily

## Code Structure Notes

- **Cross-platform compatibility**: Scripts support both Linux and macOS (see date command handling in `lib.sh` and `collect-results.sh`)
- **Python venv**: Virtual environment created in `collect-results.sh` for `opl` library usage
- **GNU Parallel dependency**: Required for benchmark script to orchestrate concurrent PipelineRun creation
- **Immutable secrets**: `signing-secrets` checks immutability before recreation to avoid conflicts
