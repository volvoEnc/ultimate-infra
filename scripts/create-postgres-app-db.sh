#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage:
  $0 <app> <prod|stage> [password]

Examples:
  $0 billing prod
  $0 billing stage 'strong-password'
EOF
}

sanitize_identifier() {
  local value="$1"

  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | tr -c 'a-z0-9_' '_')"
  value="$(printf '%s' "$value" | sed -E 's/_+/_/g; s/^_+//; s/_+$//')"

  if [[ -z "$value" ]]; then
    echo "Failed to derive a valid postgres identifier." >&2
    exit 1
  fi

  printf '%s' "$value"
}

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
    return 0
  fi

  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '-' </proc/sys/kernel/random/uuid
    return 0
  fi

  echo "Unable to generate password automatically. Pass it as the third argument." >&2
  exit 1
}

sql_escape_literal() {
  printf '%s' "$1" | sed "s/'/''/g"
}

sql_escape_identifier() {
  printf '%s' "$1" | sed 's/"/""/g'
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
  exit 1
fi

require_command docker
require_command sed
require_command tr

APP_NAME="$1"
ENV_NAME="$2"
PASSWORD_OVERRIDE="${3:-}"

case "$ENV_NAME" in
  prod|stage)
    ;;
  *)
    echo "Environment must be prod or stage." >&2
    exit 1
    ;;
esac

POSTGRES_STACK_DIR="$(resolve_stack_dir postgres)"
POSTGRES_ENV_FILE="$POSTGRES_STACK_DIR/.env"

ensure_dir "$POSTGRES_STACK_DIR"

if [[ ! -f "$POSTGRES_ENV_FILE" ]]; then
  echo "Missing postgres stack config: $POSTGRES_ENV_FILE" >&2
  exit 1
fi

if [[ -z "$(compose_in_dir "$POSTGRES_STACK_DIR" ps -q postgres)" ]]; then
  echo "Postgres stack is not running. Start it with: make up-postgres" >&2
  exit 1
fi

ADMIN_DB="$(extract_env_value "$POSTGRES_ENV_FILE" "POSTGRES_DB" || true)"
ADMIN_USER="$(extract_env_value "$POSTGRES_ENV_FILE" "POSTGRES_USER" || true)"

if [[ -z "$ADMIN_DB" || -z "$ADMIN_USER" ]]; then
  echo "POSTGRES_DB and POSTGRES_USER must be set in $POSTGRES_ENV_FILE" >&2
  exit 1
fi

APP_SLUG="$(sanitize_identifier "$APP_NAME")"
DB_NAME="${APP_SLUG}_${ENV_NAME}"
DB_USER="${APP_SLUG}_${ENV_NAME}"
DB_PASSWORD="${PASSWORD_OVERRIDE:-$(generate_password)}"

DB_NAME_ESCAPED="$(sql_escape_identifier "$DB_NAME")"
DB_USER_ESCAPED="$(sql_escape_identifier "$DB_USER")"
DB_PASSWORD_ESCAPED="$(sql_escape_literal "$DB_PASSWORD")"

psql_query() {
  local sql="$1"

  compose_in_dir "$POSTGRES_STACK_DIR" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d "$ADMIN_DB" -tAc "$sql"
}

psql_exec() {
  local database="$1"
  local sql="$2"

  compose_in_dir "$POSTGRES_STACK_DIR" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d "$database" -c "$sql" >/dev/null
}

if [[ "$(psql_query "SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}';")" != "1" ]]; then
  psql_exec "$ADMIN_DB" "CREATE ROLE \"$DB_USER_ESCAPED\" LOGIN PASSWORD '$DB_PASSWORD_ESCAPED';"
else
  psql_exec "$ADMIN_DB" "ALTER ROLE \"$DB_USER_ESCAPED\" WITH LOGIN PASSWORD '$DB_PASSWORD_ESCAPED';"
fi

if [[ "$(psql_query "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}';")" != "1" ]]; then
  psql_exec "$ADMIN_DB" "CREATE DATABASE \"$DB_NAME_ESCAPED\" OWNER \"$DB_USER_ESCAPED\";"
else
  psql_exec "$ADMIN_DB" "ALTER DATABASE \"$DB_NAME_ESCAPED\" OWNER TO \"$DB_USER_ESCAPED\";"
fi

psql_exec "$DB_NAME" "GRANT ALL ON SCHEMA public TO \"$DB_USER_ESCAPED\";"
psql_exec "$DB_NAME" "ALTER SCHEMA public OWNER TO \"$DB_USER_ESCAPED\";"

cat <<EOF
PostgreSQL resources are ready.

App: $APP_NAME
Environment: $ENV_NAME
Database: $DB_NAME
User: $DB_USER

Put these values into env/$ENV_NAME/${APP_SLUG}.env:

DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@infra-postgres:5432/${DB_NAME}?sslmode=disable
PGHOST=infra-postgres
PGPORT=5432
PGDATABASE=${DB_NAME}
PGUSER=${DB_USER}
PGPASSWORD=${DB_PASSWORD}
EOF
