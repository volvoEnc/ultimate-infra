#!/usr/bin/env bash
# Tests for scripts/export-n8n-workflows.sh: the previous export must survive any failure
# and be replaced only by a complete new one. Real docker is never used: a stub answers
# `compose ps/exec` and `cp` against a fake "container root" inside a temp dir.
#   EXN_TREE_REF=<ref>  tree to test (default HEAD)
#   EXN_BASH5=1         run the script inside a Debian image with bash 5 (no network)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TREE="$TMP/tree"
CROOT="$TMP/croot"
mkdir -p "$TREE" "$CROOT" "$TMP/bin"
git -C "$REPO" archive "${EXN_TREE_REF:-HEAD}" | tar -x -C "$TREE"
printf 'N8N_VERSION=test\n' > "$TREE/n8n/.env"

# --- docker stub ---
{
  echo '#!/usr/bin/env bash'
  echo "TMP='$TMP'"
  echo "CROOT='$CROOT'"
} > "$TMP/bin/docker"
cat >> "$TMP/bin/docker" <<'STUB'
mode="$(< "$TMP/mode")"
cid="$(< "$TMP/ps_out")"
case "${1:-}" in
  compose)
    shift
    if [[ "${1:-}" == "--env-file" && "${3:-}" == "-f" ]]; then shift 4; fi
    echo "$*" >> "$TMP/calls.log"
    if [[ "$*" == "ps -q n8n" ]]; then
      printf '%s\n' "$cid"
    elif [[ "${1:-}" == exec && "${2:-}" == -T && "${3:-}" == n8n && "${4:-}" == rm && "${5:-}" == -rf && $# -eq 6 ]]; then
      rm -rf "${CROOT:?}$6"
    elif [[ "${1:-}" == exec && "${2:-}" == -T && "${3:-}" == n8n && "${4:-}" == n8n && "${5:-}" == export:workflow && "${6:-}" == --backup && "${7:-}" == --output=* && $# -eq 7 ]]; then
      p="$CROOT${7#--output=}"
      case "$mode" in
        export_fail) echo "export: boom" >&2; exit 1 ;;
        empty) mkdir -p "$p" ;;
        many) mkdir -p "$p"; touch $(seq -f "$p/wf%g.json" 1 2000) ;;
        *) mkdir -p "$p"; echo '{"n":1}' > "$p/wf1.json"; echo '{"n":2}' > "$p/wf2.json" ;;
      esac
    else
      echo "compose $*" >> "$TMP/forbidden.log"; exit 99
    fi
    ;;
  cp)
    echo "$*" >> "$TMP/calls.log"
    if [[ $# -ne 3 || "$2" != "$cid":* || -z "$cid" ]]; then
      echo "$*" >> "$TMP/forbidden.log"; exit 1
    fi
    src="$CROOT${2#*:}"; dest="$3"
    if [[ "$mode" == cp_fail ]]; then
      mkdir -p "$dest"; echo partial > "$dest/partial.json"; exit 1
    fi
    if [[ -d "$dest" ]]; then cp -R "$src" "$dest/"; else cp -R "$src" "$dest"; fi
    ;;
  *)
    echo "$*" >> "$TMP/forbidden.log"; exit 99
    ;;
esac
STUB
cat > "$TMP/bin/mv" <<'STUB'
#!/usr/bin/env bash
last="${!#}"
if [[ "$last" == */n8n/workflows-exported ]]; then
  if [[ -e "$TMP_FLAGS/fail_swap" && "$1" == */new ]]; then exit 1; fi
  if [[ -e "$TMP_FLAGS/fail_restore" ]]; then exit 1; fi
fi
exec /bin/mv "$@"
STUB
cat > "$TMP/bin/rm" <<'STUB'
#!/usr/bin/env bash
if [[ -e "$TMP_FLAGS/fail_rm_stage" ]]; then
  for a in "$@"; do
    if [[ "$a" == */n8n/.workflows-exported.* && "${a##*/n8n/}" != */* ]]; then exit 1; fi
  done
fi
exec /bin/rm "$@"
STUB
chmod +x "$TMP/bin/docker" "$TMP/bin/mv" "$TMP/bin/rm"
export TMP_FLAGS="$TMP/flags"

# --- harness ---
BAD=0
RC=0
RC_ALL=0
EXP="$TREE/n8n/workflows-exported"
setup() { # $1 = stub mode, $2 = 1 if a previous export exists, $3 = container id from ps
  rm -rf "$TMP/flags" "$CROOT" "$TREE"/n8n/.workflows-exported.* "$EXP"
  mkdir -p "$TMP/flags" "$CROOT"
  : > "$TMP/calls.log"; : > "$TMP/forbidden.log"
  printf '%s\n' "${1:-ok}" > "$TMP/mode"
  printf '%s' "${3-cid-test-1}" > "$TMP/ps_out"
  if [[ "${2:-1}" == 1 ]]; then mkdir -p "$EXP"; echo 'OLD-CONTENT' > "$EXP/old.json"; fi
}
exec_script() {
  set +e
  if [[ "${EXN_BASH5:-}" == 1 ]]; then
    docker run --rm --network none -v "$TMP:$TMP" -w "$TREE" -e TMP_FLAGS="$TMP/flags" pgvector/pgvector:pg17 \
      bash -c "PATH='$TMP/bin':\$PATH bash '$TREE/scripts/export-n8n-workflows.sh'" > "$TMP/out.txt" 2> "$TMP/err.txt"
  else
    (cd "$TREE" && PATH="$TMP/bin:$PATH" bash "$TREE/scripts/export-n8n-workflows.sh") > "$TMP/out.txt" 2> "$TMP/err.txt"
  fi
  RC=$?
  set -e
}
fail() { echo "  - $*"; BAD=1; }
expect_rc0() { [[ "$RC" == 0 ]] || fail "exit code $RC, expected 0; stderr: $(head -n 3 "$TMP/err.txt")"; }
expect_rc_nonzero() { [[ "$RC" != 0 ]] || fail "exit code 0, expected non-zero"; }
expect_err_has() { grep -qF -- "$1" "$TMP/err.txt" || fail "stderr lacks '$1'"; }
expect_err_lacks() { if grep -qF -- "$1" "$TMP/err.txt"; then fail "stderr has '$1'"; fi; }
expect_out_has() { grep -qF -- "$1" "$TMP/out.txt" || fail "stdout lacks '$1'"; }
names() { if [[ -d "$EXP" ]]; then find "$EXP" -mindepth 1 -maxdepth 1 | sed 's|.*/||' | sort | tr '\n' ' '; fi; }
expect_old_intact() {
  [[ "$(cat "$EXP/old.json" 2>/dev/null)" == "OLD-CONTENT" ]] || fail "old.json missing or changed in workflows-exported"
  [[ "$(names)" == "old.json " ]] || fail "workflows-exported has: '$(names)'"
}
expect_listing() { [[ "$(names)" == "$1" ]] || fail "workflows-exported is '$(names)', expected '$1'"; }
expect_no_stage() { if compgen -G "$TREE/n8n/.workflows-exported.*" >/dev/null; then fail "stage dir left in n8n/"; fi; }
expect_no_container_dir() { [[ ! -e "$CROOT/tmp/n8n-workflows-export" ]] || fail "export dir left in container"; }
finish() {
  if [[ -s "$TMP/forbidden.log" ]]; then fail "forbidden docker call: $(head -n 1 "$TMP/forbidden.log")"; fi
  if [[ "$BAD" == 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; RC_ALL=1; fi
  BAD=0
}

# --- cases ---
export_failure_keeps_previous() {
  setup export_fail
  exec_script
  expect_rc_nonzero; expect_old_intact; expect_err_has "previous export kept"; expect_no_stage
  finish export_failure_keeps_previous
}
cp_failure_keeps_previous() {
  setup cp_fail
  exec_script
  expect_rc_nonzero; expect_old_intact; expect_no_container_dir; expect_no_stage
  [[ ! -e "$EXP/partial.json" ]] || fail "partial.json leaked into result"
  finish cp_failure_keeps_previous
}
success_replaces_previous() {
  setup ok
  exec_script
  expect_rc0; expect_listing "wf1.json wf2.json "; expect_out_has "Workflows exported to:"; expect_no_stage
  finish success_replaces_previous
}
first_run_creates_export() {
  setup ok 0
  exec_script
  expect_rc0; expect_listing "wf1.json wf2.json "; expect_no_stage
  finish first_run_creates_export
}
empty_export_keeps_previous() {
  setup empty
  exec_script
  expect_rc_nonzero; expect_old_intact; expect_err_has "No workflows exported"; expect_no_stage
  finish empty_export_keeps_previous
}
not_running_keeps_previous() {
  setup ok 1 ""
  exec_script
  expect_rc_nonzero; expect_old_intact
  if grep -qE '^(exec|cp) ' "$TMP/calls.log"; then fail "exec or cp called although n8n is not running"; fi
  finish not_running_keeps_previous
}
cp_uses_compose_container_id() {
  setup ok 1 "cid-xyz"
  exec_script
  grep -qE '^cp cid-xyz:' "$TMP/calls.log" || fail "cp not addressed to cid-xyz"
  if grep -qF 'infra-n8n' "$TMP/calls.log"; then fail "hard-coded infra-n8n used"; fi
  finish cp_uses_compose_container_id
}
swap_failure_restores_previous() {
  setup ok
  : > "$TMP/flags/fail_swap"
  exec_script
  expect_rc_nonzero; expect_old_intact; expect_no_stage
  finish swap_failure_restores_previous
}
success_many_workflows() {
  setup many
  exec_script
  expect_rc0
  [[ "$(find "$EXP" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 2000 ]] || fail "expected 2000 files in result"
  [[ ! -e "$EXP/old.json" ]] || fail "old.json survived a successful export"
  expect_no_stage
  finish success_many_workflows
}
rollback_failure_keeps_previous_in_stage() {
  setup ok
  : > "$TMP/flags/fail_swap"; : > "$TMP/flags/fail_restore"
  exec_script
  expect_rc_nonzero
  local st
  st="$(compgen -G "$TREE/n8n/.workflows-exported.*" | head -n 1 || true)"
  if [[ -z "$st" ]]; then fail "stage dir removed although previous was not restored"
  else
    [[ "$(cat "$st/previous/old.json" 2>/dev/null)" == "OLD-CONTENT" ]] || fail "old.json not kept in stage/previous"
    expect_err_has "$st/previous"
  fi
  finish rollback_failure_keeps_previous_in_stage
}
cleanup_failure_after_swap_reports_new() {
  setup ok
  : > "$TMP/flags/fail_rm_stage"
  exec_script
  expect_rc_nonzero; expect_listing "wf1.json wf2.json "; expect_err_has "New export in place"
  expect_err_lacks "previous export kept"
  finish cleanup_failure_after_swap_reports_new
}

export_failure_keeps_previous
cp_failure_keeps_previous
success_replaces_previous
first_run_creates_export
empty_export_keeps_previous
not_running_keeps_previous
cp_uses_compose_container_id
swap_failure_restores_previous
success_many_workflows
rollback_failure_keeps_previous_in_stage
cleanup_failure_after_swap_reports_new
exit "$RC_ALL"
