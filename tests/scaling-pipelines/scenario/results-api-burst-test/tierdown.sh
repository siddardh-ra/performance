source scenario/common/lib.sh

info "Tierdown for results-api-burst-test scenario"

# Stop any background processes that might be updating concurrency
# (The background process in setup.sh should complete naturally, but this is a safety measure)

# Stop pruner if it was started
pruner_stop

# Stop chains if they were enabled
chains_stop

info "Tierdown completed"
