#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_command docker
require_command curl

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not available. Install Docker and start the service first." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose plugin is not available." >&2
  exit 1
fi

mkdir -p \
  "$ROOT_DIR/env/prod" \
  "$ROOT_DIR/env/stage" \
  "$ROOT_DIR/backups/env" \
  "$ROOT_DIR/backups/volumes"

chmod 700 "$ROOT_DIR/env/prod" "$ROOT_DIR/env/stage" "$ROOT_DIR/backups/env" "$ROOT_DIR/backups/volumes"

"$SCRIPT_DIR/create-network.sh" proxy
"$SCRIPT_DIR/create-network.sh" data

cat <<EOF
Server bootstrap checks completed.

Created/verified directories:
  - $ROOT_DIR/env/prod
  - $ROOT_DIR/env/stage
  - $ROOT_DIR/backups/env
  - $ROOT_DIR/backups/volumes

Next steps:
  1. Copy each *.env.example to .env in the relevant stack directory.
  2. Put real application env files into env/prod and env/stage.
  3. Start gateway: make up-gateway
  4. Start postgres if needed: make up-postgres
  5. Start registry if needed: make up-registry
  6. Start observability: make up-observability
  7. Start n8n if needed: make up-n8n
  8. Start ClickHouse if needed: make up-clickhouse
  9. Start Kafka if needed: make up-kafka
EOF
