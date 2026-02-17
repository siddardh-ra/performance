#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Script to query Tekton Results database from a PostgreSQL dump file
# Requires local PostgreSQL installation with psql and pg_restore

DUMP_FILE="${DUMP_FILE:-artifacts/tekton-results-postgres-pgdump.dump}"
DB_NAME="${DB_NAME:-tekton_results_dump}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-${USER}}"
QUERY="${1:-}"

if [ -z "$QUERY" ]; then
    echo "Usage: $0 '<SQL_QUERY>'"
    echo ""
    echo "Environment variables:"
    echo "  DUMP_FILE - Path to PostgreSQL dump file (default: artifacts/tekton-results-postgres-pgdump.dump)"
    echo "  DB_NAME - Database name for restored dump (default: tekton_results_dump)"
    echo "  DB_HOST - PostgreSQL host (default: localhost)"
    echo "  DB_PORT - PostgreSQL port (default: 5432)"
    echo "  DB_USER - PostgreSQL user (default: \$USER)"
    echo ""
    echo "Examples:"
    echo "  # Count PipelineRuns"
    echo "  $0 \"SELECT type, count(*) FROM records WHERE type LIKE '%PipelineRun%' GROUP BY type;\""
    echo ""
    echo "  # Count TaskRuns"
    echo "  $0 \"SELECT type, count(*) FROM records WHERE type LIKE '%TaskRun%' GROUP BY type;\""
    echo ""
    echo "  # Show table structure"
    echo "  $0 \"SELECT table_name, column_name, data_type FROM information_schema.columns WHERE table_schema = 'public' ORDER BY table_name, ordinal_position;\""
    exit 1
fi

# Check if PostgreSQL tools are available
if ! command -v psql &> /dev/null; then
    echo "Error: psql is not installed or not in PATH"
    echo ""
    echo "To install PostgreSQL client tools on macOS:"
    echo "  brew install postgresql@15"
    echo "  brew link postgresql@15"
    echo ""
    echo "Or install full PostgreSQL server:"
    echo "  brew install postgresql"
    exit 1
fi

if ! command -v pg_restore &> /dev/null; then
    echo "Error: pg_restore is not installed or not in PATH"
    exit 1
fi

# Check if dump file exists
if [ ! -f "$DUMP_FILE" ]; then
    echo "Error: Dump file not found: $DUMP_FILE"
    exit 1
fi

# Check if database exists by trying to connect to it
db_exists=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1 && echo "1" || echo "0")

if [ "$db_exists" = "0" ]; then
    echo "Database $DB_NAME does not exist. Creating..."
    # createdb doesn't support -h/-p flags, use PGHOST/PGPORT env vars or default to local socket
    if [ "$DB_HOST" != "localhost" ] || [ "$DB_PORT" != "5432" ]; then
        PGHOST="$DB_HOST" PGPORT="$DB_PORT" PGUSER="$DB_USER" createdb "$DB_NAME" 2>&1 || {
            echo "Error: Failed to create database. Make sure PostgreSQL is running and you have permissions."
            echo "You may need to start PostgreSQL:"
            echo "  brew services start postgresql@14"
            exit 1
        }
    else
        createdb -U "$DB_USER" "$DB_NAME" 2>&1 || {
            echo "Error: Failed to create database. Make sure PostgreSQL is running and you have permissions."
            echo "You may need to start PostgreSQL:"
            echo "  brew services start postgresql@14"
            exit 1
        }
    fi
    
    echo "Restoring dump file to database..."
    pg_restore -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" --no-owner --no-acl "$DUMP_FILE" 2>&1 | grep -v "WARNING" || true
    echo "Dump restored successfully"
else
    echo "Database $DB_NAME already exists, using existing database"
    # Check if it has tables
    table_count=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
    if [ "$table_count" = "0" ]; then
        echo "Database exists but is empty. Restoring dump..."
        pg_restore -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" --no-owner --no-acl "$DUMP_FILE" 2>&1 | grep -v "WARNING" || true
        echo "Dump restored successfully"
    fi
fi

echo ""
echo "Executing query:"
echo "$QUERY"
echo ""
echo "Results:"
echo "---"

# Execute query
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "$QUERY"

