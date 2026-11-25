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

# Reads `docker compose config` YAML on stdin, prints the real volume names (one per line).
# Compose puts the final name (name:, project prefix, external) into the `name:` field of every
# top-level volume. A key without it means an old compose: fail instead of guessing a name.
# POSIX awk only (no gensub, no match() with array).
compose_volume_names() {
  awk -v dir="$1" '
    function indent(s) { match(s, /[^ ]/); return RSTART - 1 }
    function unq(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s)
      if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
      return s
    }
    function flush() {
      if (key != "") {
        if (nm == "") {
          print "Cannot resolve real name for volume key \047" key "\047 in " dir > "/dev/stderr"
          bad = 1
        } else {
          print nm
        }
      }
      key = ""; nm = ""
    }
    BEGIN { inblock = 0; bad = 0; key = ""; nm = "" }
    /^[ \t\r]*$/ { next }
    /^volumes:[ \t\r]*$/ { inblock = 1; keyind = -1; next }
    inblock {
      ind = indent($0)
      if (ind == 0) { flush(); inblock = 0; next }
      if (keyind < 0) keyind = ind
      if (ind == keyind) {
        flush()
        line = substr($0, ind + 1)
        k = index(line, ":")
        key = unq(k > 0 ? substr(line, 1, k - 1) : line)
        childind = -1
      } else if (key != "" && ind > keyind) {
        if (childind < 0) childind = ind
        if (ind == childind && substr($0, ind + 1) ~ /^name:/) {
          nm = unq(substr($0, ind + 6))
        }
      }
    }
    END { flush(); exit bad }
  '
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
  config_out="$(compose_in_dir "$STACK_DIR" config)"
  volume_names="$(printf '%s\n' "$config_out" | compose_volume_names "$STACK_DIR")"
  while IFS= read -r volume_name; do
    [[ -n "$volume_name" ]] && VOLUMES+=("$volume_name")
  done <<< "$volume_names"
else
  VOLUMES=("$@")
fi

if [[ ${#VOLUMES[@]} -eq 0 ]]; then
  echo "No named volumes found to back up."
  exit 0
fi

declare -a MISSING=()
declare -a FAILED=()

for volume_name in "${VOLUMES[@]}"; do
  if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
    echo "Volume '$volume_name' not found, skipping (no empty volume is created)." >&2
    MISSING+=("$volume_name")
    continue
  fi
  archive_path="$BACKUP_DIR/${volume_name}-${TIMESTAMP}.tar.gz"
  echo "Backing up volume '$volume_name' to '$archive_path'..."
  if ! docker run --rm \
    -v "${volume_name}:/volume:ro" \
    -v "${BACKUP_DIR}:/backup" \
    busybox:1.36.1 \
    sh -c "cd /volume && tar -czf /backup/${volume_name}-${TIMESTAMP}.tar.gz ."; then
    rm -f "$archive_path"
    echo "Backup of volume '$volume_name' failed, partial archive removed." >&2
    FAILED+=("$volume_name")
  fi
done

if [[ ${#MISSING[@]} -gt 0 || ${#FAILED[@]} -gt 0 ]]; then
  summary="Volume backup incomplete"
  [[ ${#MISSING[@]} -gt 0 ]] && summary="$summary, missing: ${MISSING[*]}"
  [[ ${#FAILED[@]} -gt 0 ]] && summary="$summary; failed: ${FAILED[*]}"
  echo "$summary" >&2
  exit 1
fi

echo "Volume backup completed."
