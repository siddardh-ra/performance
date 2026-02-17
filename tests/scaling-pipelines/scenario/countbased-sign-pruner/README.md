# "countbased-sign-pruner" scenario

This scenario is designed to create a **fixed number** of PipelineRuns (controlled by `TEST_TOTAL`) to enable precise comparison between:
- Expected PipelineRun count (TEST_TOTAL)
- Prometheus metrics (`tekton_pipelines_controller_pipelinerun_total`)
- Tekton Results API counts (Console Dashboard data)
- Tekton Results DB counts

This helps identify where PipelineRuns are "lost" and why there's a discrepancy between Prometheus metrics and Results API.

The scenario creates PipelineRuns at a constant rate controlled by `TEST_CONCURRENT`. Chains and Pruner are enabled at specific times during the test to simulate real-world conditions where some PipelineRuns may be pruned before being captured by Results.

## Environment Variables

### PipelineRun Count Control:
- **TEST_TOTAL**: Total number of PipelineRuns to create (Default: 1000)
- **TEST_CONCURRENT**: Number of concurrent PipelineRuns (Default: 10)

### Chains and Pruner Control (Disabled by Default):
- **ENABLE_CHAINS**: Set to `"true"` to enable Chains (Default: `false` - baseline mode)
- **ENABLE_PRUNER**: Set to `"true"` to enable Pruner (Default: `false` - baseline mode)
- **CHAINS_WAIT_TIME**: Wait period before enabling chains in seconds (Default: 60 seconds)
- **PRUNER_WAIT_TIME**: Wait period before enabling pruner in seconds (Default: 300 seconds / 5 minutes)
- **PRUNER_KEEP**: Number of PipelineRuns to keep when pruning (Default: 10)
- **PRUNER_SCHEDULE**: Cron schedule for pruner (Default: `*/2 * * * *` - every 2 minutes)

### PR/TR Payload Size:
- **TEST_BIGBANG_MULTI_STEP__TASK_COUNT**: Total number of tasks per Pipeline (Default: 5 tasks)
- **TEST_BIGBANG_MULTI_STEP__STEP_COUNT**: Total number of steps per Task (Default: 10 steps)
- **TEST_BIGBANG_MULTI_STEP__LINE_COUNT**: Total number of unique output log lines per step (Default: 15 lines)

### Locust Test Parameters (Optional):
- **RUN_LOCUST**: Set to "true" to run Locust API tests after PipelineRuns complete (Default: false)
- **LOCUST_USERS**: Total number of users to spawn (Default: 100)
- **LOCUST_SPAWN_RATE**: Number of users to spawn every second (Default: 10)
- **LOCUST_DURATION**: Total duration for locust testing (Default: 15m)
- **LOCUST_WORKERS**: Number of Locust worker pods (Default: 5)
- **LOCUST_EXTRA_CMD**: Additional Locust Command-line parameters.

## Usage Example

### Baseline Test (Chains and Pruner Disabled):
```bash
export TEST_SCENARIO="countbased-sign-pruner"
export TEST_TOTAL=1000              # Create exactly 1000 PipelineRuns
export TEST_CONCURRENT=20            # Create 20 at a time
# Chains and Pruner are disabled by default for baseline

./ci-scripts/load-test.sh
```

### With Pruner Enabled (After Baseline):
```bash
export TEST_SCENARIO="countbased-sign-pruner"
export TEST_TOTAL=1000              # Create exactly 1000 PipelineRuns
export TEST_CONCURRENT=20            # Create 20 at a time
export ENABLE_PRUNER=true           # Enable Pruner
export PRUNER_WAIT_TIME=300          # Enable Pruner after 5 minutes
export PRUNER_KEEP=10                # Keep only 10 most recent PRs
export PRUNER_SCHEDULE="*/2 * * * *" # Prune every 2 minutes

./ci-scripts/load-test.sh
```

### With Both Chains and Pruner Enabled:
```bash
export TEST_SCENARIO="countbased-sign-pruner"
export TEST_TOTAL=1000
export TEST_CONCURRENT=20
export ENABLE_CHAINS=true            # Enable Chains
export ENABLE_PRUNER=true            # Enable Pruner
export CHAINS_WAIT_TIME=60           # Enable Chains after 1 minute
export PRUNER_WAIT_TIME=300          # Enable Pruner after 5 minutes
export PRUNER_KEEP=10
export PRUNER_SCHEDULE="*/2 * * * *"

./ci-scripts/load-test.sh
```

## Expected Output

After the test completes, you can compare:
1. **Expected**: `TEST_TOTAL` (e.g., 1000)
2. **Prometheus**: `sum by (service) (increase(tekton_pipelines_controller_pipelinerun_total[<test_duration>]))`
3. **Results API**: `.results.ResultsAPI.pipelineruns.count` in `benchmark-tekton.json`
4. **Results DB**: `.results.ResultsDB.queries` in `benchmark-tekton.json`

The discrepancy analysis will show where PipelineRuns are being lost (pruned before Results capture, watcher failures, etc.).

This scenario **supports** multi-namespace testing through *TEST_NAMESPACE* env variable.

