source scenario/common/lib.sh

# Test Scenario specific env variables
TEST_BIGBANG_MULTI_STEP__TASK_COUNT="${TEST_BIGBANG_MULTI_STEP__TASK_COUNT:-5}"
TEST_BIGBANG_MULTI_STEP__STEP_COUNT="${TEST_BIGBANG_MULTI_STEP__STEP_COUNT:-5}"
TEST_BIGBANG_MULTI_STEP__LINE_COUNT="${TEST_BIGBANG_MULTI_STEP__LINE_COUNT:-5}"

# Total timeout: 10 min (baseline) + 1 min (burst) + 10 min (baseline) + buffer = ~22 minutes
# Using 1320 seconds (22 minutes) as total timeout
TOTAL_TIMEOUT="1320"

# By default chains will be disabled
# If its set, then we consider chains to be enabled at certain time
CHAINS_ENABLE_TIME="${CHAINS_ENABLE_TIME:-false}"

chains_setup_tekton_tekton_
chains_stop

if [ "$CHAINS_ENABLE_TIME" != "false" ] && [ -n "$CHAINS_ENABLE_TIME" ]; then
    (
         wait_for_timeout $CHAINS_ENABLE_TIME "waiting for chains timeout"
         chains_start
    ) &
fi

create_pipeline_from_j2_template pipeline.yaml.j2 "task_count=${TEST_BIGBANG_MULTI_STEP__TASK_COUNT}, step_count=${TEST_BIGBANG_MULTI_STEP__STEP_COUNT}, line_count=${TEST_BIGBANG_MULTI_STEP__LINE_COUNT}"

pruner_start

# Initialize concurrency to 1 for baseline
echo 1 > scenario/$TEST_SCENARIO/concurrency.txt

# Background process to vary concurrency over time
(
    # Phase 1: Baseline at 1 concurrency for 10 minutes (600 seconds)
    info "Phase 1: Running at 1 concurrency for 10 minutes (baseline)"
    wait_for_timeout 600 "baseline performance with 1 concurrent PipelineRun"

    # Phase 2: Burst to 300 concurrency for 1 minute (60 seconds)
    info "Phase 2: Bursting to 300 concurrency for 1 minute"
    echo 300 > scenario/$TEST_SCENARIO/concurrency.txt
    wait_for_timeout 60 "burst performance with 300 concurrent PipelineRuns"

    # Phase 3: Return to baseline at 1 concurrency for 10 minutes (600 seconds)
    info "Phase 3: Returning to 1 concurrency for 10 minutes (baseline)"
    echo 1 > scenario/$TEST_SCENARIO/concurrency.txt
    wait_for_timeout 600 "baseline performance with 1 concurrent PipelineRun"

    info "Concurrency variation cycle completed"
)&

export TEST_PARAMS="--wait-for-duration=${TOTAL_TIMEOUT}"
