#!/usr/bin/env sh

set -eu

test_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
stack_dir=$(CDPATH= cd "$test_dir/.." && pwd)
temporary_root=$(mktemp -d)
trap 'rm -rf "$temporary_root"' EXIT

: > "$temporary_root/app.env"
: > "$temporary_root/mysql.env"

grep -Eq '^      SESSION_ENCRYPT: "true"$' "$stack_dir/docker-compose.yml"

configured=$(APP_ENV_FILE="$temporary_root/app.env" \
  MYSQL_ENV_FILE="$temporary_root/mysql.env" \
  docker compose \
  --env-file "$stack_dir/.env.example" \
  -f "$stack_dir/docker-compose.yml" \
  config 2>/dev/null)

printf '%s\n' "$configured" | grep -A30 '^  app:' | grep -Eq '^      SESSION_ENCRYPT: "true"$'

printf '%s\n' 'Freelance runtime security contract passed.'
