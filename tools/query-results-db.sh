#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Script to query Tekton Results database directly from the cluster
# This is simpler than restoring the dump file

QUERY="${1:-}"

if [ -z "$QUERY" ]; then
    echo "Usage: $0 '<SQL_QUERY>'"
    echo ""
    echo "Examples:"
    echo "  # Count PipelineRuns"
    echo "  $0 \"SELECT type, count(*) FROM records WHERE type LIKE '%PipelineRun%' GROUP BY type;\""
    echo ""
    echo "  # Count TaskRuns"
    echo "  $0 \"SELECT type, count(*) FROM records WHERE type LIKE '%TaskRun%' GROUP BY type;\""
    echo ""
    echo "  # Count all records by type"
    echo "  $0 \"SELECT type, count(*) FROM records GROUP BY type ORDER BY count(*) DESC;\""
    echo ""
    echo "  # Count records by parent (namespace)"
    echo "  $0 \"SELECT parent, count(*) FROM records GROUP BY parent ORDER BY parent;\""
    echo ""
    echo "  # Count records by parent and type"
    echo "  $0 \"SELECT parent, type, count(*) FROM records GROUP BY parent, type ORDER BY parent, type;\""
    exit 1
fi

# Get Postgres credentials
pg_user=$(oc -n openshift-pipelines get secret tekton-results-postgres -o json | jq -r '.data.POSTGRES_USER' | base64 -d)
pg_pwd=$(oc -n openshift-pipelines get secret tekton-results-postgres -o json | jq -r '.data.POSTGRES_PASSWORD' | base64 -d)

echo "Executing query:"
echo "$QUERY"
echo ""
echo "Results:"
echo "---"

# Execute query
oc -n openshift-pipelines exec -i tekton-results-postgres-0 -- bash -c \
    "PGPASSWORD=$pg_pwd psql -d tekton-results -U $pg_user -c \"$QUERY\""


