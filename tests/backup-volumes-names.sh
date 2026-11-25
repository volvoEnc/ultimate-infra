#!/usr/bin/env bash
# Tests for scripts/backup-volumes.sh: it must back up the real volume names
# (as printed by `docker compose config`), never create empty volumes.
# Real docker is never used: a stub answers `compose config`, `volume inspect`, `run`.
#   BV_TREE_REF=<ref>  tree to test (default HEAD)
#   BV_BASH5=1         run the script inside a Debian image with bash 5 (no network)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TREE="$TMP/tree"
FIX="$TMP/fix"
mkdir -p "$TREE" "$FIX" "$TMP/bin"
git -C "$REPO" archive "${BV_TREE_REF:-HEAD}" | tar -x -C "$TREE"

# --- fixtures: env files and test stacks (no dotenv files are created) ---
mkdir -p "$TREE/env/prod"
: > "$TREE/env/prod/freelance.env"
: > "$TREE/env/prod/freelance-mysql.env"
mkdir -p "$TREE/deployments/fx-test" "$TREE/deployments/nameless-test" "$TREE/deployments/broken-test"
cat > "$TREE/deployments/fx-test/docker-compose.yml" <<'YML'
services:
  app:
    image: busybox:1.36.1
    volumes:
      - plain:/a
      - ext:/b
      - extnamed:/c
      - opts:/d
volumes:
  plain: {}
  ext:
    external: true
  extnamed:
    external: true
    name: real-ext
  opts:
    labels:
      name: decoy
    driver_opts:
      name: decoy2
YML
cat > "$TREE/deployments/broken-test/docker-compose.yml" <<'YML'
services:
  app:
    image: busybox:1.36.1
    env_file: ../../env/prod/missing.env
    volumes:
      - data:/a
volumes:
  data: {}
YML

# --- render fixtures with the real compose (no daemon needed) ---
render() {
  local rel="$1" envarg=""
  mkdir -p "$FIX/$rel"
  [[ -f "$TREE/$rel/.env.example" ]] && envarg="--env-file .env.example"
  set +e
  # shellcheck disable=SC2086
  (cd "$TREE/$rel" && docker compose $envarg config) > "$FIX/$rel/config.out" 2> "$FIX/$rel/config.err"
  echo $? > "$FIX/$rel/config.rc"
  # shellcheck disable=SC2086
  (cd "$TREE/$rel" && docker compose $envarg config --volumes) > "$FIX/$rel/volumes.out" 2> "$FIX/$rel/volumes.err"
  echo $? > "$FIX/$rel/volumes.rc"
  set -e
}
for rel in admin gateway observability postgres centrifugo deployments/freelance-prod deployments/fx-test deployments/broken-test; do
  render "$rel"
  if [[ "$rel" != "deployments/broken-test" && "$(< "$FIX/$rel/config.rc")" != 0 ]]; then
    echo "FAIL render $rel: $(head -n 3 "$FIX/$rel/config.err")"
    exit 1
  fi
done
# compose output with a volume key that has no name: (old compose imitation)
rel=deployments/nameless-test
mkdir -p "$FIX/$rel"
printf 'name: nameless-test\nservices:\n  app:\n    image: busybox\nvolumes:\n  data: {}\n' > "$FIX/$rel/config.out"
printf 'data\n' > "$FIX/$rel/volumes.out"
: > "$FIX/$rel/config.err"
: > "$FIX/$rel/volumes.err"
echo 0 > "$FIX/$rel/config.rc"
echo 0 > "$FIX/$rel/volumes.rc"

# --- docker stub: only compose config, volume inspect, run are allowed ---
{
  echo '#!/usr/bin/env bash'
  echo "TMP='$TMP'"
  echo "TREE='$TREE'"
  echo "FIX='$FIX'"
} > "$TMP/bin/docker"
cat >> "$TMP/bin/docker" <<'STUB'
case "${1:-}" in
  compose)
    shift
    if [[ "${1:-}" == "--env-file" ]]; then shift 2; fi
    rel="${PWD#"$TREE"/}"
    if [[ "${1:-}" == "config" && "${2:-}" == "--volumes" && $# -eq 2 ]]; then pre=volumes
    elif [[ "${1:-}" == "config" && $# -eq 1 ]]; then pre=config
    else echo "compose $*" >> "$TMP/forbidden.log"; exit 99; fi
    cat "$FIX/$rel/$pre.out"
    cat "$FIX/$rel/$pre.err" >&2
    exit "$(< "$FIX/$rel/$pre.rc")"
    ;;
  volume)
    if [[ "${2:-}" == "inspect" && $# -eq 3 ]]; then
      grep -qxF -- "$3" "$TMP/existing"
      exit $?
    fi
    echo "volume $*" >> "$TMP/forbidden.log"; exit 99
    ;;
  run)
    echo "$*" >> "$TMP/run.log"
    vol=""; bdir=""
    for a in "$@"; do
      case "$a" in
        *:/volume:ro) vol="${a%:/volume:ro}" ;;
        *:/backup) bdir="${a%:/backup}" ;;
      esac
    done
    if grep -qxF -- "$vol" "$TMP/fail_run"; then
      last="${!#}"
      f="${last##*/backup/}"; f="${f%% *}"
      echo partial > "$bdir/$f"
      exit 1
    fi
    exit 0
    ;;
  *)
    echo "$*" >> "$TMP/forbidden.log"; exit 99
    ;;
esac
STUB
chmod +x "$TMP/bin/docker"

# --- harness ---
BAD=0
RC=0
RC_ALL=0
setup() { # $1 = existing volumes (newline separated), $2 = volumes whose run fails
  : > "$TMP/run.log"; : > "$TMP/forbidden.log"
  printf '%s\n' "${1:-}" > "$TMP/existing"
  printf '%s\n' "${2:-}" > "$TMP/fail_run"
  rm -rf "$TREE/backups"
}
exec_script() {
  local q="" a
  for a in "$@"; do q="$q $(printf '%q' "$a")"; done
  set +e
  if [[ "${BV_BASH5:-}" == 1 ]]; then
    docker run --rm --network none -v "$TMP:$TMP" -w "$TREE" pgvector/pgvector:pg17 \
      bash -c "PATH='$TMP/bin':\$PATH bash '$TREE/scripts/backup-volumes.sh' $q" > "$TMP/out.txt" 2> "$TMP/err.txt"
  else
    (cd "$TREE" && PATH="$TMP/bin:$PATH" bash "$TREE/scripts/backup-volumes.sh" "$@") > "$TMP/out.txt" 2> "$TMP/err.txt"
  fi
  RC=$?
  set -e
}
fail() { echo "  - $*"; BAD=1; }
ran() { grep -qF -- "-v $1:/volume:ro " "$TMP/run.log"; }
expect_run() { ran "$1" || fail "no docker run for volume '$1'"; }
expect_no_run() { if ran "$1"; then fail "unexpected docker run for volume '$1'"; fi; }
expect_no_any_run() { [[ ! -s "$TMP/run.log" ]] || fail "unexpected docker run: $(head -n 1 "$TMP/run.log")"; }
expect_rc0() { [[ "$RC" == 0 ]] || fail "exit code $RC, expected 0; stderr: $(head -n 3 "$TMP/err.txt")"; }
expect_rc_nonzero() { [[ "$RC" != 0 ]] || fail "exit code 0, expected non-zero"; }
expect_err_has() { grep -qF -- "$1" "$TMP/err.txt" || fail "stderr lacks '$1'"; }
expect_out_has() { grep -qF -- "$1" "$TMP/out.txt" || fail "stdout lacks '$1'"; }
expect_out_lacks() { if grep -qF -- "$1" "$TMP/out.txt"; then fail "stdout has '$1'"; fi; }
expect_run_archive() { grep -qE -- "/backup/$1-[0-9]{8}-[0-9]{6}\.tar\.gz " "$TMP/run.log" || fail "run does not write archive '$1-<ts>.tar.gz'"; }
finish() { # $1 = test name
  if [[ -s "$TMP/forbidden.log" ]]; then fail "forbidden docker call: $(head -n 1 "$TMP/forbidden.log")"; fi
  if [[ "$BAD" == 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; RC_ALL=1; fi
  BAD=0
}
OBS="observability-grafana-data
observability-loki-data
observability-prometheus-data
observability-promtail-positions"

# --- cases ---
admin_backs_up_named_volume() {
  setup "admin-portainer-data"
  exec_script --stack admin
  expect_rc0; expect_run admin-portainer-data; expect_run_archive admin-portainer-data
  expect_no_run portainer-data
  finish "admin_backs_up_named_volume"
}
postgres_name_equals_key_unchanged() {
  setup "postgres-data"
  exec_script --stack postgres
  expect_rc0; expect_run postgres-data
  finish "postgres_name_equals_key_unchanged"
}
observability_and_gateway_real_names() {
  setup "$OBS"
  exec_script --stack observability
  expect_rc0
  local v
  for v in $OBS; do expect_run "$v"; done
  expect_no_run grafana-data; expect_no_run loki-data
  setup "gateway-letsencrypt"
  exec_script --stack gateway
  expect_rc0; expect_run gateway-letsencrypt; expect_no_run letsencrypt
  finish "observability_and_gateway_real_names"
}
app_stack_real_name() {
  setup "freelance-prod-mysql-data"
  exec_script --stack freelance prod
  expect_rc0; expect_run freelance-prod-mysql-data
  finish "app_stack_real_name"
}
project_and_external_names() {
  setup "fx-test_plain
ext
real-ext
fx-test_opts"
  exec_script --stack fx test
  expect_rc0
  expect_run fx-test_plain; expect_run ext; expect_run real-ext; expect_run fx-test_opts
  expect_no_run extnamed
  finish "project_and_external_names"
}
label_name_does_not_override() {
  setup "fx-test_plain
ext
real-ext
fx-test_opts"
  exec_script --stack fx test
  expect_no_run decoy; expect_no_run decoy2
  if grep -qE 'decoy' "$TMP/run.log"; then fail "decoy name reached docker run"; fi
  finish "label_name_does_not_override"
}
missing_volume_no_empty_backup() {
  setup ""
  exec_script --stack admin
  expect_rc_nonzero; expect_err_has "admin-portainer-data"; expect_no_any_run
  expect_out_lacks "Volume backup completed."
  finish "missing_volume_no_empty_backup"
}
partial_stack_backs_up_rest() {
  setup "observability-grafana-data
observability-prometheus-data
observability-promtail-positions"
  exec_script --stack observability
  expect_rc_nonzero; expect_err_has "observability-loki-data"
  expect_run observability-grafana-data; expect_run observability-prometheus-data
  expect_run observability-promtail-positions; expect_no_run observability-loki-data
  expect_out_lacks "Volume backup completed."
  finish "partial_stack_backs_up_rest"
}
explicit_existing_volume() {
  setup "postgres-data"
  exec_script postgres-data
  expect_rc0; expect_run postgres-data
  finish "explicit_existing_volume"
}
explicit_missing_volume() {
  setup "postgres-data"
  exec_script postgres-data typo-data
  expect_rc_nonzero; expect_run postgres-data; expect_no_run typo-data; expect_err_has "typo-data"
  finish "explicit_missing_volume"
}
compose_config_failure_fails() {
  setup "data"
  exec_script --stack broken test
  expect_rc_nonzero; expect_no_any_run; expect_out_lacks "No named volumes found"
  finish "compose_config_failure_fails"
}
key_without_name_fails() {
  setup "data"
  exec_script --stack nameless test
  expect_rc_nonzero; expect_err_has "data"; expect_no_any_run
  finish "key_without_name_fails"
}
stack_without_volumes_ok() {
  setup ""
  exec_script --stack centrifugo
  expect_rc0; expect_out_has "No named volumes found to back up."; expect_no_any_run
  finish "stack_without_volumes_ok"
}
run_failure_removes_partial_archive() {
  setup "$OBS" "observability-loki-data"
  exec_script --stack observability
  expect_rc_nonzero
  expect_run observability-grafana-data; expect_run observability-prometheus-data
  expect_run observability-promtail-positions; expect_run observability-loki-data
  if ls "$TREE"/backups/volumes/observability-loki-data-* >/dev/null 2>&1; then fail "partial archive of failed volume left on disk"; fi
  expect_out_lacks "Volume backup completed."
  finish "run_failure_removes_partial_archive"
}

admin_backs_up_named_volume
postgres_name_equals_key_unchanged
observability_and_gateway_real_names
app_stack_real_name
project_and_external_names
label_name_does_not_override
missing_volume_no_empty_backup
partial_stack_backs_up_rest
explicit_existing_volume
explicit_missing_volume
compose_config_failure_fails
key_without_name_fails
stack_without_volumes_ok
run_failure_removes_partial_archive
exit "$RC_ALL"
