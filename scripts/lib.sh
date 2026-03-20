#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

is_infra_stack() {
  local stack="$1"
  [[ "$stack" == "gateway" || "$stack" == "postgres" || "$stack" == "observability" || "$stack" == "admin" || "$stack" == "uptime" ]]
}

resolve_stack_dir() {
  local stack="$1"
  local env_name="${2:-}"

  if is_infra_stack "$stack"; then
    printf '%s/%s\n' "$ROOT_DIR" "$stack"
    return 0
  fi

  if [[ -z "$env_name" ]]; then
    echo "Environment is required for application stacks." >&2
    return 1
  fi

  printf '%s/deployments/%s-%s\n' "$ROOT_DIR" "$stack" "$env_name"
}

ensure_dir() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    echo "Directory not found: $dir" >&2
    return 1
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    return 1
  fi
}

compose_in_dir() {
  local stack_dir="$1"
  shift

  (
    cd "$stack_dir"
    if [[ -f .env ]]; then
      docker compose --env-file .env "$@"
    else
      docker compose "$@"
    fi
  )
}

extract_env_value() {
  local file_path="$1"
  local variable_name="$2"

  if [[ ! -f "$file_path" ]]; then
    return 1
  fi

  awk -F= -v key="$variable_name" '$1 == key {sub(/^[^=]+=*/, "", $0); print $0}' "$file_path" | tail -n 1
}
