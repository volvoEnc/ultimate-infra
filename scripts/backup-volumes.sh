#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage:
  $0 <volume> [volume...]
  $0 --stack <gateway|postgres|registry|observability|admin|uptime|centrifugo|n8n|clickhouse|kafka|redis|mailpit|authelia|openclaw>
  $0 --stack <app> <env>
EOF
}

require_command docker

BACKUP_DIR="$ROOT_DIR/backups/volumes"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

declare -a VOLUMES=()

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

if [[ "$1" == "--stack" ]]; then
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    usage
    exit 1
  fi

  STACK_NAME="$2"
  ENV_NAME="${3:-}"
  STACK_DIR="$(resolve_stack_dir "$STACK_NAME" "$ENV_NAME")"
  ensure_dir "$STACK_DIR"
  mapfile -t VOLUMES < <(compose_in_dir "$STACK_DIR" config --volumes)
else
  VOLUMES=("$@")
fi

if [[ ${#VOLUMES[@]} -eq 0 ]]; then
  echo "No named volumes found to back up."
  exit 0
fi

for volume_name in "${VOLUMES[@]}"; do
  archive_path="$BACKUP_DIR/${volume_name}-${TIMESTAMP}.tar.gz"
  echo "Backing up volume '$volume_name' to '$archive_path'..."
  docker run --rm \
    -v "${volume_name}:/volume:ro" \
    -v "${BACKUP_DIR}:/backup" \
    busybox:1.36.1 \
    sh -c "cd /volume && tar -czf /backup/${volume_name}-${TIMESTAMP}.tar.gz ."
done

echo "Volume backup completed."
