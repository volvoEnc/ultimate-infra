# Freelance Ledger production stack

Laravel runs as PHP-FPM behind a dedicated Nginx image. Traefik terminates TLS
and routes `freelance.danilka.tech` to the `web` service. MySQL is private to
the stack and persists in the `freelance-prod-mysql-data` volume.

Server-only files:

- `.env` — immutable image tags and public routing values;
- `../../env/prod/freelance.env` — Laravel, owner, and DB-user secrets (mode 600);
- `../../env/prod/freelance-mysql.env` — MySQL bootstrap and root secrets (mode 600).

Owner database sessions are encrypted explicitly by the stack. Client Jira,
Git links and private documents use Laravel encrypted casts, so every backup
must preserve the current `APP_KEY`. During key rotation keep the old key in
`APP_PREVIOUS_KEYS` until the encrypted workspace has been re-encrypted.

## Nginx upstream override

`nginx/default.conf` is bind-mounted over the config baked into the web image.
The image ships `fastcgi_pass app:9000`, but `web` is attached to the shared
`proxy` network as well, where other stacks run their own `app` service. After
a host reboot dockerd starts containers in no particular order: if `web` came
up before `app`, Docker DNS answered `app` with another stack's container,
nginx cached that IP, `/up` returned 502, Traefik dropped the unhealthy
container and the site served 404. The override addresses FPM by the unique
container name `freelance-prod-app` and resolves it per request through Docker
DNS (`resolver 127.0.0.11 valid=10s`), so start order and `app` recreation no
longer matter. Keep it in sync with `docker/prod/nginx.conf` of the app repo;
drop the mount once the image ships the same upstream. After editing the file,
restart `web` (a single-file bind mount keeps the old inode until then).

Deploy and verify from the infra root:

```bash
./scripts/deploy.sh freelance prod
./scripts/healthcheck.sh freelance prod
```

For Codex, open this stack directory as a trusted project and provide the
`FREELANCE_LEDGER_MCP_TOKEN` environment variable. The primary MCP transport is
the authenticated Streamable HTTP endpoint. A disabled stdio wrapper remains
available as an emergency server-local fallback:

```bash
scripts/freelance-ledger --check
codex mcp list
```

Seed the historical records once after the first successful deployment:

```bash
docker compose --env-file deployments/freelance-prod/.env \
  -f deployments/freelance-prod/docker-compose.yml \
  exec -T app php artisan db:seed --class=HistoricalNotesSeeder --force

docker compose --env-file deployments/freelance-prod/.env \
  -f deployments/freelance-prod/docker-compose.yml \
  exec -T app php artisan db:seed --class=SellersSeeder --force
```

Rollback: restore the previous `APP_IMAGE` and `WEB_IMAGE` tags in `.env`, then
run the deploy script again. New workspace tables are additive, so an older
image safely ignores them; database rollback is deliberately separate. Before
deploy, preserve both a consistent MySQL dump and the server-only env/stack
configuration with mode `0600`.
