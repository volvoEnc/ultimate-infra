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

Open n8n and check that `Telegram ElevenLabs Bot` exists.

The committed `Telegram ElevenLabs Bot` workflow uses the settings and credentials below. After import, it handles:

- password-gated first access for unknown Telegram users;
- `/start` menu;
- `/agents` inline agent list and agent creation;
- prompt, welcome message, and text-only knowledge updates for the selected ElevenLabs agent.
- local ownership checks so Telegram users only operate on agents stored under their own user record;
- bot event logging for successful key operations and selected failure paths.

Create a dedicated PostgreSQL database for bot business data:

```bash
./scripts/create-postgres-app-db.sh telegram-elevenlabs-bot prod
```

Create these n8n credentials manually after import:

- Telegram API credential for the bot token from BotFather;
- PostgreSQL credential pointing at the bot business database, not the n8n internal database;
- HTTP Header Auth credential for ElevenLabs with header name `xi-api-key` and the ElevenLabs API key as the value.

Attach credentials to the matching Telegram, PostgreSQL, and HTTP Request nodes in the workflow. The committed workflow intentionally does not include credential IDs because n8n treats exported IDs as real database records; placeholder IDs turn into very sincere runtime failures. Name the ElevenLabs HTTP Header Auth credential `ElevenLabs API Key`, then select it manually in every ElevenLabs HTTP Request node.

Dynamic inline keyboards, including `/agents`, are sent through Telegram Bot API HTTP calls. n8n's native Telegram node stores inline keyboard rows as a fixedCollection shape, and that shape does not handle dynamic rows cleanly without the sort of ceremony usually reserved for minor court intrigues. Keep using the Telegram API credential for trigger and plain Telegram nodes, but store the HTTP base URL in the bot business database.

The workflow creates a singleton `bot_settings` table in the bot business database. After the workflow has run once, or after you create the table manually from the workflow SQL, set the runtime values there:

```sql
UPDATE bot_settings
SET
  bot_access_password = 'send-this-password-to-test-users',
  telegram_bot_api_base_url = 'https://api.telegram.org/bot<token>',
  max_agents_per_user = 3,
  default_agent_prompt = 'You are a helpful voice assistant.',
  default_agent_welcome = 'Hello, how can I help you today?',
  default_agent_language = 'en',
  default_agent_voice_id = 'cjVigY5qzO86Huf0OWal',
  default_agent_tts_model_id = 'eleven_turbo_v2',
  default_agent_llm = 'gpt-4o-mini',
  updated_at = now()
WHERE id = 1;
```

The access password is compared inside the `Load Bot Settings` SQL query and is not passed into later Code nodes. The workflow deliberately does not read these values through `process.env`: n8n 2.x runs Code nodes in task runners and may block environment access there by default. Do not commit DB dumps or workflow exports containing real Telegram or ElevenLabs secrets. Yes, this is the unromantic part where secrets punish optimism.

The bot intentionally accepts only text messages for agent names, prompt updates, welcome message updates, and knowledge content. Files, voice messages, and other Telegram payloads receive a text-only error reply rather than being sent to ElevenLabs.

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
