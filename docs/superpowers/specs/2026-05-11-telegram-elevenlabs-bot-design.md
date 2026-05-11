# Telegram ElevenLabs bot design

## Цель

Расширить существующий n8n workflow `Telegram ElevenLabs Bot`, чтобы Telegram-пользователи могли создавать и настраивать несколько ElevenLabs agents через бота.

Workflow должен:

- хранить Telegram-пользователей и привязанные к ним ElevenLabs agents в отдельной PostgreSQL БД;
- разрешать пользователю работать только со своими agents;
- пускать новых Telegram-пользователей только после ввода общего access password;
- создавать нового ElevenLabs agent по явной кнопке в `/agents`;
- обновлять prompt, welcome message и text-only knowledge content выбранного agent;
- отклонять не-текстовые сообщения в режимах редактирования;
- не хранить секреты в workflow JSON.

Текущий workflow минимален: `Telegram Trigger -> Prepare Telegram Reply -> Reply in Telegram`. Новый дизайн оставляет один основной workflow, но превращает его в явный router с состояниями пользователя. Да, JSON станет крупнее. Зато не будет россыпи меж-workflow вызовов, где смысл тонет быстрее, чем надежда на пятничный деплой.

## Выбранный Подход

Использовать один расширенный n8n workflow.

Входная точка остается одна: Telegram Trigger принимает `message` и `callback_query`. Дальше workflow нормализует вход, создает таблицы при необходимости, upsert'ит пользователя, читает состояние диалога и маршрутизирует событие.

Альтернативы были отклонены:

- несколько workflow для отдельных действий: чище по модульности, но сложнее импорт, связность и отладка;
- отдельный backend API рядом с n8n: архитектурно взрослее, но для этой версии слишком много инфраструктуры вокруг одного Telegram-интерфейса.

## База Данных

Бизнес-данные бота живут не в служебной БД n8n, а в отдельной app database. БД и пользователь создаются один раз существующим infra-скриптом:

```bash
./scripts/create-postgres-app-db.sh telegram-elevenlabs-bot prod
```

n8n подключается к этой БД через отдельные PostgreSQL credentials. Workflow создает только таблицы и индексы внутри своей БД через idempotent bootstrap step. Полноценные будущие миграции лучше выносить в SQL-файлы, потому что n8n как мигратор БД - это уже не automation, а легкая форма наказания.

### Таблицы

`telegram_users`

- `id bigserial primary key`
- `telegram_user_id bigint not null unique`
- `chat_id bigint not null`
- `username text`
- `first_name text`
- `last_name text`
- `active_agent_id bigint`
- `dialog_state text not null default 'idle'`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`

Разрешенные состояния:

- `idle`
- `awaiting_agent_name`
- `awaiting_prompt`
- `awaiting_welcome`
- `awaiting_knowledge`

`elevenlabs_agents`

- `id bigserial primary key`
- `user_id bigint not null references telegram_users(id) on delete cascade`
- `elevenlabs_agent_id text not null unique`
- `display_name text not null`
- `knowledge_document_id text`
- `prompt_text text`
- `welcome_text text`
- `status text not null default 'active'`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`

`bot_events`

- `id bigserial primary key`
- `user_id bigint references telegram_users(id) on delete set null`
- `agent_id bigint references elevenlabs_agents(id) on delete set null`
- `event_type text not null`
- `status text not null`
- `error_message text`
- `metadata jsonb not null default '{}'::jsonb`
- `created_at timestamptz not null default now()`

Индексы:

- `telegram_users(telegram_user_id)`
- `elevenlabs_agents(user_id)`
- `elevenlabs_agents(elevenlabs_agent_id)`
- `bot_events(user_id, created_at desc)`
- `bot_events(agent_id, created_at desc)`

`active_agent_id` хранится как удобное состояние интерфейса. Любое действие с agent обязано делать lookup через `elevenlabs_agents.id = active_agent_id and elevenlabs_agents.user_id = telegram_users.id`. Никакого доверия callback data: кнопка в Telegram не является нотариусом.

## Настройки

Настройки первой версии хранятся в n8n workflow/env, не в БД:

- `BOT_ACCESS_PASSWORD`
- `MAX_AGENTS_PER_USER`, default `3`
- `DEFAULT_AGENT_PROMPT`
- `DEFAULT_AGENT_WELCOME`
- `DEFAULT_AGENT_LANGUAGE`
- `DEFAULT_AGENT_VOICE_ID`
- `DEFAULT_AGENT_TTS_MODEL_ID`
- `DEFAULT_AGENT_LLM`

`BOT_ACCESS_PASSWORD` задается в untracked runtime-настройке n8n, например через `n8n/.env` или n8n environment variable. В workflow export и git пароль не попадает. Это все еще простой общий пароль, но без жанра "секрет лежит в репозитории и машет рукой".

Если `BOT_ACCESS_PASSWORD` пустой или не задан, workflow должен fail closed для новых пользователей: не регистрировать их и отвечать, что доступ временно не настроен.

ElevenLabs API key хранится в n8n credential для HTTP Request nodes, например header credential с `xi-api-key`. Секрет не попадает в git и не попадает в workflow export.

## Telegram Flow

### Access Gate

Access gate выполняется до любых business actions.

Если `telegram_user_id` уже есть в `telegram_users`, workflow продолжает обычный маршрут.

Если пользователя нет в БД:

1. workflow проверяет, что `BOT_ACCESS_PASSWORD` задан;
2. если входящее сообщение является текстом и `trim(message_text) = BOT_ACCESS_PASSWORD`, workflow создает пользователя, ставит `dialog_state = 'idle'` и показывает стартовое меню;
3. если пароль неверный или сообщение не текстовое, workflow не создает пользователя и просит отправить пароль доступа текстом;
4. callback query от неизвестного пользователя не обрабатывается как действие, а получает просьбу сначала пройти пароль.

Пароль спрашивается только до первой успешной регистрации. Если нужно отозвать доступ, запись пользователя удаляется из `telegram_users` вручную или будущей админской операцией. Автоматическую ротацию и персональные пароли в v1 не делаем.

### `/start`

Workflow:

1. нормализует вход;
2. создает таблицы, если их еще нет;
3. применяет access gate для неизвестного пользователя;
4. для уже допущенного пользователя upsert'ит Telegram profile fields по `telegram_user_id`;
5. сбрасывает `dialog_state` в `idle`;
6. отправляет короткое меню: `/agents`, доступные действия, текущий лимит agents.

### `/agents`

Workflow выбирает agents текущего пользователя и отправляет inline keyboard:

- кнопка выбора для каждого agent;
- кнопка `Создать агента`, если лимит не исчерпан.

Callback data должны быть короткими, чтобы не упереться в лимит Telegram:

- `ag:sel:<local_agent_id>`
- `ag:new`
- `ag:p`
- `ag:w`
- `ag:k`

После выбора agent workflow сохраняет `active_agent_id` и показывает действия:

- изменить prompt;
- изменить приветствие;
- обновить knowledge.

### Создание Agent

По `ag:new` workflow:

1. проверяет количество active agents пользователя;
2. если лимит исчерпан, отвечает отказом;
3. если лимит доступен, ставит `dialog_state = 'awaiting_agent_name'`;
4. просит отправить имя agent текстом.

Следующее текстовое сообщение:

1. валидируется как непустое имя;
2. вызывает ElevenLabs `POST /v1/convai/agents/create`;
3. передает `name` и default conversation config;
4. сохраняет `elevenlabs_agent_id` в `elevenlabs_agents`;
5. делает новый agent активным;
6. возвращает пользователя в `idle`;
7. отправляет карточку действий для созданного agent.

Если вместо текста пришел файл, фото, voice или другое не-текстовое сообщение, workflow отвечает ошибкой и оставляет состояние `awaiting_agent_name`.

## ElevenLabs Agent Updates

Перед любым обновлением workflow получает active agent только через join с текущим пользователем. Если active agent отсутствует или не принадлежит пользователю, бот отвечает просьбой выбрать agent через `/agents`.

Для agent config updates workflow использует безопасный порядок:

1. `GET /v1/convai/agents/:agent_id`;
2. merge нужного поля в текущую `conversation_config`;
3. `PATCH /v1/convai/agents/:agent_id`;
4. update local cache в БД;
5. сброс `dialog_state` в `idle`.

GET-merge-PATCH выбран намеренно, чтобы не снести соседние nested настройки partial payload'ом. У внешних API иногда богатая внутренняя жизнь, и лучше не узнавать о ней через потерянный voice config.

### Prompt

`ag:p` ставит `dialog_state = 'awaiting_prompt'`.

Следующее текстовое сообщение обновляет:

- `conversation_config.agent.prompt.prompt`
- `elevenlabs_agents.prompt_text`

### Welcome Message

`ag:w` ставит `dialog_state = 'awaiting_welcome'`.

Следующее текстовое сообщение обновляет:

- `conversation_config.agent.first_message`
- `elevenlabs_agents.welcome_text`

### Knowledge

`ag:k` ставит `dialog_state = 'awaiting_knowledge'`.

Knowledge в первой версии принимает только текст. Не-текстовые сообщения получают понятную ошибку, состояние остается `awaiting_knowledge`.

Text knowledge replacement:

1. создать новый text knowledge document через `POST /v1/convai/knowledge-base/text`;
2. получить текущий agent config через `GET /v1/convai/agents/:agent_id`;
3. заменить knowledge list в `conversation_config.agent.prompt.knowledge_base` на один новый text document;
4. применить config через `PATCH /v1/convai/agents/:agent_id`;
5. обновить `elevenlabs_agents.knowledge_document_id`;
6. сбросить `dialog_state` в `idle`;
7. удалить старый document через `DELETE /v1/convai/knowledge-base/:documentation_id?force=true`, если он был.

Если удаление старого document не удалось, пользовательское действие считается успешным, но ошибка пишется в `bot_events`. Новый document уже привязан, старый document уже не должен блокировать основной сценарий.

## Ошибки И События

Пользовательские ошибки:

- новый пользователь не ввел access password;
- access password неверный;
- лимит agents исчерпан;
- нет active agent;
- пустой текст;
- не-текстовое сообщение в режиме ожидания текста;
- callback с agent, который не принадлежит пользователю.

На такие ошибки бот отвечает понятным текстом и не делает внешний ElevenLabs update.

Системные ошибки:

- ElevenLabs 4xx/5xx;
- PostgreSQL недоступен;
- Telegram reply не отправился;
- старый knowledge document не удалился.

Системные ошибки пишутся в `bot_events` с `status = 'error'`, `event_type`, `agent_id` где применимо, и кратким `error_message`. Пользователю возвращается нейтральное сообщение без API details и секретов.

## Credentials И Документация

README для n8n должен описать обязательные credentials:

- Telegram credential для trigger и send message;
- PostgreSQL credential для bot business database;
- HTTP credential для ElevenLabs с header `xi-api-key`.

Также README должен описать создание bot database через `create-postgres-app-db.sh`, `BOT_ACCESS_PASSWORD`, лимит agents и default agent settings. Документация должна явно сказать: access password не коммитится в workflow JSON.

## Проверка

До импорта workflow:

- `jq` подтверждает валидность `n8n/workflows/telegram-elevenlabs-bot.json`;
- workflow содержит Telegram trigger для `message` и `callback_query`;
- workflow содержит PostgreSQL bootstrap/upsert/select/update nodes;
- workflow содержит HTTP nodes для ElevenLabs create/get/patch/create knowledge/delete knowledge;
- workflow не содержит ElevenLabs API key или Telegram token.

Ручной smoke test после настройки credentials:

1. неизвестный пользователь получает запрос access password;
2. неверный access password не создает пользователя в БД;
3. верный access password создает пользователя и показывает меню;
4. `/start` для существующего пользователя показывает меню без повторного пароля;
5. `/agents` показывает пустой список и кнопку создания;
6. создание agent спрашивает имя и создает ElevenLabs agent;
7. выбор agent показывает действия;
8. prompt update меняет prompt только выбранного agent;
9. welcome update меняет first message только выбранного agent;
10. knowledge update принимает текст и заменяет previous knowledge document;
11. не-текстовое сообщение в режиме knowledge получает ошибку и не сбрасывает состояние;
12. пользователь не может изменить agent, который ему не принадлежит;
13. лимит `MAX_AGENTS_PER_USER` блокирует создание сверх лимита.

## Out Of Scope

В первой версии не делаем:

- allowlist администраторов;
- персональные пароли пользователей;
- автоматическую ротацию access password;
- user-facing удаление agents;
- переименование agents;
- загрузку файлов, URL или PDF в knowledge;
- историю knowledge documents;
- отдельный backend API;
- полноценный миграционный механизм для будущих изменений схемы;
- админку для default settings.

## Источники

Официальные ElevenLabs docs, проверено 2026-05-11:

- Create agent: https://elevenlabs.io/docs/eleven-agents/api-reference/agents/create
- Get agent: https://elevenlabs.io/docs/eleven-agents/api-reference/agents/get
- Update agent: https://elevenlabs.io/docs/api-reference/agents/update
- Create text knowledge document: https://elevenlabs.io/docs/eleven-agents/api-reference/knowledge-base/create-from-text
- Delete knowledge document: https://elevenlabs.io/docs/eleven-agents/api-reference/knowledge-base/delete
