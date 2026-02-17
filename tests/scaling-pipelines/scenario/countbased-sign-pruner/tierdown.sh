source scenario/common/lib.sh

# Wait for all PipelineRuns to complete before collecting metrics
# This ensures we capture accurate counts
info "Waiting for all PipelineRuns to complete..."
wait_for_prs_finished ${TEST_TOTAL:-1000}

# Wait additional time for Results watcher to sync all records
# This gives Results API time to capture all PipelineRuns before we query
RESULTS_SYNC_WAIT_TIME=${RESULTS_SYNC_WAIT_TIME:-120}  # [Default: 2 minutes]
info "Waiting ${RESULTS_SYNC_WAIT_TIME} seconds for Results watcher to sync records..."
wait_for_timeout $RESULTS_SYNC_WAIT_TIME "Results watcher sync"

# Optional: Run Locust API tests if enabled
if [ "${RUN_LOCUST:-false}" == "true" ]; then
    info "Running Locust API load tests..."
    
    # Locust test configurations
    LOCUST_HOST="https://tekton-results-api-service.openshift-pipelines.svc.cluster.local:8080"
    LOCUST_USERS=${LOCUST_USERS:-100}
    LOCUST_SPAWN_RATE=${LOCUST_SPAWN_RATE:-10}
    LOCUST_DURATION="${LOCUST_DURATION:-15m}"
    LOCUST_WORKERS=${LOCUST_WORKERS:-5}
    LOCUST_EXTRA_CMD="${LOCUST_EXTRA_CMD:-}"
    LOCUST_WAIT_TIME=${LOCUST_WAIT_TIME:-60} # [Default: 1 minute]

    # Wait before starting locust test
    wait_for_timeout $LOCUST_WAIT_TIME "start Locust test"

    # Run fetch-log loadtest scenario
    run_locust "fetch-log" $LOCUST_HOST $LOCUST_USERS $LOCUST_SPAWN_RATE $LOCUST_DURATION $LOCUST_WORKERS "$LOCUST_EXTRA_CMD"

    # Run fetch-record loadtest scenario
    run_locust "fetch-record" $LOCUST_HOST $LOCUST_USERS $LOCUST_SPAWN_RATE $LOCUST_DURATION $LOCUST_WORKERS "$LOCUST_EXTRA_CMD"

    # Run fetch-all-records loadtest scenario
    run_locust "fetch-all-records" $LOCUST_HOST $LOCUST_USERS $LOCUST_SPAWN_RATE $LOCUST_DURATION $LOCUST_WORKERS "$LOCUST_EXTRA_CMD"
else
    info "Skipping Locust tests (set RUN_LOCUST=true to enable)"
fi

# Update test end time
set_ended_now

# Log summary for discrepancy analysis
info "=== Test Summary ==="
info "Expected PipelineRuns: ${TEST_TOTAL:-1000}"
info "Check benchmark-tekton.json for:"
info "  - Prometheus metrics: .measurements.tekton_pipelines_controller_pipelinerun_total"
info "  - Results API count: .results.ResultsAPI.pipelineruns.count"
info "  - Results DB counts: .results.ResultsDB.queries"


