function _log() {
    # Cross-platform ISO 8601 timestamp (macOS compatible)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "$( date -u +"%Y-%m-%dT%H:%M:%S.000000Z" ) $1 $2" >&1
    else
        echo "$( date -Ins --utc ) $1 $2" >&1
    fi
}

function debug() {
    _log DEBUG "$1"
}

function info() {
    _log INFO "$1"
}

function warning() {
    _log WARNING "$1"
}

function error() {
    _log ERROR "$1"
}

function fatal() {
    _log FATAL "$1"
    exit 1
}

function entity_by_selector_exists() {
    local ns
    local entity
    local l
    local expected
    local count

    ns="$1"
    entity="$2"
    l="$3"
    expected="${4:-}"   # Expect this much entities, if not set, expect more than 0

    count=$( kubectl -n "$ns" get "$entity" -l "$l" -o name 2>/dev/null | wc -l )

    if [ -n "$expected" ]; then
        debug "Number of $entity entities in $ns with label $l: $count out of $expected"
        if [ "$count" -eq "$expected" ]; then
            return 0
        fi
    else
        debug "Number of $entity entities in $ns with label $l: $count"
        if [ "$count" -gt 0 ]; then
            return 0
        fi
    fi

    return 1
}

function wait_for_entity_by_selector() {
    local timeout
    local ns
    local entity
    local l
    local expected
    local before
    local now

    timeout="$1"
    ns="$2"
    entity="$3"
    l="$4"
    expected="${5:-}"

    before=$(date -u +%s)

    while ! entity_by_selector_exists "$ns" "$entity" "$l" "$expected"; do
        now=$(date -u +%s)
        if [[ $(( now - before )) -ge "$timeout" ]]; then
            fatal "Required $entity did not appeared before timeout"
        fi
        debug "Still not ready ($(( now - before ))/$timeout), waiting and trying again"
        sleep 3
    done
}

function capture_results_db_query(){
    local pg_user=$1
    local pg_pwd=$2
    local pg_db=$3
    local query=$4
    local output_file=$5

    local result
    result=$(oc -n openshift-pipelines exec -i tekton-results-postgres-0 -- bash -c "PGPASSWORD=$pg_pwd psql -d $pg_db -U $pg_user -c \"SELECT json_agg(t) from ($query) t\" --tuples-only --no-align ")
    
    if [ -z "$result" ]; then
        warning "No results found or query failed."
        return
    fi

    # Create the JSON structure for the current query
    local new_entry
    new_entry=$(jq -n --arg query "$query" --argjson result "$result" '
        {query: $query, result: $result}'
    )

    # Check if the output file exists
    if [ -f "$output_file" ]; then
        # Append to existing JSON array in the file
        jq --argjson new_entry "$new_entry" '.results.ResultsDB.queries += [$new_entry]' "$output_file" > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"
    else
        # Create a new JSON array and add the new entry
        echo "{}" | jq ".results.ResultsDB.queries = [$new_entry]" > "$output_file"
    fi
}

function capture_results_api_metrics(){
    local output_file=$1
    local token=$2

    info "Collecting Results API metrics (Console Dashboard data)"

    # Try to find a Results API pod to exec into, or use route
    local results_api_pod
    results_api_pod=$(kubectl -n openshift-pipelines get pod -l app.kubernetes.io/name=tekton-results-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    local api_base_url=""
    local use_pod_exec=false

    if [ -n "$results_api_pod" ]; then
        # Use pod exec to query the API (most reliable)
        debug "Querying Results API via pod exec: $results_api_pod"
        api_base_url="https://tekton-results-api-service.openshift-pipelines.svc.cluster.local:8080"
        use_pod_exec=true
    else
        # Fallback: try to use route if available
        local results_api_route
        results_api_route=$(kubectl -n openshift-pipelines get route tekton-results-api -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
        
        if [ -n "$results_api_route" ]; then
            debug "Querying Results API via route: $results_api_route"
            api_base_url="https://${results_api_route}"
            use_pod_exec=false
        else
            warning "Results API pod or route not found, skipping API metrics collection"
            return
        fi
    fi

    # Collect all records with pagination
    local all_records="[]"
    local page_token=""
    local page_size=1000  # Request large page size
    local total_pages=0
    local api_error=""

    info "Fetching all records from Results API (with pagination)..."
    
    while true; do
        local api_response=""
        local url="${api_base_url}/apis/results.tekton.dev/v1alpha2/parents/-/results/-/records?page_size=${page_size}"
        
        if [ -n "$page_token" ]; then
            url="${url}&page_token=${page_token}"
        fi

        if [ "$use_pod_exec" == "true" ]; then
            api_response=$(oc -n openshift-pipelines exec "$results_api_pod" -- curl -s -k \
                -H "Authorization: Bearer $token" \
                "$url" 2>&1) || api_error="$api_response"
        else
            api_response=$(curl -s -k -H "Authorization: Bearer $token" "$url" 2>&1) || api_error="$api_response"
        fi

        if [ -n "$api_error" ] || [ -z "$api_response" ]; then
            warning "Failed to query Results API: ${api_error:-empty response}"
            break
        fi

        # Check if response is valid JSON
        if ! echo "$api_response" | jq empty 2>/dev/null; then
            warning "Results API returned invalid JSON response"
            debug "Response: ${api_response:0:200}"
            break
        fi

        # Extract records from this page
        local page_records
        page_records=$(echo "$api_response" | jq -r '.records // []' 2>/dev/null || echo "[]")
        
        # Merge with all_records
        all_records=$(echo "$all_records" | jq --argjson page "$page_records" '. + $page' 2>/dev/null || echo "$all_records")

        # Check for next page token
        page_token=$(echo "$api_response" | jq -r '.next_page_token // ""' 2>/dev/null || echo "")
        total_pages=$((total_pages + 1))
        
        local page_count
        page_count=$(echo "$page_records" | jq 'length' 2>/dev/null || echo "0")
        debug "Fetched page $total_pages: $page_count records"

        # If no next page token, we're done
        if [ -z "$page_token" ] || [ "$page_token" == "null" ] || [ "$page_token" == "" ]; then
            break
        fi
    done

    # Parse all records and extract counts
    local pipelinerun_count taskrun_count total_records
    
    # Count PipelineRuns (try multiple type patterns)
    pipelinerun_count=$(echo "$all_records" | jq -r '[.[]? | select(.data.type? | (endswith(".PipelineRun") or contains("PipelineRun") or (type == "string" and (. | test("PipelineRun"; "i")))))] | length' 2>/dev/null || echo "0")
    
    # If that didn't work, try a simpler approach
    if [ "$pipelinerun_count" == "0" ] || [ -z "$pipelinerun_count" ]; then
        pipelinerun_count=$(echo "$all_records" | jq -r '[.[]? | select(.data.type? | endswith("PipelineRun"))] | length' 2>/dev/null || echo "0")
    fi
    
    # Count TaskRuns
    taskrun_count=$(echo "$all_records" | jq -r '[.[]? | select(.data.type? | endswith(".TaskRun"))] | length' 2>/dev/null || echo "0")
    
    # Total records
    total_records=$(echo "$all_records" | jq -r 'length' 2>/dev/null || echo "0")
    
    # Check if count seems low (less than 50 records when we might expect more)
    # This is a heuristic - user should verify with DB query
    if [ "$total_records" -lt 50 ] && [ -n "${TEST_TOTAL:-}" ] && [ "${TEST_TOTAL}" -gt 100 ]; then
        warning "Results API returned only $total_records records, but TEST_TOTAL=${TEST_TOTAL}"
        warning "This might indicate:"
        warning "  1. Pagination issue (check if total_pages > 1)"
        warning "  2. PipelineRuns not yet synced by Results watcher"
        warning "  3. PipelineRuns were pruned before being captured"
        warning "  4. Results API filtering (incomplete runs, etc.)"
        warning "Verify with: ./tools/query-results-db.sh \"SELECT count(*) FROM records WHERE type LIKE '%PipelineRun%';\""
    fi
    
    info "Fetched $total_pages page(s) from Results API: Total=$total_records, PipelineRuns=$pipelinerun_count, TaskRuns=$taskrun_count"

    # Create JSON structure for Results API metrics
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    local api_metrics
    api_metrics=$(jq -n \
        --argjson pipelinerun_count "${pipelinerun_count:-0}" \
        --argjson taskrun_count "${taskrun_count:-0}" \
        --argjson total_records "${total_records:-0}" \
        --argjson total_pages "${total_pages:-1}" \
        --arg timestamp "$timestamp" \
        '{
            total_records: $total_records,
            total_pages: $total_pages,
            pipelineruns: {
                count: $pipelinerun_count
            },
            taskruns: {
                count: $taskrun_count
            },
            timestamp: $timestamp
        }')

    # Merge into output file
    if [ -f "$output_file" ]; then
        jq --argjson api_metrics "$api_metrics" '.results.ResultsAPI = $api_metrics' "$output_file" > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"
    else
        echo "{}" | jq --argjson api_metrics "$api_metrics" '.results.ResultsAPI = $api_metrics' > "$output_file"
    fi

    info "Results API metrics collected: PipelineRuns=$pipelinerun_count, TaskRuns=$taskrun_count, Total=$total_records"
}

version_gte() {
    # Compare whether the version number specified in the first argument
    # is greater than or equal to the version number in the second argument.

    # TODO: Use package manager utility for version comparison
    # https://github.com/openshift-pipelines/performance/pull/64#discussion_r2041881415
    printf '%s\n%s\n' "$2" "$1" | sort --check=quiet --version-sort
}

capture_nightly_build_info() {
    local output_file=$1

    info "Collecting nightly build information"

    # CatalogSource image reference
    local catalog_image
    catalog_image=$(oc get catalogsource custom-osp-nightly -n openshift-marketplace -o jsonpath='{.spec.image}' 2>/dev/null || echo "unknown")

    # Defaults
    local image_digest="unknown" image_created="unknown"
    local build_release="unknown" build_version="unknown" os_git_commit="unknown"

    if [ "$catalog_image" != "unknown" ]; then
        local image_info_json
        image_info_json=$(oc image info "$catalog_image" --filter-by-os=linux/amd64 -o json 2>/dev/null || echo "")

        if [ -n "$image_info_json" ]; then
            read -r image_digest image_created build_release build_version os_git_commit <<<"$(
              echo "$image_info_json" | jq -r '
                [
                  .digest // "unknown",
                  .config.created // .config.config.Labels["build-date"] // "unknown",
                  (.config.config.Env[] | select(startswith("BUILD_RELEASE=")) | split("=")[1]) // "unknown",
                  (.config.config.Env[] | select(startswith("BUILD_VERSION=")) | split("=")[1]) // "unknown",
                  (.config.config.Env[] | select(startswith("OS_GIT_COMMIT=")) | split("=")[1]) // "unknown"
                ] | @tsv
              '
            )"
        fi
    fi

    # Deployment context
    local deployment_type="${DEPLOYMENT_TYPE:-unknown}"
    local deployment_version="${DEPLOYMENT_VERSION:-unknown}"
    local is_nightly_build="${NIGHTLY_BUILD:-false}"

    # JSON struct
    local deployment_info_entry
    deployment_info_entry=$(jq -n \
        --arg deployment_type "$deployment_type" \
        --arg deployment_version "$deployment_version" \
        --arg is_nightly_build "$is_nightly_build" \
        --arg image "$catalog_image" \
        --arg digest "$image_digest" \
        --arg created "$image_created" \
        --arg build_release "$build_release" \
        --arg build_version "$build_version" \
        --arg os_git_commit "$os_git_commit" \
        '{
            type: $deployment_type,
            version: $deployment_version,
            is_nightly_build: ($is_nightly_build | test("true"; "i")),
            nightly_build: {
                image: $image,
                digest: $digest,
                created: $created,
                build_release: $build_release,
                build_version: $build_version,
                os_git_commit: $os_git_commit
            }
        }')

    # Merge into output file (create if not exists)
    (jq --argjson deployment_info "$deployment_info_entry" \
        '.deployment = $deployment_info' "$output_file" 2>/dev/null \
     || echo "{}" | jq --argjson deployment_info "$deployment_info_entry" '.deployment = $deployment_info') \
     > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"

    info "Nightly build info collected: $catalog_image ($image_digest)"
}
