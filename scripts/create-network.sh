#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_command docker

NETWORK_NAME="${1:-proxy}"

if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  echo "Docker network '$NETWORK_NAME' already exists."
  exit 0
fi

docker network create "$NETWORK_NAME" >/dev/null
echo "Docker network '$NETWORK_NAME' created."
