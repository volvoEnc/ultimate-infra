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

N8N_CONTAINER_ID="$(compose_n8n ps -q n8n)"
if [[ -z "$N8N_CONTAINER_ID" ]]; then
  echo "n8n container is not running." >&2
  echo "Start it first with: make up-n8n" >&2
  exit 1
fi

# The new export is built next to the result (same filesystem, so mv is a rename)
# and replaces the previous one only when it is complete.
STAGE_DIR="$(mktemp -d "$ROOT_DIR/n8n/.workflows-exported.XXXXXX")"
SWAPPED=0

cleanup() {
  local rc=$?
  local final=$rc keep_stage=0 restore_failed=0
  set +e
  if ((rc != 0)); then
    compose_n8n exec -T n8n rm -rf "$CONTAINER_EXPORT_DIR" >/dev/null 2>&1
  fi
  if [[ -d "$STAGE_DIR/previous" && ! -e "$EXPORT_DIR" ]]; then
    if ! mv "$STAGE_DIR/previous" "$EXPORT_DIR"; then
      echo "Could not restore previous export; it is left at: $STAGE_DIR/previous" >&2
      restore_failed=1
      keep_stage=1
      ((final == 0)) && final=1
    fi
  fi
  if ((keep_stage == 0)) && [[ -e "$STAGE_DIR" ]]; then
    if ! rm -rf "$STAGE_DIR"; then
      if ((SWAPPED == 1)); then
        echo "New export in place: $EXPORT_DIR; could not remove previous export at: $STAGE_DIR" >&2
      else
        echo "Could not remove temporary directory: $STAGE_DIR" >&2
      fi
      ((final == 0)) && final=1
    fi
  fi
  if ((rc != 0 && SWAPPED == 0 && restore_failed == 0)); then
    if [[ -d "$EXPORT_DIR" ]]; then
      echo "Export failed; previous export kept: $EXPORT_DIR" >&2
    else
      echo "Export failed; no previous export at $EXPORT_DIR" >&2
    fi
  fi
  exit "$final"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

compose_n8n exec -T n8n rm -rf "$CONTAINER_EXPORT_DIR"
compose_n8n exec -T n8n n8n export:workflow --backup --output="$CONTAINER_EXPORT_DIR"
# STAGE_DIR/new must not exist yet: docker cp then puts the directory contents into it.
docker cp "$N8N_CONTAINER_ID:$CONTAINER_EXPORT_DIR" "$STAGE_DIR/new"
compose_n8n exec -T n8n rm -rf "$CONTAINER_EXPORT_DIR"

# No pipe here: a reader that exits early would kill find with SIGPIPE under pipefail.
FIRST_JSON="$(find "$STAGE_DIR/new" -maxdepth 1 -type f -name '*.json' -print -quit)"
if [[ -z "$FIRST_JSON" ]]; then
  echo "No workflows exported." >&2
  exit 1
fi

if [[ -e "$EXPORT_DIR" ]]; then
  mv "$EXPORT_DIR" "$STAGE_DIR/previous"
fi
mv "$STAGE_DIR/new" "$EXPORT_DIR"
SWAPPED=1
rm -rf "$STAGE_DIR"

echo "Workflows exported to: $EXPORT_DIR"
