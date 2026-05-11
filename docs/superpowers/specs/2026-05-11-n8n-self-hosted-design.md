# n8n self-hosted design

## Goal

Prepare a production-ready n8n self-hosted stack for the existing single-VDS infra repository.

The stack must follow the repository's current Docker Compose conventions: Traefik for HTTPS routing, shared PostgreSQL over the external `data` network, persistent named volumes, Docker log rotation, and simple Makefile/script operations.

## Selected approach

Use one n8n container backed by the existing shared PostgreSQL instance.

This is the smallest durable setup for one VDS. It avoids SQLite for production data, avoids duplicating a PostgreSQL container, and leaves queue mode with Redis for a later scale step when workflow volume justifies the extra moving parts.

## Stack layout

Add a new top-level `n8n/` directory:

- `n8n/docker-compose.yml` defines the n8n service.
- `n8n/.env.example` documents required stack variables.
- `n8n/README.md` documents setup, deployment, health checks, and backup.

The stack is treated as an infra stack, not a generic app deployment under `deployments/`, because n8n is an operational platform component and has its own runtime conventions.

## Runtime configuration

The n8n container uses the official n8n Docker image and listens internally on port `5678`.

Core environment variables:

- `N8N_HOST` and `N8N_PROTOCOL=https` define the public host.
- `WEBHOOK_URL` is set to the public HTTPS URL so webhooks generated behind Traefik are correct.
- `N8N_ENCRYPTION_KEY` is required and stored only in the real untracked `n8n/.env`.
- `GENERIC_TIMEZONE` and `TZ` are passed from stack env.
- PostgreSQL settings point to `infra-postgres:5432` on the shared `data` network.

The real database password is stored in `n8n/.env`. The example file contains only placeholders.

## Networking and routing

The service joins:

- external `proxy` network for Traefik routing;
- external `data` network for PostgreSQL access.

Traefik labels expose n8n at `https://<N8N_HOST>/` with:

- `websecure` entrypoint;
- `letsencrypt` cert resolver;
- `default-chain@file` middleware;
- service port `5678`.

No host port is published.

## Persistence

Use named volume `n8n-data` mounted to `/home/node/.n8n`.

Even with PostgreSQL enabled, n8n still needs this directory for local runtime state. Backups must include both the shared PostgreSQL database and this volume.

## PostgreSQL

Create a dedicated database and user through the existing helper:

```bash
./scripts/create-postgres-app-db.sh n8n prod
```

Use the generated database name, user, and password in `n8n/.env`.

Expected connection:

- host: `infra-postgres`
- port: `5432`
- database: dedicated n8n database
- user: dedicated n8n user

## Operations

Add `make up-n8n` to create required external networks and run the stack with `docker compose --env-file .env up -d --remove-orphans`.

Extend infra stack recognition in scripts so these commands work:

```bash
./scripts/logs.sh n8n
./scripts/restart.sh n8n
./scripts/healthcheck.sh n8n
./scripts/backup-volumes.sh --stack n8n
```

Update top-level docs so n8n appears in the quick start, stack list, commands, and backup notes.

## Health checks

The container healthcheck calls n8n's local health endpoint on `127.0.0.1:5678`.

Deployment verification should include:

- Docker Compose config validation for `n8n/`;
- script stack resolution for `n8n`;
- a healthcheck after deployment on the server.

## Security

Secrets stay out of git. The real `n8n/.env` is ignored by the existing `**/.env` rule.

The implementation must not commit:

- database passwords;
- `N8N_ENCRYPTION_KEY`;
- generated runtime files;
- live n8n credentials or workflow exports.

Basic auth at Traefik is not part of the first version because n8n has its own authentication and user management. If an additional outer gate is needed later, it can be added as a Traefik middleware.

## Out of scope

This design does not include:

- queue mode;
- Redis;
- multiple n8n workers;
- a dedicated PostgreSQL container for n8n;
- workflow export/import automation;
- SSO;
- automated Uptime Kuma monitor creation.

These can be added later without changing the basic public URL, PostgreSQL database, or Traefik routing model.
