#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
N8N_ENV_FILE="$ROOT_DIR/n8n/.env"
N8N_COMPOSE_FILE="$ROOT_DIR/n8n/docker-compose.yml"
EXPORT_DIR="$ROOT_DIR/n8n/workflows-exported"
CONTAINER_EXPORT_DIR="/tmp/n8n-workflows-export"

compose_n8n() {
  docker compose --env-file "$N8N_ENV_FILE" -f "$N8N_COMPOSE_FILE" "$@"
}

if [[ ! -f "$N8N_ENV_FILE" ]]; then
  echo "Missing n8n env file: $N8N_ENV_FILE" >&2
  echo "Copy n8n/.env.example to n8n/.env and fill production values first." >&2
  exit 1
fi

if [[ -z "$(compose_n8n ps -q n8n)" ]]; then
  echo "n8n container is not running." >&2
  echo "Start it first with: make up-n8n" >&2
  exit 1
fi

rm -rf "$EXPORT_DIR"

compose_n8n exec -T n8n rm -rf "$CONTAINER_EXPORT_DIR"
compose_n8n exec -T n8n n8n export:workflow --backup --output="$CONTAINER_EXPORT_DIR"
docker cp "infra-n8n:$CONTAINER_EXPORT_DIR" "$EXPORT_DIR"
compose_n8n exec -T n8n rm -rf "$CONTAINER_EXPORT_DIR"

echo "Workflows exported to: $EXPORT_DIR"
