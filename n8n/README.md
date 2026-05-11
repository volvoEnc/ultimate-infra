# n8n

`n8n/` runs a self-hosted n8n instance behind the shared Traefik gateway.

The stack uses:

- one official n8n container;
- the existing shared PostgreSQL service at `infra-postgres:5432`;
- the external `proxy` network for Traefik;
- the external `data` network for PostgreSQL;
- the named volume `n8n-data` for `/home/node/.n8n`.

## Setup

Create a dedicated PostgreSQL database and user:

```bash
./scripts/create-postgres-app-db.sh n8n prod
```

Copy the env example:

```bash
cp n8n/.env.example n8n/.env
chmod 600 n8n/.env
```

Set production values in `n8n/.env`:

- `N8N_HOST`
- `WEBHOOK_URL`
- `N8N_ENCRYPTION_KEY`
- `DB_POSTGRESDB_DATABASE`
- `DB_POSTGRESDB_USER`
- `DB_POSTGRESDB_PASSWORD`
- `GENERIC_TIMEZONE`
- `TZ`

Generate `N8N_ENCRYPTION_KEY` as a long random string and keep it stable. Changing it after credentials exist will make stored credentials unreadable.

## Start

```bash
make up-postgres
make up-gateway
make up-n8n
```

Open `https://<N8N_HOST>/` and complete n8n owner setup.

## Operations

```bash
./scripts/healthcheck.sh n8n
./scripts/logs.sh n8n
./scripts/restart.sh n8n
```

## Telegram bot workflow import

The `workflows/` directory is mounted into the container as `/workflows`.

Import all committed workflows:

```bash
make import-n8n-workflows
```

The import command starts n8n if needed, waits for the container healthcheck, imports each JSON file from `n8n/workflows/` explicitly, and restarts n8n so the running instance sees the imported workflows.

Workflow JSON files committed for CLI import must include a stable top-level `id`. n8n uses that ID to create or update the workflow record during import.

To import a single workflow:

```bash
./scripts/import-n8n-workflows.sh telegram-elevenlabs-bot
```

If your n8n instance uses projects and the imported workflow is not visible in the UI, set one of these values in `n8n/.env` and rerun the import:

```bash
N8N_IMPORT_PROJECT_ID=<project-id>
N8N_IMPORT_USER_ID=<user-id>
```

Open n8n and check that `Telegram ElevenLabs Bot` exists. Create a Telegram API credential with the bot token from BotFather, attach it to both Telegram nodes, then activate the workflow.

The first version handles incoming Telegram messages only:

- `/start` replies with the default welcome text.
- any other message gets a default "message received" reply.

ElevenLabs integration is intentionally left for the next workflow step, after the Telegram entry point is stable.

Export current workflows for inspection:

```bash
./scripts/export-n8n-workflows.sh
```

Exports go to `n8n/workflows-exported/`, which is ignored by git.

## Backup

Back up the Docker volume:

```bash
./scripts/backup-volumes.sh --stack n8n
```

Also back up the dedicated PostgreSQL database. The volume alone is not enough because workflows, credentials, and execution data live in PostgreSQL when `DB_TYPE=postgresdb`.

## Update

Before updating n8n:

```bash
./scripts/backup-env.sh
./scripts/backup-volumes.sh --stack n8n
```

Then update `N8N_VERSION` in `n8n/.env`, pull, and restart:

```bash
cd n8n
docker compose --env-file .env pull
docker compose --env-file .env up -d --remove-orphans
```
