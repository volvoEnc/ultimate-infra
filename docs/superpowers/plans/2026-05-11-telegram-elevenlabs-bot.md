# Telegram ElevenLabs Bot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing n8n Telegram workflow so password-approved Telegram users can create and manage their own ElevenLabs agents.

**Architecture:** Keep one importable n8n workflow and turn it into a stateful router. Store bot business data in a separate PostgreSQL database, call ElevenLabs through HTTP Request nodes with n8n credentials, and keep Telegram replies centralized so failures do not become a choose-your-own-adventure novel.

**Tech Stack:** n8n workflow JSON, PostgreSQL, Telegram node, HTTP Request node, Code node JavaScript, Docker Compose env, bash, jq.

---

## Source References

- Design spec: `docs/superpowers/specs/2026-05-11-telegram-elevenlabs-bot-design.md`
- Existing workflow: `n8n/workflows/telegram-elevenlabs-bot.json`
- n8n Telegram Message operations: `https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.telegram/message-operations/`
- n8n Telegram Callback operations: `https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.telegram/callback-operations/`
- ElevenLabs Create agent: `https://elevenlabs.io/docs/eleven-agents/api-reference/agents/create`
- ElevenLabs Get agent: `https://elevenlabs.io/docs/eleven-agents/api-reference/agents/get`
- ElevenLabs Update agent: `https://elevenlabs.io/docs/api-reference/agents/update`
- ElevenLabs Create text knowledge: `https://elevenlabs.io/docs/eleven-agents/api-reference/knowledge-base/create-from-text`
- ElevenLabs Delete knowledge: `https://elevenlabs.io/docs/eleven-agents/api-reference/knowledge-base/delete`

## File Structure

- Modify `n8n/docker-compose.yml`: expose bot runtime settings to the n8n container.
- Modify `n8n/.env.example`: document bot access password, agent limit, and default ElevenLabs agent values.
- Modify `n8n/README.md`: document bot database setup, credentials, env settings, import, and smoke test.
- Modify `n8n/workflows/telegram-elevenlabs-bot.json`: replace the current 3-node smoke workflow with the stateful Telegram/DB/ElevenLabs workflow.
- Create `scripts/check-telegram-elevenlabs-workflow.sh`: validate the committed workflow shape and secret hygiene.
- Modify `Makefile`: add a convenience validation target.

Implementation note: the workflow JSON should keep the stable top-level id `tgElevenLabsBot01` so the existing import script updates the same workflow instead of birthing a duplicate. Duplicates in n8n are like invoices in email threads: nobody knows which one is real until production answers.

## Workflow Node Map

Use these node names exactly. The validation script depends on them.

- `Telegram Trigger`: receives `message` and `callback_query`.
- `Normalize Telegram Update`: Code node; extracts user, chat, text, callback, and env settings.
- `Ensure Bot DB Schema`: PostgreSQL node; creates tables and indexes.
- `Load User Context`: PostgreSQL node; loads the current user, active agent, and agent list.
- `Route Telegram Event`: Code node; computes the next action.
- `Route Switch`: Switch node; branches by `route`.
- `Register User`: PostgreSQL node; inserts a new user after password success.
- `Refresh User Context`: PostgreSQL node; reloads context after registration or state changes.
- `Set Dialog State`: PostgreSQL node; updates `dialog_state` and optional `active_agent_id`.
- `Create ElevenLabs Agent`: HTTP Request node; calls `POST /v1/convai/agents/create`.
- `Save Created Agent`: PostgreSQL node; saves created agent and makes it active.
- `Get ElevenLabs Agent`: HTTP Request node; fetches current agent config before prompt, welcome, or knowledge patch.
- `Create Knowledge Document`: HTTP Request node; creates a text knowledge document.
- `Build ElevenLabs Patch`: Code node; merges the requested change into `conversation_config`.
- `Patch ElevenLabs Agent`: HTTP Request node; applies the agent update.
- `Save Agent Update`: PostgreSQL node; persists local cache and clears state.
- `Delete Old Knowledge Document`: HTTP Request node; best-effort cleanup after knowledge replacement.
- `Log Bot Event`: PostgreSQL node; records system errors and cleanup failures.
- `Answer Callback Query`: Telegram node; answers callback queries with a short notification.
- `Reply in Telegram`: Telegram node; sends the final user-facing message.

For every PostgreSQL node in this plan, use the node's Execute Query operation and parameter bindings. Do not interpolate Telegram text directly into SQL. It is depressingly easy to turn a bot into a public SQL console when convenience gets promoted above survival.

## Shared Snippets

Use this schema SQL in `Ensure Bot DB Schema`:

```sql
CREATE TABLE IF NOT EXISTS telegram_users (
  id bigserial PRIMARY KEY,
  telegram_user_id bigint NOT NULL UNIQUE,
  chat_id bigint NOT NULL,
  username text,
  first_name text,
  last_name text,
  active_agent_id bigint,
  dialog_state text NOT NULL DEFAULT 'idle',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS elevenlabs_agents (
  id bigserial PRIMARY KEY,
  user_id bigint NOT NULL REFERENCES telegram_users(id) ON DELETE CASCADE,
  elevenlabs_agent_id text NOT NULL UNIQUE,
  display_name text NOT NULL,
  knowledge_document_id text,
  prompt_text text,
  welcome_text text,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bot_events (
  id bigserial PRIMARY KEY,
  user_id bigint REFERENCES telegram_users(id) ON DELETE SET NULL,
  agent_id bigint REFERENCES elevenlabs_agents(id) ON DELETE SET NULL,
  event_type text NOT NULL,
  status text NOT NULL,
  error_message text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_telegram_users_telegram_user_id
  ON telegram_users(telegram_user_id);
CREATE INDEX IF NOT EXISTS idx_elevenlabs_agents_user_id
  ON elevenlabs_agents(user_id);
CREATE INDEX IF NOT EXISTS idx_elevenlabs_agents_elevenlabs_agent_id
  ON elevenlabs_agents(elevenlabs_agent_id);
CREATE INDEX IF NOT EXISTS idx_bot_events_user_created_at
  ON bot_events(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bot_events_agent_created_at
  ON bot_events(agent_id, created_at DESC);
```

Use this JavaScript body in `Normalize Telegram Update`:

```javascript
const update = $json;
const callback = update.callback_query ?? null;
const message = update.message ?? callback?.message ?? {};
const from = update.message?.from ?? callback?.from ?? {};
const chat = message.chat ?? {};
const messageText = typeof update.message?.text === 'string' ? update.message.text : '';
const callbackData = typeof callback?.data === 'string' ? callback.data : '';

const numberOrNull = (value) => {
  if (value === undefined || value === null || value === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
};

return [
  {
    json: {
      updateType: callback ? 'callback_query' : 'message',
      telegramUserId: numberOrNull(from.id),
      chatId: numberOrNull(chat.id),
      messageId: numberOrNull(message.message_id),
      callbackQueryId: callback?.id ?? '',
      callbackData,
      messageText,
      trimmedText: messageText.trim(),
      command: messageText.trim().split(/\s+/)[0] || '',
      isTextMessage: Boolean(update.message && typeof update.message.text === 'string'),
      isCallback: Boolean(callback),
      username: from.username ?? '',
      firstName: from.first_name ?? '',
      lastName: from.last_name ?? '',
      settings: {
        accessPassword: process.env.BOT_ACCESS_PASSWORD ?? '',
        maxAgentsPerUser: Number.parseInt(process.env.MAX_AGENTS_PER_USER ?? '3', 10),
        defaultPrompt: process.env.DEFAULT_AGENT_PROMPT ?? 'You are a helpful voice assistant.',
        defaultWelcome: process.env.DEFAULT_AGENT_WELCOME ?? 'Hello, how can I help you today?',
        defaultLanguage: process.env.DEFAULT_AGENT_LANGUAGE ?? 'en',
        defaultVoiceId: process.env.DEFAULT_AGENT_VOICE_ID ?? 'cjVigY5qzO86Huf0OWal',
        defaultTtsModelId: process.env.DEFAULT_AGENT_TTS_MODEL_ID ?? 'eleven_turbo_v2',
        defaultLlm: process.env.DEFAULT_AGENT_LLM ?? 'gpt-4o-mini',
      },
    },
  },
];
```

Use this SQL in `Load User Context` and `Refresh User Context`. Bind `$1` to `telegramUserId`.

```sql
WITH current_user AS (
  SELECT *
  FROM telegram_users
  WHERE telegram_user_id = $1
),
agent_rows AS (
  SELECT
    a.id,
    a.elevenlabs_agent_id,
    a.display_name,
    a.knowledge_document_id,
    a.prompt_text,
    a.welcome_text,
    a.status,
    a.created_at,
    (a.id = (SELECT active_agent_id FROM current_user)) AS is_active
  FROM elevenlabs_agents a
  WHERE a.user_id = (SELECT id FROM current_user)
    AND a.status = 'active'
  ORDER BY a.created_at ASC
),
active_agent AS (
  SELECT *
  FROM agent_rows
  WHERE is_active
  LIMIT 1
)
SELECT
  COALESCE(to_jsonb((SELECT row_to_json(current_user) FROM current_user)), 'null'::jsonb) AS user_record,
  COALESCE((SELECT jsonb_agg(to_jsonb(agent_rows)) FROM agent_rows), '[]'::jsonb) AS agents,
  COALESCE(to_jsonb((SELECT row_to_json(active_agent) FROM active_agent)), 'null'::jsonb) AS active_agent;
```

Use this JavaScript body in `Route Telegram Event`. It assumes the normalized update and DB context are merged into the item JSON before the Code node. If the PostgreSQL node returns only DB columns, add a Set node before this step to merge the normalized fields back into the item.

```javascript
const user = typeof $json.user_record === 'string' ? JSON.parse($json.user_record) : $json.user_record;
const agents = typeof $json.agents === 'string' ? JSON.parse($json.agents) : ($json.agents ?? []);
const activeAgent = typeof $json.active_agent === 'string' ? JSON.parse($json.active_agent) : $json.active_agent;
const settings = $json.settings ?? {};
const maxAgents = Number.isFinite(settings.maxAgentsPerUser) ? settings.maxAgentsPerUser : 3;

const button = (text, data) => ({ text, callback_data: data });
const agentsKeyboard = () => {
  const rows = agents.map((agent) => [button(agent.is_active ? `✓ ${agent.display_name}` : agent.display_name, `ag:sel:${agent.id}`)]);
  if (agents.length < maxAgents) rows.push([button('Создать агента', 'ag:new')]);
  return { inline_keyboard: rows };
};
const actionsKeyboard = () => ({
  inline_keyboard: [
    [button('Изменить prompt', 'ag:p')],
    [button('Изменить приветствие', 'ag:w')],
    [button('Обновить knowledge', 'ag:k')],
    [button('Список агентов', 'ag:list')],
  ],
});
const menuText = () => [
  'Доступ открыт.',
  `Лимит агентов: ${maxAgents}.`,
  'Команда /agents покажет список агентов и действия.',
].join('\n');
const reply = (route, text, extra = {}) => [{ json: { ...$json, route, replyText: text, replyMarkup: extra.replyMarkup ?? null, ...extra } }];

if (!$json.telegramUserId || !$json.chatId) {
  return reply('reply', 'Не вижу Telegram user id или chat id. Попробуйте отправить сообщение еще раз.');
}

if (!user) {
  if (!settings.accessPassword) {
    return reply('reply', 'Доступ временно не настроен. Попробуйте позже.');
  }
  if ($json.isTextMessage && $json.trimmedText === settings.accessPassword) {
    return reply('register_user', menuText());
  }
  return reply('reply', 'Пришлите пароль доступа текстовым сообщением.');
}

if ($json.isCallback && $json.callbackData) {
  if ($json.callbackData === 'ag:list') {
    return reply('reply', agents.length ? 'Ваши агенты:' : 'У вас пока нет агентов.', { replyMarkup: agentsKeyboard(), answerCallback: true });
  }
  if ($json.callbackData === 'ag:new') {
    if (agents.length >= maxAgents) {
      return reply('reply', `Лимит агентов исчерпан: ${maxAgents}.`, { answerCallback: true });
    }
    return reply('set_state', 'Как назвать нового агента? Пришлите имя текстом.', { nextState: 'awaiting_agent_name', answerCallback: true });
  }
  if ($json.callbackData.startsWith('ag:sel:')) {
    const localAgentId = Number.parseInt($json.callbackData.slice('ag:sel:'.length), 10);
    const selected = agents.find((agent) => agent.id === localAgentId);
    if (!selected) return reply('reply', 'Этот агент вам не принадлежит. Выберите агента через /agents.', { answerCallback: true });
    return reply('set_active_agent', `Выбран агент: ${selected.display_name}`, { activeAgentId: localAgentId, replyMarkup: actionsKeyboard(), answerCallback: true });
  }
  if (['ag:p', 'ag:w', 'ag:k'].includes($json.callbackData)) {
    if (!activeAgent?.id) return reply('reply', 'Сначала выберите агента через /agents.', { answerCallback: true });
    const states = { 'ag:p': 'awaiting_prompt', 'ag:w': 'awaiting_welcome', 'ag:k': 'awaiting_knowledge' };
    const texts = {
      'ag:p': 'Пришлите новый prompt текстом.',
      'ag:w': 'Пришлите новое приветствие текстом.',
      'ag:k': 'Пришлите новый knowledge content текстом.',
    };
    return reply('set_state', texts[$json.callbackData], { nextState: states[$json.callbackData], answerCallback: true });
  }
  return reply('reply', 'Неизвестное действие. Откройте /agents.', { answerCallback: true });
}

if ($json.command === '/start') return reply('reset_to_menu', menuText(), { nextState: 'idle' });
if ($json.command === '/agents') return reply('reply', agents.length ? 'Ваши агенты:' : 'У вас пока нет агентов.', { replyMarkup: agentsKeyboard() });

if (user.dialog_state === 'awaiting_agent_name') {
  if (!$json.isTextMessage || !$json.trimmedText) return reply('reply', 'Имя агента нужно отправить текстом.');
  if (agents.length >= maxAgents) return reply('reset_to_menu', `Лимит агентов исчерпан: ${maxAgents}.`, { nextState: 'idle' });
  return reply('create_agent', 'Создаю агента...', { agentName: $json.trimmedText });
}

if (['awaiting_prompt', 'awaiting_welcome', 'awaiting_knowledge'].includes(user.dialog_state)) {
  if (!activeAgent?.id) return reply('reset_to_menu', 'Сначала выберите агента через /agents.');
  if (!$json.isTextMessage || !$json.trimmedText) return reply('reply', 'Пришлите текст. Файлы, голосовые и прочая роскошь в этой версии не принимаются.');
  const routeByState = {
    awaiting_prompt: 'update_prompt',
    awaiting_welcome: 'update_welcome',
    awaiting_knowledge: 'update_knowledge',
  };
  return reply(routeByState[user.dialog_state], 'Обновляю агента...', { newText: $json.trimmedText });
}

return reply('reply', 'Откройте /agents, чтобы выбрать или создать агента.');
```

Use this JavaScript body in `Build ElevenLabs Patch`:

```javascript
const current = $json.elevenlabsAgent ?? $json;
const conversationConfig = structuredClone(current.conversation_config ?? {});
conversationConfig.agent = conversationConfig.agent ?? {};
conversationConfig.agent.prompt = conversationConfig.agent.prompt ?? {};

if ($json.route === 'update_prompt') {
  conversationConfig.agent.prompt.prompt = $json.newText;
}

if ($json.route === 'update_welcome') {
  conversationConfig.agent.first_message = $json.newText;
}

if ($json.route === 'update_knowledge') {
  conversationConfig.agent.prompt.knowledge_base = [
    {
      type: 'text',
      name: $json.newKnowledgeDocumentName,
      id: $json.newKnowledgeDocumentId,
      usage_mode: 'prompt',
    },
  ];
}

return [
  {
    json: {
      ...$json,
      elevenlabsPatchBody: {
        conversation_config: conversationConfig,
      },
    },
  },
];
```

## Task 1: Add Workflow Validation Harness

**Files:**
- Create: `scripts/check-telegram-elevenlabs-workflow.sh`
- Modify: `Makefile`

- [ ] **Step 1: Write the failing validation script**

Create `scripts/check-telegram-elevenlabs-workflow.sh`:

```bash
#!/usr/bin/env bash

set -euo pipefail

WORKFLOW_PATH="${1:-n8n/workflows/telegram-elevenlabs-bot.json}"

if [[ ! -f "$WORKFLOW_PATH" ]]; then
  echo "Workflow file not found: $WORKFLOW_PATH" >&2
  exit 1
fi

jq -e '.id == "tgElevenLabsBot01"' "$WORKFLOW_PATH" >/dev/null
jq -e '.name == "Telegram ElevenLabs Bot"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Telegram Trigger") | .parameters.updates | index("message")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Telegram Trigger") | .parameters.updates | index("callback_query")' "$WORKFLOW_PATH" >/dev/null

required_nodes=(
  "Normalize Telegram Update"
  "Ensure Bot DB Schema"
  "Load User Context"
  "Route Telegram Event"
  "Route Switch"
  "Register User"
  "Refresh User Context"
  "Set Dialog State"
  "Create ElevenLabs Agent"
  "Save Created Agent"
  "Get ElevenLabs Agent"
  "Create Knowledge Document"
  "Build ElevenLabs Patch"
  "Patch ElevenLabs Agent"
  "Save Agent Update"
  "Delete Old Knowledge Document"
  "Log Bot Event"
  "Answer Callback Query"
  "Reply in Telegram"
)

for node_name in "${required_nodes[@]}"; do
  jq -e --arg node_name "$node_name" '.nodes[] | select(.name == $node_name)' "$WORKFLOW_PATH" >/dev/null
done

jq -e '[.nodes[] | select(.type == "n8n-nodes-base.postgres")] | length >= 6' "$WORKFLOW_PATH" >/dev/null
jq -e '[.nodes[] | select(.type == "n8n-nodes-base.httpRequest")] | length >= 5' "$WORKFLOW_PATH" >/dev/null
jq -e '[.nodes[] | select(.type == "n8n-nodes-base.code")] | length >= 3' "$WORKFLOW_PATH" >/dev/null

if grep -E 'xi-api-key"[[:space:]]*:[[:space:]]*"[^=]' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow appears to contain a literal ElevenLabs API key header." >&2
  exit 1
fi

if grep -E 'BOT_ACCESS_PASSWORD[[:space:]]*=' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow appears to contain a literal access password assignment." >&2
  exit 1
fi

echo "Telegram ElevenLabs workflow validation passed."
```

- [ ] **Step 2: Make the script executable**

Run:

```bash
chmod +x scripts/check-telegram-elevenlabs-workflow.sh
```

Expected: command exits with status 0.

- [ ] **Step 3: Run validation and verify it fails against the current workflow**

Run:

```bash
./scripts/check-telegram-elevenlabs-workflow.sh
```

Expected: FAIL because the current Telegram Trigger only listens to `message` and the new required nodes do not exist.

- [ ] **Step 4: Add Makefile target**

Modify `Makefile`:

```make
.PHONY: help up-gateway up-postgres up-registry up-observability up-admin up-uptime up-centrifugo up-n8n import-n8n-workflows check-telegram-elevenlabs-workflow deploy logs status init-server
```

Add this line to the help output:

```make
	  '  make check-telegram-elevenlabs-workflow' \
```

Add this target after `import-n8n-workflows`:

```make
check-telegram-elevenlabs-workflow:
	./scripts/check-telegram-elevenlabs-workflow.sh
```

- [ ] **Step 5: Run the target and verify it fails for the same reason**

Run:

```bash
make check-telegram-elevenlabs-workflow
```

Expected: FAIL because the workflow has not been expanded yet.

- [ ] **Step 6: Commit validation harness**

```bash
git add Makefile scripts/check-telegram-elevenlabs-workflow.sh
git commit -m "test: add telegram elevenlabs workflow validation"
```

## Task 2: Add Runtime Settings and Documentation

**Files:**
- Modify: `n8n/docker-compose.yml`
- Modify: `n8n/.env.example`
- Modify: `n8n/README.md`

- [ ] **Step 1: Expose bot settings in Docker Compose**

In `n8n/docker-compose.yml`, add these entries under `services.n8n.environment` after `DB_POSTGRESDB_SCHEMA`:

```yaml
      BOT_ACCESS_PASSWORD: ${BOT_ACCESS_PASSWORD}
      MAX_AGENTS_PER_USER: ${MAX_AGENTS_PER_USER}
      DEFAULT_AGENT_PROMPT: ${DEFAULT_AGENT_PROMPT}
      DEFAULT_AGENT_WELCOME: ${DEFAULT_AGENT_WELCOME}
      DEFAULT_AGENT_LANGUAGE: ${DEFAULT_AGENT_LANGUAGE}
      DEFAULT_AGENT_VOICE_ID: ${DEFAULT_AGENT_VOICE_ID}
      DEFAULT_AGENT_TTS_MODEL_ID: ${DEFAULT_AGENT_TTS_MODEL_ID}
      DEFAULT_AGENT_LLM: ${DEFAULT_AGENT_LLM}
```

- [ ] **Step 2: Add example env values**

In `n8n/.env.example`, add this block after `N8N_IMPORT_USER_ID=`:

```dotenv

# Telegram ElevenLabs bot runtime settings.
# Use a real shared password only in untracked n8n/.env.
BOT_ACCESS_PASSWORD=example-access-password-change-me
MAX_AGENTS_PER_USER=3
DEFAULT_AGENT_PROMPT="You are a helpful voice assistant."
DEFAULT_AGENT_WELCOME="Hello, how can I help you today?"
DEFAULT_AGENT_LANGUAGE=en
DEFAULT_AGENT_VOICE_ID=cjVigY5qzO86Huf0OWal
DEFAULT_AGENT_TTS_MODEL_ID=eleven_turbo_v2
DEFAULT_AGENT_LLM=gpt-4o-mini
```

- [ ] **Step 3: Update README setup docs**

In `n8n/README.md`, replace the current "The first version handles incoming Telegram messages only" paragraph and bullets with:

````markdown
The committed `Telegram ElevenLabs Bot` workflow handles:

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

Set these bot runtime values in untracked `n8n/.env` before starting n8n:

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
````

- [ ] **Step 4: Validate Compose config**

Run:

```bash
cd n8n && docker compose --env-file .env.example config >/tmp/n8n-compose-config.yml
```

Expected: PASS. If it fails because Docker is not available locally, run:

```bash
cd n8n && docker compose --env-file .env.example config
```

Expected if Docker exists: rendered compose output contains the new bot environment variables.

- [ ] **Step 5: Commit runtime docs**

```bash
git add n8n/docker-compose.yml n8n/.env.example n8n/README.md
git commit -m "docs: document telegram elevenlabs bot settings"
```

## Task 3: Expand Workflow Skeleton

**Files:**
- Modify: `n8n/workflows/telegram-elevenlabs-bot.json`

- [ ] **Step 1: Update Telegram Trigger**

In `n8n/workflows/telegram-elevenlabs-bot.json`, update `Telegram Trigger.parameters.updates` to:

```json
[
  "message",
  "callback_query"
]
```

- [ ] **Step 2: Replace the smoke Set node with workflow router nodes**

Remove `Prepare Telegram Reply`. Add the node names listed in "Workflow Node Map" using these node types:

```json
[
  { "name": "Normalize Telegram Update", "type": "n8n-nodes-base.code", "typeVersion": 2 },
  { "name": "Ensure Bot DB Schema", "type": "n8n-nodes-base.postgres", "typeVersion": 2.6 },
  { "name": "Load User Context", "type": "n8n-nodes-base.postgres", "typeVersion": 2.6 },
  { "name": "Route Telegram Event", "type": "n8n-nodes-base.code", "typeVersion": 2 },
  { "name": "Route Switch", "type": "n8n-nodes-base.switch", "typeVersion": 3.2 },
  { "name": "Answer Callback Query", "type": "n8n-nodes-base.telegram", "typeVersion": 1.2 },
  { "name": "Reply in Telegram", "type": "n8n-nodes-base.telegram", "typeVersion": 1.2 }
]
```

Keep `Reply in Telegram` as the final user-facing message node.

- [ ] **Step 3: Configure `Normalize Telegram Update`**

Set its Code node JavaScript to the exact `Normalize Telegram Update` snippet in "Shared Snippets".

- [ ] **Step 4: Configure `Ensure Bot DB Schema`**

Set it to execute the exact schema SQL in "Shared Snippets".

- [ ] **Step 5: Configure `Load User Context`**

Set it to execute the exact `Load User Context` SQL in "Shared Snippets" with query parameter:

```text
={{ $json.telegramUserId }}
```

- [ ] **Step 6: Configure `Route Telegram Event`**

Set its Code node JavaScript to the exact `Route Telegram Event` snippet in "Shared Snippets".

- [ ] **Step 7: Wire the base chain**

Configure connections:

```text
Telegram Trigger -> Normalize Telegram Update
Normalize Telegram Update -> Ensure Bot DB Schema
Ensure Bot DB Schema -> Load User Context
Load User Context -> Route Telegram Event
Route Telegram Event -> Route Switch
```

- [ ] **Step 8: Run JSON validation**

Run:

```bash
jq empty n8n/workflows/telegram-elevenlabs-bot.json
```

Expected: PASS.

- [ ] **Step 9: Run workflow validation and verify remaining failures**

Run:

```bash
./scripts/check-telegram-elevenlabs-workflow.sh
```

Expected: FAIL because action nodes for DB writes and ElevenLabs calls are not all present yet.

## Task 4: Implement Access Gate, Menu, and State Writes

**Files:**
- Modify: `n8n/workflows/telegram-elevenlabs-bot.json`

- [ ] **Step 1: Add `Register User` PostgreSQL node**

Configure `Register User` with this query. Bind parameters in order: `telegramUserId`, `chatId`, `username`, `firstName`, `lastName`.

```sql
INSERT INTO telegram_users (
  telegram_user_id,
  chat_id,
  username,
  first_name,
  last_name,
  dialog_state,
  updated_at
)
VALUES ($1, $2, NULLIF($3, ''), NULLIF($4, ''), NULLIF($5, ''), 'idle', now())
ON CONFLICT (telegram_user_id) DO UPDATE
SET
  chat_id = EXCLUDED.chat_id,
  username = EXCLUDED.username,
  first_name = EXCLUDED.first_name,
  last_name = EXCLUDED.last_name,
  dialog_state = 'idle',
  updated_at = now()
RETURNING *;
```

- [ ] **Step 2: Add `Set Dialog State` PostgreSQL node**

Configure it with this query. Bind parameters in order: `telegramUserId`, `nextState`, `activeAgentId`.

```sql
UPDATE telegram_users
SET
  dialog_state = COALESCE(NULLIF($2, ''), dialog_state),
  active_agent_id = COALESCE(NULLIF($3, '')::bigint, active_agent_id),
  updated_at = now()
WHERE telegram_user_id = $1
RETURNING *;
```

- [ ] **Step 3: Add `Refresh User Context` PostgreSQL node**

Use the exact `Load User Context` SQL in "Shared Snippets" and bind `$1` to `telegramUserId`.

- [ ] **Step 4: Configure `Answer Callback Query`**

Set Telegram node parameters:

```json
{
  "resource": "callback",
  "operation": "answerQuery",
  "queryId": "={{ $json.callbackQueryId }}",
  "additionalFields": {
    "text": "Готово"
  }
}
```

- [ ] **Step 5: Configure `Reply in Telegram`**

Set Telegram node parameters:

```json
{
  "resource": "message",
  "operation": "sendMessage",
  "chatId": "={{ $json.chatId }}",
  "text": "={{ $json.replyText }}",
  "replyMarkup": "inlineKeyboard",
  "inlineKeyboard": "={{ $json.replyMarkup ? $json.replyMarkup.inline_keyboard : [] }}",
  "additionalFields": {
    "appendAttribution": false,
    "reply_to_message_id": "={{ $json.messageId || undefined }}"
  }
}
```

If the native Telegram node cannot accept a dynamic `inlineKeyboard` expression in this shape, configure `replyMarkup` as `none` for plain replies and use the node UI's Inline Keyboard row mapping for menu replies. Keep the same `replyMarkup` object produced by `Route Telegram Event`; do not hardcode agent ids into the workflow JSON.

- [ ] **Step 6: Wire route outputs**

Wire `Route Switch` cases:

```text
register_user -> Register User -> Refresh User Context -> Reply in Telegram
set_state -> Set Dialog State -> Reply in Telegram
set_active_agent -> Set Dialog State -> Reply in Telegram
reset_to_menu -> Set Dialog State -> Reply in Telegram
reply -> Reply in Telegram
```

For callback routes, also wire a copy to `Answer Callback Query` when `answerCallback` is true. If the Switch node cannot fan out cleanly, place `Answer Callback Query` before the action branch and guard it with an IF node checking `isCallback = true`.

- [ ] **Step 7: Validate workflow**

Run:

```bash
jq empty n8n/workflows/telegram-elevenlabs-bot.json
```

Expected: PASS.

## Task 5: Implement ElevenLabs Agent Creation

**Files:**
- Modify: `n8n/workflows/telegram-elevenlabs-bot.json`

- [ ] **Step 1: Configure `Create ElevenLabs Agent` HTTP node**

Set method and URL:

```text
POST https://api.elevenlabs.io/v1/convai/agents/create
```

Use the ElevenLabs HTTP Header Auth credential. Set JSON body:

```json
{
  "name": "={{ $json.agentName }}",
  "conversation_config": {
    "agent": {
      "first_message": "={{ $json.settings.defaultWelcome }}",
      "language": "={{ $json.settings.defaultLanguage }}",
      "prompt": {
        "prompt": "={{ $json.settings.defaultPrompt }}",
        "llm": "={{ $json.settings.defaultLlm }}"
      }
    },
    "tts": {
      "voice_id": "={{ $json.settings.defaultVoiceId }}",
      "model_id": "={{ $json.settings.defaultTtsModelId }}"
    }
  }
}
```

- [ ] **Step 2: Configure `Save Created Agent` PostgreSQL node**

Configure this query. Bind parameters in order: `telegramUserId`, `agentName`, `agent_id` from ElevenLabs response, `defaultPrompt`, `defaultWelcome`.

```sql
WITH current_user AS (
  SELECT id
  FROM telegram_users
  WHERE telegram_user_id = $1
),
created_agent AS (
  INSERT INTO elevenlabs_agents (
    user_id,
    elevenlabs_agent_id,
    display_name,
    prompt_text,
    welcome_text,
    status,
    updated_at
  )
  SELECT
    current_user.id,
    $3,
    $2,
    $4,
    $5,
    'active',
    now()
  FROM current_user
  RETURNING id
)
UPDATE telegram_users
SET
  active_agent_id = (SELECT id FROM created_agent),
  dialog_state = 'idle',
  updated_at = now()
WHERE id = (SELECT id FROM current_user)
RETURNING active_agent_id;
```

- [ ] **Step 3: Add success reply shaping**

Add a Code node or extend the route item before `Reply in Telegram` so created-agent success replies use:

```javascript
return [
  {
    json: {
      ...$json,
      replyText: `Агент "${$json.agentName}" создан и выбран.`,
      replyMarkup: {
        inline_keyboard: [
          [{ text: 'Изменить prompt', callback_data: 'ag:p' }],
          [{ text: 'Изменить приветствие', callback_data: 'ag:w' }],
          [{ text: 'Обновить knowledge', callback_data: 'ag:k' }],
          [{ text: 'Список агентов', callback_data: 'ag:list' }],
        ],
      },
    },
  },
];
```

- [ ] **Step 4: Wire creation route**

Wire:

```text
Route Switch(create_agent) -> Create ElevenLabs Agent -> Save Created Agent -> Reply in Telegram
```

- [ ] **Step 5: Validate workflow**

Run:

```bash
jq empty n8n/workflows/telegram-elevenlabs-bot.json
./scripts/check-telegram-elevenlabs-workflow.sh
```

Expected: validation may still fail until all update nodes are present, but JSON must pass.

## Task 6: Implement Prompt and Welcome Updates

**Files:**
- Modify: `n8n/workflows/telegram-elevenlabs-bot.json`

- [ ] **Step 1: Configure `Get ElevenLabs Agent` HTTP node**

Set method and URL:

```text
GET ={{ "https://api.elevenlabs.io/v1/convai/agents/" + $json.active_agent.elevenlabs_agent_id }}
```

Use the ElevenLabs HTTP Header Auth credential.

- [ ] **Step 2: Configure `Build ElevenLabs Patch`**

Set its Code node JavaScript to the exact `Build ElevenLabs Patch` snippet in "Shared Snippets". Before this node, make sure the current agent response is available as `$json.elevenlabsAgent` and the original route item fields `route`, `newText`, and `active_agent` are still present. If the HTTP node overwrites the item JSON, add a Merge node in pass-through mode to combine the route item and HTTP response.

- [ ] **Step 3: Configure `Patch ElevenLabs Agent` HTTP node**

Set method and URL:

```text
PATCH ={{ "https://api.elevenlabs.io/v1/convai/agents/" + $json.active_agent.elevenlabs_agent_id }}
```

Use JSON body:

```text
={{ $json.elevenlabsPatchBody }}
```

Use the ElevenLabs HTTP Header Auth credential.

- [ ] **Step 4: Configure `Save Agent Update` PostgreSQL node**

Configure this query. Bind parameters in order: `telegramUserId`, `active_agent.id`, `route`, `newText`, `newKnowledgeDocumentId`.

```sql
WITH current_user AS (
  SELECT id
  FROM telegram_users
  WHERE telegram_user_id = $1
),
updated_agent AS (
  UPDATE elevenlabs_agents
  SET
    prompt_text = CASE WHEN $3 = 'update_prompt' THEN $4 ELSE prompt_text END,
    welcome_text = CASE WHEN $3 = 'update_welcome' THEN $4 ELSE welcome_text END,
    knowledge_document_id = CASE WHEN $3 = 'update_knowledge' THEN $5 ELSE knowledge_document_id END,
    updated_at = now()
  WHERE id = $2
    AND user_id = (SELECT id FROM current_user)
  RETURNING id, display_name
)
UPDATE telegram_users
SET dialog_state = 'idle', updated_at = now()
WHERE id = (SELECT id FROM current_user)
  AND EXISTS (SELECT 1 FROM updated_agent)
RETURNING (SELECT display_name FROM updated_agent) AS display_name;
```

- [ ] **Step 5: Add success reply shaping for prompt/welcome**

Before `Reply in Telegram`, set:

```javascript
const label = $json.route === 'update_prompt' ? 'Prompt' : 'Приветствие';
return [{ json: { ...$json, replyText: `${label} обновлено.`, replyMarkup: null } }];
```

- [ ] **Step 6: Wire prompt and welcome routes**

Wire both routes:

```text
Route Switch(update_prompt) -> Get ElevenLabs Agent -> Build ElevenLabs Patch -> Patch ElevenLabs Agent -> Save Agent Update -> Reply in Telegram
Route Switch(update_welcome) -> Get ElevenLabs Agent -> Build ElevenLabs Patch -> Patch ElevenLabs Agent -> Save Agent Update -> Reply in Telegram
```

- [ ] **Step 7: Validate workflow JSON**

Run:

```bash
jq empty n8n/workflows/telegram-elevenlabs-bot.json
```

Expected: PASS.

## Task 7: Implement Text Knowledge Replacement

**Files:**
- Modify: `n8n/workflows/telegram-elevenlabs-bot.json`

- [ ] **Step 1: Configure `Create Knowledge Document` HTTP node**

Set method and URL:

```text
POST https://api.elevenlabs.io/v1/convai/knowledge-base/text
```

Use JSON body:

```json
{
  "text": "={{ $json.newText }}",
  "name": "={{ 'Telegram knowledge ' + $json.active_agent.display_name + ' ' + new Date().toISOString() }}"
}
```

Use the ElevenLabs HTTP Header Auth credential.

- [ ] **Step 2: Preserve new knowledge document fields**

After `Create Knowledge Document`, add a Code node or Set fields:

```javascript
return [
  {
    json: {
      ...$json,
      oldKnowledgeDocumentId: $json.active_agent.knowledge_document_id ?? '',
      newKnowledgeDocumentId: $json.id,
      newKnowledgeDocumentName: $json.name,
    },
  },
];
```

If the HTTP node overwrites the route item, use a Merge node so `active_agent`, `route`, `newText`, and settings remain available.

- [ ] **Step 3: Wire knowledge patch**

Wire:

```text
Route Switch(update_knowledge) -> Create Knowledge Document -> Get ElevenLabs Agent -> Build ElevenLabs Patch -> Patch ElevenLabs Agent -> Save Agent Update -> Delete Old Knowledge Document -> Reply in Telegram
```

- [ ] **Step 4: Configure `Delete Old Knowledge Document` HTTP node**

Set it to execute only if `oldKnowledgeDocumentId` is not empty.

Set method and URL:

```text
DELETE ={{ "https://api.elevenlabs.io/v1/convai/knowledge-base/" + $json.oldKnowledgeDocumentId + "?force=true" }}
```

Use the ElevenLabs HTTP Header Auth credential and enable continue-on-fail for this node.

- [ ] **Step 5: Log cleanup failure**

Wire failed output or continue-on-fail result from `Delete Old Knowledge Document` to `Log Bot Event` with this query. Bind parameters in order: `telegramUserId`, `active_agent.id`, `errorMessage`, JSON metadata.

```sql
WITH current_user AS (
  SELECT id
  FROM telegram_users
  WHERE telegram_user_id = $1
)
INSERT INTO bot_events (
  user_id,
  agent_id,
  event_type,
  status,
  error_message,
  metadata
)
VALUES (
  (SELECT id FROM current_user),
  $2,
  'delete_old_knowledge_document',
  'error',
  $3,
  $4::jsonb
);
```

Use metadata:

```json
{
  "oldKnowledgeDocumentId": "={{ $json.oldKnowledgeDocumentId }}",
  "newKnowledgeDocumentId": "={{ $json.newKnowledgeDocumentId }}"
}
```

- [ ] **Step 6: Add knowledge success reply shaping**

Before `Reply in Telegram`, set:

```javascript
return [{ json: { ...$json, replyText: 'Knowledge обновлён.', replyMarkup: null } }];
```

- [ ] **Step 7: Validate workflow**

Run:

```bash
jq empty n8n/workflows/telegram-elevenlabs-bot.json
./scripts/check-telegram-elevenlabs-workflow.sh
```

Expected: PASS.

## Task 8: Add Error Logging and User-Safe Failures

**Files:**
- Modify: `n8n/workflows/telegram-elevenlabs-bot.json`

- [ ] **Step 1: Configure `Log Bot Event` for system errors**

Use this query for system failure branches. Bind parameters in order: `telegramUserId`, `active_agent.id`, `eventType`, `errorMessage`, `metadata`.

```sql
WITH current_user AS (
  SELECT id
  FROM telegram_users
  WHERE telegram_user_id = $1
)
INSERT INTO bot_events (
  user_id,
  agent_id,
  event_type,
  status,
  error_message,
  metadata
)
VALUES (
  (SELECT id FROM current_user),
  $2,
  $3,
  'error',
  $4,
  $5::jsonb
);
```

- [ ] **Step 2: Add failure reply shaping**

For HTTP and PostgreSQL failure branches that can continue, shape the reply:

```javascript
return [
  {
    json: {
      ...$json,
      replyText: 'Не получилось выполнить действие. Попробуйте позже.',
      replyMarkup: null,
    },
  },
];
```

- [ ] **Step 3: Wire system failures**

Wire ElevenLabs HTTP failures and PostgreSQL save failures:

```text
failed action -> Log Bot Event -> Reply in Telegram
```

Use event types:

```text
create_agent_failed
patch_agent_failed
create_knowledge_document_failed
save_agent_update_failed
```

- [ ] **Step 4: Validate workflow**

Run:

```bash
jq empty n8n/workflows/telegram-elevenlabs-bot.json
./scripts/check-telegram-elevenlabs-workflow.sh
```

Expected: PASS.

## Task 9: Final Verification and Import Documentation

**Files:**
- Modify: `n8n/README.md`
- Modify: `n8n/workflows/telegram-elevenlabs-bot.json`

- [ ] **Step 1: Run static validation**

Run:

```bash
jq empty n8n/workflows/telegram-elevenlabs-bot.json
make check-telegram-elevenlabs-workflow
```

Expected: both commands pass.

- [ ] **Step 2: Verify no secrets were committed**

Run:

```bash
! rg -n "xi-api-key|sk_|telegram.*token|bot[0-9]+:" n8n/workflows/telegram-elevenlabs-bot.json
rg -n "BOT_ACCESS_PASSWORD=example-access-password-change-me" n8n/.env.example
! rg -n "BOT_ACCESS_PASSWORD=.*send-this-password-to-test-users" n8n/workflows/telegram-elevenlabs-bot.json
```

Expected: the first and third commands exit with status 0 because `rg` finds nothing and `!` inverts the result. The second command exits with status 0 because the example env file documents only the safe example access password.

- [ ] **Step 3: Validate workflow import command path**

Run:

```bash
./scripts/import-n8n-workflows.sh --help
```

Expected: help output includes workflow import usage and exits with status 0.

- [ ] **Step 4: Add README smoke test section**

Add this section to `n8n/README.md` after the credentials instructions:

```markdown
## Telegram ElevenLabs bot smoke test

After credentials are attached and the workflow is active:

1. Send `/start` from a Telegram account that is not in the bot database.
2. Confirm the bot asks for the access password.
3. Send a wrong password and confirm no user row is created.
4. Send the correct `BOT_ACCESS_PASSWORD` and confirm the menu appears.
5. Send `/agents` and create a new agent by name.
6. Select the created agent.
7. Update prompt, welcome message, and knowledge text.
8. Send a non-text message while the bot waits for knowledge text and confirm it asks for text again.
9. Try to exceed `MAX_AGENTS_PER_USER` and confirm creation is blocked.
```

- [ ] **Step 5: Commit implementation**

```bash
git add Makefile scripts/check-telegram-elevenlabs-workflow.sh n8n/docker-compose.yml n8n/.env.example n8n/README.md n8n/workflows/telegram-elevenlabs-bot.json
git commit -m "feat: add telegram elevenlabs bot workflow"
```

## Execution Notes

- Keep the workflow inactive in committed JSON. Activation belongs to the target n8n instance after credentials are attached.
- Do not commit real `BOT_ACCESS_PASSWORD`, Telegram bot token, or ElevenLabs API key.
- If n8n changes exported parameter shapes for Telegram inline keyboards, prefer the n8n UI's current native fields over raw Telegram Bot API calls, then export the workflow and rerun the validation script.
- If any node cannot preserve original route fields after an HTTP or PostgreSQL call, insert a Merge node and keep the route item as the authoritative context.
