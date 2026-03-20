#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_command tar

BACKUP_DIR="$ROOT_DIR/backups/env"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_PATH="${1:-$BACKUP_DIR/env-$TIMESTAMP.tar.gz}"

mkdir -p "$(dirname "$ARCHIVE_PATH")"

tar -czf "$ARCHIVE_PATH" -C "$ROOT_DIR" env/prod env/stage
chmod 600 "$ARCHIVE_PATH"

echo "Environment backup created: $ARCHIVE_PATH"
