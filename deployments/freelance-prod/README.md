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
