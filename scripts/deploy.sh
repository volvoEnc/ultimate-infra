#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage: $0 <app> <env>

Example:
  $0 app1 prod
EOF
}

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

require_command docker
"$SCRIPT_DIR/create-network.sh" proxy
"$SCRIPT_DIR/create-network.sh" data

APP_NAME="$1"
ENV_NAME="$2"
STACK_DIR="$(resolve_stack_dir "$APP_NAME" "$ENV_NAME")"

ensure_dir "$STACK_DIR"

if [[ ! -f "$STACK_DIR/.env" ]]; then
  echo "Missing stack config: $STACK_DIR/.env" >&2
  exit 1
fi

compose_in_dir "$STACK_DIR" pull
compose_in_dir "$STACK_DIR" up -d --remove-orphans
compose_in_dir "$STACK_DIR" ps

"$SCRIPT_DIR/healthcheck.sh" "$APP_NAME" "$ENV_NAME"
