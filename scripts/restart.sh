#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage:
  $0 <gateway|postgres|registry|observability|admin|uptime|n8n> [service]
  $0 <app> <env> [service]
EOF
}

if [[ $# -lt 1 || $# -gt 3 ]]; then
  usage
  exit 1
fi

require_command docker

TARGET="$1"
ENV_NAME=""
SERVICE_NAME=""

if is_infra_stack "$TARGET"; then
  SERVICE_NAME="${2:-}"
else
  ENV_NAME="${2:-}"
  SERVICE_NAME="${3:-}"
fi

STACK_DIR="$(resolve_stack_dir "$TARGET" "$ENV_NAME")"
ensure_dir "$STACK_DIR"

if [[ -n "$SERVICE_NAME" ]]; then
  compose_in_dir "$STACK_DIR" restart "$SERVICE_NAME"
else
  compose_in_dir "$STACK_DIR" restart
fi

compose_in_dir "$STACK_DIR" ps
