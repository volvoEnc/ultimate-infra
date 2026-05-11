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

Attach credentials to the matching Telegram, PostgreSQL, and HTTP Request nodes in the workflow. Name the ElevenLabs HTTP Header Auth credential `ElevenLabs API Key`, or update the imported workflow nodes to match your credential name.

Dynamic inline keyboards, including `/agents`, are sent through Telegram Bot API HTTP calls. n8n's native Telegram node stores inline keyboard rows as a fixedCollection shape, and that shape does not handle dynamic rows cleanly without the sort of ceremony usually reserved for minor court intrigues. Keep using the Telegram API credential for trigger and plain Telegram nodes, but set the HTTP base URL in the workflow settings below.

Open the `Normalize Telegram Update` node and edit the `workflowSettings` object at the top of the code before publishing the workflow:

```js
const workflowSettings = {
  botAccessPassword: 'send-this-password-to-test-users',
  telegramBotApiBaseUrl: 'https://api.telegram.org/bot<token>',
  maxAgentsPerUser: 3,
  defaultPrompt: 'You are a helpful voice assistant.',
  defaultWelcome: 'Hello, how can I help you today?',
  defaultLanguage: 'en',
  defaultVoiceId: 'cjVigY5qzO86Huf0OWal',
  defaultTtsModelId: 'eleven_turbo_v2',
  defaultLlm: 'gpt-4o-mini',
};
```

The workflow deliberately does not read these values through `process.env`: n8n 2.x runs Code nodes in task runners and may block environment access there by default. Do not commit or share workflow exports containing the real `botAccessPassword`, Telegram bot token, or ElevenLabs API key. Yes, this is the unromantic part where secrets punish optimism.

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
