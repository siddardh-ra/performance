#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Script to query Tekton Results database from a PostgreSQL dump file
# Uses Docker to avoid needing local PostgreSQL installation

DUMP_FILE="${DUMP_FILE:-artifacts/tekton-results-postgres-pgdump.dump}"
DB_NAME="${DB_NAME:-tekton-results-dump}"
CONTAINER_NAME="${CONTAINER_NAME:-tekton-results-query}"
QUERY="${1:-}"

if [ -z "$QUERY" ]; then
    echo "Usage: $0 '<SQL_QUERY>'"
    echo ""
    echo "Environment variables:"
    echo "  DUMP_FILE - Path to PostgreSQL dump file (default: artifacts/tekton-results-postgres-pgdump.dump)"
    echo "  DB_NAME - Database name for restored dump (default: tekton-results-dump)"
    echo "  CONTAINER_NAME - Docker container name (default: tekton-results-query)"
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
    echo "  # Show table structure"
    echo "  $0 \"SELECT table_name, column_name, data_type FROM information_schema.columns WHERE table_schema = 'public' ORDER BY table_name, ordinal_position;\""
    exit 1
fi

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed or not in PATH"
    echo "Please install Docker Desktop for Mac: https://www.docker.com/products/docker-desktop"
    exit 1
fi

# Check if dump file exists
if [ ! -f "$DUMP_FILE" ]; then
    echo "Error: Dump file not found: $DUMP_FILE"
    exit 1
fi

# Check if container already exists and is running
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container ${CONTAINER_NAME} already exists"
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Container is running, using existing database"
    else
        echo "Starting existing container..."
        docker start "${CONTAINER_NAME}" > /dev/null
        # Wait for PostgreSQL to be ready
        echo "Waiting for PostgreSQL to be ready..."
        for i in {1..30}; do
            if docker exec "${CONTAINER_NAME}" pg_isready -U postgres > /dev/null 2>&1; then
                break
            fi
            sleep 1
        done
    fi
else
    echo "Creating and starting PostgreSQL container..."
    # Start PostgreSQL container
    docker run -d \
        --name "${CONTAINER_NAME}" \
        -e POSTGRES_PASSWORD=postgres \
        -e POSTGRES_USER=postgres \
        -e POSTGRES_DB="${DB_NAME}" \
        postgres:15-alpine > /dev/null
    
    # Wait for PostgreSQL to be ready
    echo "Waiting for PostgreSQL to be ready..."
    for i in {1..30}; do
        if docker exec "${CONTAINER_NAME}" pg_isready -U postgres > /dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    
    # Check if database already has data
    table_count=$(docker exec "${CONTAINER_NAME}" psql -U postgres -d "${DB_NAME}" -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
    
    if [ "$table_count" = "0" ]; then
        echo "Restoring dump file to database..."
        # Restore the dump
        docker exec -i "${CONTAINER_NAME}" pg_restore -U postgres -d "${DB_NAME}" --no-owner --no-acl < "${DUMP_FILE}" 2>&1 | grep -v "WARNING" || true
        echo "Dump restored successfully"
    else
        echo "Database already contains data, skipping restore"
    fi
fi

echo ""
echo "Executing query:"
echo "$QUERY"
echo ""
echo "Results:"
echo "---"

# Execute query
docker exec "${CONTAINER_NAME}" psql -U postgres -d "${DB_NAME}" -c "$QUERY"

echo ""
echo "---"
echo "Note: Container ${CONTAINER_NAME} is still running. To stop it, run:"
echo "  docker stop ${CONTAINER_NAME}"
echo "To remove it, run:"
echo "  docker rm -f ${CONTAINER_NAME}"
