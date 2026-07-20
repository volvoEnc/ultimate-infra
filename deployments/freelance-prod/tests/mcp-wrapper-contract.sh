#!/usr/bin/env sh

set -eu

test_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
stack_dir=$(CDPATH= cd "$test_dir/.." && pwd)
fake_bin=$(mktemp -d)
trap 'rm -rf "$fake_bin"' EXIT

cat > "$fake_bin/docker" <<'SH'
#!/usr/bin/env sh
set -eu

case "$*" in
    "inspect --format {{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}} freelance-prod-app")
        echo healthy
        ;;
    "exec -i freelance-prod-app php artisan migrate:status --pending --no-ansi")
        echo "No pending migrations"
        ;;
    "exec -i freelance-prod-app php artisan mcp:start freelance-ledger")
        cat >/dev/null
        echo '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"Freelance Ledger"}}}'
        ;;
    *)
        echo "Unexpected docker invocation: $*" >&2
        exit 1
        ;;
esac
SH
chmod +x "$fake_bin/docker"

result=$(PATH="$fake_bin:$PATH" "$stack_dir/scripts/freelance-ledger" --check 2>&1)
echo "$result" | grep -q 'MCP prerequisite check passed for container: freelance-prod-app.'
