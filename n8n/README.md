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

If you will use the Telegram bot workflow, also set its runtime values before starting n8n:

- `BOT_ACCESS_PASSWORD`
- `MAX_AGENTS_PER_USER`
- `DEFAULT_AGENT_PROMPT`
- `DEFAULT_AGENT_WELCOME`
- `DEFAULT_AGENT_LANGUAGE`
- `DEFAULT_AGENT_VOICE_ID`
- `DEFAULT_AGENT_TTS_MODEL_ID`
- `DEFAULT_AGENT_LLM`

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

Open n8n and check that `Telegram ElevenLabs Bot` exists.

The expanded `Telegram ElevenLabs Bot` workflow uses the settings and credentials below. Until that expanded workflow JSON is imported, the committed workflow may only provide the rollout scaffold rather than the full bot behavior; documentation should not perform prophecy where version control has not yet provided evidence.

After the expanded workflow is imported, it is expected to handle:

- password-gated first access for unknown Telegram users;
- `/start` menu;
- `/agents` inline agent list and agent creation;
- prompt, welcome message, and text-only knowledge updates for the selected ElevenLabs agent.

Create a dedicated PostgreSQL database for bot business data:

```bash
./scripts/create-postgres-app-db.sh telegram-elevenlabs-bot prod
```

Create these n8n credentials manually after import:

- Telegram API credential for the bot token from BotFather;
- PostgreSQL credential pointing at the bot business database, not the n8n internal database;
- HTTP Header Auth credential for ElevenLabs with header name `xi-api-key` and the ElevenLabs API key as the value.

Attach credentials to the matching Telegram, PostgreSQL, and HTTP Request nodes in the workflow.

Set the bot runtime values in untracked `n8n/.env` before starting n8n. This repeats the Setup values with example defaults:

```env
BOT_ACCESS_PASSWORD=send-this-password-to-test-users
MAX_AGENTS_PER_USER=3
DEFAULT_AGENT_PROMPT="You are a helpful voice assistant."
DEFAULT_AGENT_WELCOME="Hello, how can I help you today?"
DEFAULT_AGENT_LANGUAGE=en
DEFAULT_AGENT_VOICE_ID=cjVigY5qzO86Huf0OWal
DEFAULT_AGENT_TTS_MODEL_ID=eleven_turbo_v2
DEFAULT_AGENT_LLM=gpt-4o-mini
```

Do not commit the real `BOT_ACCESS_PASSWORD` or ElevenLabs API key. The workflow reads them from runtime configuration and credentials; the export must stay secret-free.

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
