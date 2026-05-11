#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage:
  $0 [--no-restart] [workflow.json ...]

Imports every JSON workflow from n8n/workflows by default.
If workflow files are passed, each path must be a file inside n8n/workflows.

Optional env:
  N8N_IMPORT_PROJECT_ID=<project-id>
  N8N_IMPORT_USER_ID=<user-id>
EOF
}

require_command docker

N8N_DIR="$ROOT_DIR/n8n"
N8N_ENV_FILE="$N8N_DIR/.env"
WORKFLOWS_DIR="$N8N_DIR/workflows"
CONTAINER_WORKFLOWS_DIR="/workflows"
RESTART_AFTER_IMPORT=1
WORKFLOW_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --no-restart)
      RESTART_AFTER_IMPORT=0
      shift
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      WORKFLOW_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ! -f "$N8N_ENV_FILE" ]]; then
  echo "Missing n8n env file: $N8N_ENV_FILE" >&2
  echo "Copy n8n/.env.example to n8n/.env and fill production values first." >&2
  exit 1
fi

ensure_dir "$WORKFLOWS_DIR"

resolve_workflow_arg() {
  local workflow_arg="$1"
  local workflow_path=""

  if [[ -f "$workflow_arg" ]]; then
    workflow_path="$workflow_arg"
  elif [[ -f "$WORKFLOWS_DIR/$workflow_arg" ]]; then
    workflow_path="$WORKFLOWS_DIR/$workflow_arg"
  elif [[ -f "$WORKFLOWS_DIR/$workflow_arg.json" ]]; then
    workflow_path="$WORKFLOWS_DIR/$workflow_arg.json"
  else
    echo "Workflow file not found: $workflow_arg" >&2
    return 1
  fi

  workflow_path="$(cd "$(dirname "$workflow_path")" && pwd)/$(basename "$workflow_path")"

  case "$workflow_path" in
    "$WORKFLOWS_DIR"/*.json)
      printf '%s\n' "$workflow_path"
      ;;
    *)
      echo "Workflow file must be inside $WORKFLOWS_DIR: $workflow_path" >&2
      return 1
      ;;
  esac
}

if [[ ${#WORKFLOW_ARGS[@]} -gt 0 ]]; then
  WORKFLOW_FILES=()
  for workflow_arg in "${WORKFLOW_ARGS[@]}"; do
    WORKFLOW_FILES+=("$(resolve_workflow_arg "$workflow_arg")")
  done
else
  mapfile -t WORKFLOW_FILES < <(find "$WORKFLOWS_DIR" -maxdepth 1 -type f -name '*.json' | sort)
fi

if [[ ${#WORKFLOW_FILES[@]} -eq 0 ]]; then
  echo "No workflow JSON files found in $WORKFLOWS_DIR" >&2
  exit 1
fi

PROJECT_ID="${N8N_IMPORT_PROJECT_ID:-$(extract_env_value "$N8N_ENV_FILE" "N8N_IMPORT_PROJECT_ID" || true)}"
USER_ID="${N8N_IMPORT_USER_ID:-$(extract_env_value "$N8N_ENV_FILE" "N8N_IMPORT_USER_ID" || true)}"

if [[ -n "$PROJECT_ID" && -n "$USER_ID" ]]; then
  echo "Use either N8N_IMPORT_PROJECT_ID or N8N_IMPORT_USER_ID, not both." >&2
  exit 1
fi

container_sees_workflows() {
  if ! compose_in_dir "$N8N_DIR" exec -T n8n test -d "$CONTAINER_WORKFLOWS_DIR"; then
    return 1
  fi

  for workflow_file in "${WORKFLOW_FILES[@]}"; do
    workflow_name="$(basename "$workflow_file")"
    if ! compose_in_dir "$N8N_DIR" exec -T n8n test -f "$CONTAINER_WORKFLOWS_DIR/$workflow_name"; then
      return 1
    fi
  done
}

recreate_n8n_with_current_mounts() {
  echo "n8n container does not see committed workflow files. Recreating it with current compose mounts."
  compose_in_dir "$N8N_DIR" up -d --force-recreate --remove-orphans n8n
  "$SCRIPT_DIR/healthcheck.sh" n8n
}

"$SCRIPT_DIR/create-network.sh" proxy
"$SCRIPT_DIR/create-network.sh" data

compose_in_dir "$N8N_DIR" up -d --remove-orphans
"$SCRIPT_DIR/healthcheck.sh" n8n

if ! container_sees_workflows; then
  recreate_n8n_with_current_mounts
fi

echo "Importing ${#WORKFLOW_FILES[@]} n8n workflow file(s)."

for workflow_file in "${WORKFLOW_FILES[@]}"; do
  workflow_name="$(basename "$workflow_file")"
  container_workflow_path="$CONTAINER_WORKFLOWS_DIR/$workflow_name"

  if ! compose_in_dir "$N8N_DIR" exec -T n8n test -f "$container_workflow_path"; then
    echo "Workflow is not visible inside n8n container: $container_workflow_path" >&2
    echo "Check the ./workflows:/workflows:ro bind mount, deployed git revision, and Docker bind mount permissions." >&2
    exit 1
  fi

  import_args=(import:workflow "--input=$container_workflow_path")

  if [[ -n "$PROJECT_ID" ]]; then
    import_args+=("--projectId=$PROJECT_ID")
  elif [[ -n "$USER_ID" ]]; then
    import_args+=("--userId=$USER_ID")
  fi

  echo "Importing $workflow_name"
  compose_in_dir "$N8N_DIR" exec -T n8n n8n "${import_args[@]}"
done

if [[ "$RESTART_AFTER_IMPORT" -eq 1 ]]; then
  echo "Restarting n8n so imported workflows are visible to the running instance."
  compose_in_dir "$N8N_DIR" restart n8n
  "$SCRIPT_DIR/healthcheck.sh" n8n
fi

echo "n8n workflow import finished."
