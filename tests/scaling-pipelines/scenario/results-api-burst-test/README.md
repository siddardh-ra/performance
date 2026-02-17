# "results-api-burst-test" scenario

This scenario is designed to test the hypothesis that Tekton Results may fail to store PipelineRuns during API latency spikes caused by sudden bursts of PipelineRun creation.

## Problem Statement

Ford observed a count mismatch between:
- **Console Dashboard** (which gets data from Tekton Results): Shows X PipelineRuns
- **Prometheus metrics** (`sum by (service) (increase (tekton_pipelines_controller_pipelinerun_total[7d]))`): Shows ~10% more PipelineRuns

The hypothesis is that during API latency spikes (caused by sudden bursts of PipelineRun creation), Tekton Results may fail to store some PipelineRuns, leading to the discrepancy.

## Scenario Design

This scenario simulates a burst pattern to test this hypothesis:

1. **Phase 1 (Baseline)**: Run at **1 concurrency for 10 minutes**
   - Establishes baseline performance
   - Allows Tekton Results API to operate under normal load

2. **Phase 2 (Burst)**: Burst to **300 concurrency for 1 minute**
   - Simulates sudden spike in PipelineRun creation
   - Tests if Tekton Results can handle the burst without losing PipelineRuns
   - This is the critical phase where API latency spikes are expected

3. **Phase 3 (Baseline)**: Return to **1 concurrency for 10 minutes**
   - Allows system to stabilize after the burst
   - Enables comparison of counts after the burst period

## Expected Outcome

After running this scenario, you can compare:
- **Prometheus metrics**: Total PipelineRuns created (from `tekton_pipelines_controller_pipelinerun_total`)
- **Tekton Results API**: PipelineRuns stored in Results (from Console Dashboard or Results API queries)
- **Kubernetes API**: Actual PipelineRuns in the cluster

If the hypothesis is correct, we should see:
- Prometheus metrics showing all PipelineRuns created
- Tekton Results showing fewer PipelineRuns (especially those created during the burst phase)
- The discrepancy should be visible in the burst phase

## Environment Variables

### PipelineRun Payload Size:
- **TEST_BIGBANG_MULTI_STEP__TASK_COUNT**: Total number of tasks per Pipeline (Default: 5 tasks)
- **TEST_BIGBANG_MULTI_STEP__STEP_COUNT**: Total number of steps per Task (Default: 5 steps)
- **TEST_BIGBANG_MULTI_STEP__LINE_COUNT**: Total number of unique output log lines per step (Default: 5 lines)

### Chains Control (Disabled by Default):
- **CHAINS_ENABLE_TIME**: Set to a time in seconds to enable Chains at a specific time (Default: `false` - Chains disabled)

### Pruner:
- Pruner is enabled by default in this scenario

## Usage

```bash
# Set environment variables
export TEST_SCENARIO=results-api-burst-test
export TEST_TOTAL=100000  # Large number to allow continuous creation during the test
export TEST_CONCURRENT=1   # Initial concurrency (will be varied by setup.sh)
export TEST_NAMESPACE=1

# Run the scenario
cd tests/scaling-pipelines
../../ci-scripts/load-test.sh
```

## Output and Counts

After running the scenario, the framework automatically collects and stores counts in `artifacts/benchmark-tekton.json`. Here's what you'll get:

### Automatically Collected Counts:

1. **Tekton Results API Count (Console Dashboard)** ✅
   - **Location**: `artifacts/benchmark-tekton.json` → `.results.ResultsAPI.pipelineruns.count`
   - **What it is**: The count of PipelineRuns stored in Tekton Results (same as Console Dashboard)
   - **Collected automatically** by `ci-scripts/collect-results.sh`

2. **Tekton Results DB Count** ✅
   - **Location**: `artifacts/benchmark-tekton.json` → `.results.ResultsDB.queries[]`
   - **What it is**: Direct database query count of PipelineRuns in Results database
   - **Collected automatically** by `ci-scripts/collect-results.sh`

3. **Kubernetes API Count** ✅
   - **Location**: `artifacts/pipelineruns.json` (full list) and `artifacts/benchmark-tekton.json` → `.results.PipelineRuns.count.*`
   - **What it is**: Actual PipelineRuns in the cluster (from kubectl)
   - **Collected automatically** by `tools/stats.sh`

### Prometheus Count (Manual Query Required):

4. **Prometheus Metrics** ⚠️
   - **Location**: Not automatically collected (needs manual query)
   - **What it is**: `tekton_pipelines_controller_pipelinerun_total` - total PipelineRuns created according to the controller
   - **How to get it**: Use the provided tools (see below)

## Analysis

### Quick Analysis (Recommended)

Use the built-in analysis script that compares all available counts:

```bash
cd artifacts
../../tools/analyze-metrics-discrepancy.sh benchmark-tekton.json
```

This will show you:
- Expected count (TEST_TOTAL)
- Results API count (Console Dashboard)
- Results DB count
- Prometheus count (if queried)
- **Discrepancy calculations** with percentages
- **Warnings** if discrepancy > 5% (matching the ~10% issue)

### Manual Prometheus Query

To get the Prometheus count for your test time range:

```bash
# Option 1: Query for the test duration (22 minutes)
cd tools
./query-prometheus-pipelinerun-total.sh 22m

# Option 2: Query for specific time range (more accurate)
./query-prometheus-by-time-range.sh <start_time> <end_time>
# Times can be found in artifacts/benchmark-tekton.json:
# jq -r '.results.started, .results.ended' artifacts/benchmark-tekton.json

# Option 3: Query Results DB directly (most accurate for your namespace)
./query-results-db.sh "SELECT count(*) FROM records WHERE type LIKE '%PipelineRun%' AND parent = 'benchmark';"
```

### Expected Output Example

After running `analyze-metrics-discrepancy.sh`, you'll see something like:

```
=== PipelineRun Count Discrepancy Analysis ===

1. Expected PipelineRun Count (TEST_TOTAL): 100000

2. Tekton Results API Count (Console Dashboard): 90000
   Timestamp: 2025-01-15T10:30:00Z

3. Tekton Results DB Counts:
   Query: select type, count(*) from records group by type
   Result: PipelineRun: 90000

4. Prometheus Metrics:
   tekton_pipelines_controller_pipelinerun_total: 100000

=== Discrepancy Analysis ===

Prometheus vs Results API:
  Prometheus: 100000
  Results API: 90000
  Difference: 10000 PipelineRuns
  Percentage: 10.00%
  ⚠️  WARNING: Significant discrepancy detected (>5%)
  This matches the customer-reported ~10% discrepancy!
```

This will help you identify if PipelineRuns are lost during the burst phase.

## Notes

- The scenario uses dynamic concurrency control via `concurrency.txt` file
- The `benchmark.py` script reads from this file periodically to adjust concurrency
- Total test duration is approximately 22 minutes (10 + 1 + 10 minutes + buffer)
- This scenario **supports** multi-namespace testing through *TEST_NAMESPACE* env variable

## Optional: Auto-Collect Prometheus Metrics

To automatically collect Prometheus metrics in `benchmark-tekton.json`, add this to `config/cluster_read_config.yaml`:

```yaml
- name: measurements.tekton_pipelines_controller_pipelinerun_total
  monitoring_query: sum(increase(tekton_pipelines_controller_pipelinerun_total[1m]))
  monitoring_step: 15
```

However, note that this collects a time series, not a single count. For the exact count matching Ford's query, use the manual query tools mentioned above.

## Visualization

### Plot Running PipelineRuns Over Time

To visualize the burst pattern (showing how running PipelineRuns change over time), use the provided plotting script:

```bash
# After running the test, generate the plot
cd tools
python3 plot-running-pipelineruns.py \
    --stats-file ../artifacts/benchmark-stats.csv \
    --output ../artifacts/running-pipelineruns-over-time.png \
    --title "Results API Burst Test - Running PipelineRuns Over Time"

# Or with custom title
python3 plot-running-pipelineruns.py \
    --stats-file ../artifacts/benchmark-stats.csv \
    --title "Burst Pattern: 1 -> 300 -> 1 Concurrency"
```

The plot will show:
- **X-axis**: Timestamp (time during the test)
- **Y-axis**: Number of running PipelineRuns
- **Pattern**: Should clearly show the baseline (1), burst spike (300), and return to baseline (1)

**Requirements:**
```bash
pip install pandas matplotlib
```

**Example output:**
The plot will show a clear visualization of:
1. **Phase 1 (0-10 min)**: Low running count (~1)
2. **Phase 2 (10-11 min)**: Sharp spike to high running count (~300)
3. **Phase 3 (11-21 min)**: Return to low running count (~1)

This visual representation helps identify:
- When the burst occurred
- How long it took for the system to handle the spike
- Whether PipelineRuns were properly created during the burst
- Any anomalies in the pattern
