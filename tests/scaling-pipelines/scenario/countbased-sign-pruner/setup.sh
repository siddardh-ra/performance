source scenario/common/lib.sh

# Test Scenario specific env variables
TEST_BIGBANG_MULTI_STEP__TASK_COUNT="${TEST_BIGBANG_MULTI_STEP__TASK_COUNT:-5}"
TEST_BIGBANG_MULTI_STEP__STEP_COUNT="${TEST_BIGBANG_MULTI_STEP__STEP_COUNT:-10}"
TEST_BIGBANG_MULTI_STEP__LINE_COUNT="${TEST_BIGBANG_MULTI_STEP__LINE_COUNT:-15}"

# Wait period before enabling chains/pruner (if enabled)
# These should be set to reasonable values based on TEST_TOTAL and TEST_CONCURRENT
CHAINS_WAIT_TIME=${CHAINS_WAIT_TIME:-60}   # [Default: 60 seconds / 1 minute]
PRUNER_WAIT_TIME=${PRUNER_WAIT_TIME:-300}  # [Default: 300 seconds / 5 minutes]

# Pruner configuration (if enabled)
PRUNER_KEEP=${PRUNER_KEEP:-10}             # [Default: Keep 10 most recent PRs]
PRUNER_SCHEDULE=${PRUNER_SCHEDULE:-"*/2 * * * *"}  # [Default: Every 2 minutes]

# Control flags for Chains and Pruner (set to "true" to enable)
ENABLE_CHAINS=${ENABLE_CHAINS:-false}
ENABLE_PRUNER=${ENABLE_PRUNER:-false}

# Setup Chains but keep it disabled initially
chains_setup_tekton_tekton_

# Stop Chains and Pruner initially (baseline mode)
chains_stop
pruner_stop

# Optionally enable Chains if ENABLE_CHAINS=true
if [ "${ENABLE_CHAINS}" == "true" ]; then
    info "Chains will be enabled after ${CHAINS_WAIT_TIME} seconds"
    (
        wait_for_timeout $CHAINS_WAIT_TIME "enable Chains"
        chains_start
    ) &
else
    info "Chains disabled (baseline mode). Set ENABLE_CHAINS=true to enable."
fi

# Optionally enable Pruner if ENABLE_PRUNER=true
# Note: pruner_start function uses PRUNER_KEEP and PRUNER_SCHEDULE env vars
if [ "${ENABLE_PRUNER}" == "true" ]; then
    info "Pruner will be enabled after ${PRUNER_WAIT_TIME} seconds (keeping ${PRUNER_KEEP} PRs, schedule: ${PRUNER_SCHEDULE})"
    (
        wait_for_timeout $PRUNER_WAIT_TIME "enable Pruner"
        pruner_start
    ) &
else
    info "Pruner disabled (baseline mode). Set ENABLE_PRUNER=true to enable."
fi

# Note: We don't set TEST_PARAMS with --wait-for-duration
# Instead, we rely on TEST_TOTAL to control the number of PipelineRuns created
# The benchmark.py script will create exactly TEST_TOTAL PipelineRuns

info "Scenario configured to create ${TEST_TOTAL:-1000} PipelineRuns"
info "Baseline mode: Chains=${ENABLE_CHAINS}, Pruner=${ENABLE_PRUNER}"

create_pipeline_from_j2_template pipeline.yaml.j2 "task_count=${TEST_BIGBANG_MULTI_STEP__TASK_COUNT}, step_count=${TEST_BIGBANG_MULTI_STEP__STEP_COUNT}, line_count=${TEST_BIGBANG_MULTI_STEP__LINE_COUNT}"

