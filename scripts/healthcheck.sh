#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage:
  $0 <gateway|postgres|registry|observability|admin|uptime|n8n>
  $0 <app> <env>
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

require_command docker
require_command curl

TARGET="$1"
ENV_NAME="${2:-}"
STACK_DIR="$(resolve_stack_dir "$TARGET" "$ENV_NAME")"

ensure_dir "$STACK_DIR"

mapfile -t CONTAINERS < <(compose_in_dir "$STACK_DIR" ps -q)

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
  echo "No containers found for stack in $STACK_DIR" >&2
  exit 1
fi

TIMEOUT_SECONDS="${HEALTHCHECK_TIMEOUT_SECONDS:-120}"
INTERVAL_SECONDS="${HEALTHCHECK_INTERVAL_SECONDS:-5}"
DEADLINE=$((SECONDS + TIMEOUT_SECONDS))
FAILED=0

while (( SECONDS <= DEADLINE )); do
  FAILED=0
  PENDING=0

  for container_id in "${CONTAINERS[@]}"; do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")"

    case "$status" in
      healthy|running)
        ;;
      starting|created|restarting)
        PENDING=1
        ;;
      *)
        FAILED=1
        ;;
    esac
  done

  if [[ $FAILED -eq 0 && $PENDING -eq 0 ]]; then
    break
  fi

  sleep "$INTERVAL_SECONDS"
done

for container_id in "${CONTAINERS[@]}"; do
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")"
  container_name="$(docker inspect --format '{{.Name}}' "$container_id" | sed 's#^/##')"
  echo "$container_name => $status"

  if [[ "$status" != "healthy" && "$status" != "running" ]]; then
    FAILED=1
  fi
done

STACK_ENV_FILE="$STACK_DIR/.env"
APP_URL="$(extract_env_value "$STACK_ENV_FILE" "APP_URL" || true)"
PUBLIC_URL="$(extract_env_value "$STACK_ENV_FILE" "PUBLIC_URL" || true)"
TARGET_URL="${APP_URL:-$PUBLIC_URL}"

if [[ -n "$TARGET_URL" ]]; then
  echo "Checking URL: $TARGET_URL"
  curl -fsS --retry 5 --retry-delay 2 --retry-connrefused --max-time 10 "$TARGET_URL" >/dev/null
  echo "URL check passed."
fi

if [[ $FAILED -ne 0 ]]; then
  echo "At least one container is not healthy." >&2
  exit 1
fi
