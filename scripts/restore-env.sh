#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage: $0 <archive-path> [target-root]
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

require_command tar

ARCHIVE_PATH="$1"
TARGET_ROOT="${2:-$ROOT_DIR}"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Archive not found: $ARCHIVE_PATH" >&2
  exit 1
fi

mkdir -p "$TARGET_ROOT"
tar -xzf "$ARCHIVE_PATH" -C "$TARGET_ROOT"

echo "Environment files restored into: $TARGET_ROOT"
