#!/usr/bin/env sh

set -eu

test_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
stack_dir=$(CDPATH= cd "$test_dir/.." && pwd)
conf="$stack_dir/nginx/default.conf"
temporary_root=$(mktemp -d)
trap 'rm -rf "$temporary_root"' EXIT

: > "$temporary_root/app.env"
: > "$temporary_root/mysql.env"

fail() {
    printf 'Nginx upstream contract failed: %s\n' "$1" >&2
    exit 1
}

# The bare service name is ambiguous on the shared proxy network.
if grep -Eq 'fastcgi_pass[[:space:]]+app:' "$conf"; then
    fail 'fastcgi_pass must not use the bare service name app'
fi

grep -Eq '^[[:space:]]*resolver[[:space:]]+127\.0\.0\.11[[:space:];]' "$conf" \
    || fail 'resolver 127.0.0.11 (Docker DNS) is required for per-request resolution'
grep -Eq '^[[:space:]]*fastcgi_pass[[:space:]]+\$fpm_upstream;' "$conf" \
    || fail 'fastcgi_pass must go through the $fpm_upstream variable'

upstream_host=$(sed -nE 's/^[[:space:]]*set[[:space:]]+\$fpm_upstream[[:space:]]+([^:;]+):9000;.*/\1/p' "$conf")
[ -n "$upstream_host" ] || fail 'set $fpm_upstream <host>:9000 is missing'

configured=$(APP_ENV_FILE="$temporary_root/app.env" \
    MYSQL_ENV_FILE="$temporary_root/mysql.env" \
    docker compose \
    --env-file "$stack_dir/.env.example" \
    -f "$stack_dir/docker-compose.yml" \
    config 2>/dev/null) || fail 'docker compose config rejected the stack'

app_container=$(printf '%s\n' "$configured" \
    | awk '/^  app:$/ { in_app = 1; next } /^  [^ ]/ { in_app = 0 } in_app && /^    container_name:/ { print $2; exit }')
[ "$upstream_host" = "$app_container" ] \
    || fail "upstream host '$upstream_host' differs from app container_name '$app_container'"

printf '%s\n' "$configured" \
    | awk '/^  web:$/ { in_web = 1; next } /^  [^ ]/ { in_web = 0 } in_web' \
    | grep -Eq 'target: /etc/nginx/conf\.d/default\.conf' \
    || fail 'web must bind-mount nginx/default.conf over /etc/nginx/conf.d/default.conf'

# The web image's own config (freelance-ledger >= ad24e53) reaches FPM by this alias.
printf '%s\n' "$configured" \
    | awk '/^  app:$/ { in_app = 1; next } /^  [^ ]/ { in_app = 0 } in_app' \
    | grep -Eq '^ +- freelance-fpm$' \
    || fail 'app must carry the freelance-fpm network alias the web image relies on'

printf '%s\n' 'Freelance nginx upstream contract passed.'
