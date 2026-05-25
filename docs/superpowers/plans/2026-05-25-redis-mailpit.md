# Redis and Mailpit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Redis with Redis Insight UI and Mailpit with web UI to the existing single-VDS Docker Compose infra.

**Architecture:** Add two independent top-level stacks, `redis/` and `mailpit/`. Redis and Mailpit SMTP stay internal on the shared `data` network, while Redis Insight and Mailpit web UI are exposed through the shared Traefik `proxy` network with Basic Auth.

**Tech Stack:** Docker Compose, Traefik, Redis official Docker image, Redis Insight, Mailpit, Bash helper scripts, Markdown runbooks.

---

## Source References

- Existing design spec: `docs/superpowers/specs/2026-05-25-redis-mailpit-design.md`
- Redis Docker official image tags and security notes: `https://hub.docker.com/_/redis`
- Redis Docker persistence and password guidance: `https://redis.io/tutorials/operate/orchestration/docker/`
- Redis Insight Docker install, `/data` volume, port `5540`, and `/api/health/`: `https://redis.io/docs/latest/operate/redisinsight/install/install-on-docker/`
- Redis Insight configuration environment variables and preconfigured database connection: `https://redis.io/docs/latest/operate/redisinsight/configuration/`
- Redis Insight Docker tags: `https://hub.docker.com/r/redis/redisinsight/tags`
- Mailpit Docker image, ports `8025` and `1025`, and `MP_DATABASE`: `https://mailpit.axllent.org/docs/install/docker/`
- Mailpit persistent SQLite storage and `MP_MAX_MESSAGES`: `https://mailpit.axllent.org/docs/configuration/email-storage/`
- Mailpit health endpoints `/livez` and `/readyz`: `https://mailpit.axllent.org/docs/integration/healthcheck/`
- Mailpit Docker tags: `https://hub.docker.com/r/axllent/mailpit/tags`

## File Structure

- Create `redis/docker-compose.yml`: Redis server, Redis Insight UI, volumes, healthchecks, internal data networking, and Traefik labels for UI.
- Create `redis/.env.example`: version pins, network names, Redis password, Redis Insight encryption key, public UI host, and Basic Auth example hash.
- Create `redis/README.md`: setup, startup, UI, internal connection strings, operations, and backups.
- Create `mailpit/docker-compose.yml`: Mailpit SMTP capture service with persistent SQLite database, healthcheck, internal SMTP networking, and Traefik labels for UI.
- Create `mailpit/.env.example`: version pin, network names, public UI host, message retention, and Basic Auth example hash.
- Create `mailpit/README.md`: setup, startup, UI, SMTP endpoint, operations, and backups.
- Modify `Makefile`: add `up-redis` and `up-mailpit`.
- Modify `scripts/lib.sh`: recognize `redis` and `mailpit` as infra stacks.
- Modify `scripts/logs.sh`, `scripts/restart.sh`, `scripts/healthcheck.sh`, and `scripts/backup-volumes.sh`: include both stacks in usage text.
- Modify `scripts/init-server.sh`: include both stacks in startup hints.
- Modify `README.md`: document the new services, env setup, startup commands, compose conventions, and command list.
- Modify `docs/backup-restore.md`: include Redis and Mailpit volumes and backup commands.

## Current Workspace Note

Before staging each task, run `git status --short`. Stage only files listed in that task. Existing unrelated deletions such as `deployments/danilka-tech-prod/*`, `docs/danilka-tech.md`, or `env/prod/danilka-tech.env.example` must not be restored, staged, or committed unless the user explicitly requests that.

## Task 1: Add Redis Stack

**Files:**
- Create: `redis/docker-compose.yml`
- Create: `redis/.env.example`
- Create: `redis/README.md`

- [ ] **Step 1: Write the failing stack existence check**

Run:

```bash
test -f redis/docker-compose.yml
```

Expected: FAIL with exit code `1` because the Redis stack does not exist yet.

- [ ] **Step 2: Create the stack directory**

Run:

```bash
mkdir -p redis
```

Expected: command exits with status `0`.

- [ ] **Step 3: Create `redis/docker-compose.yml`**

Write this exact file:

```yaml
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"

services:
  redis:
    image: redis:${REDIS_VERSION}
    container_name: infra-redis
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      REDIS_PASSWORD: ${REDIS_PASSWORD}
      REDIS_ARGS: --appendonly yes --requirepass ${REDIS_PASSWORD}
    security_opt:
      - no-new-privileges:true
    volumes:
      - redis-data:/data
    networks:
      data:
        aliases:
          - infra-redis
          - redis
    healthcheck:
      test: ["CMD-SHELL", "REDISCLI_AUTH=\"$${REDIS_PASSWORD}\" redis-cli ping | grep PONG"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 10s
    logging: *default-logging

  redis-ui:
    image: redis/redisinsight:${REDIS_UI_VERSION}
    container_name: infra-redis-ui
    restart: unless-stopped
    depends_on:
      redis:
        condition: service_healthy
    environment:
      TZ: ${TZ}
      RI_APP_PORT: 5540
      RI_ENCRYPTION_KEY: ${REDIS_UI_ENCRYPTION_KEY}
      RI_REDIS_HOST: infra-redis
      RI_REDIS_PORT: 6379
      RI_REDIS_ALIAS: Infra Redis
      RI_REDIS_USERNAME: default
      RI_REDIS_PASSWORD: ${REDIS_PASSWORD}
      RI_REDIS_DB: 0
    security_opt:
      - no-new-privileges:true
    volumes:
      - redis-ui-data:/data
    networks:
      - data
      - proxy
    labels:
      - traefik.enable=true
      - traefik.docker.network=${PROXY_NETWORK}
      - traefik.http.routers.redis-ui.rule=Host(`${REDIS_UI_HOST}`)
      - traefik.http.routers.redis-ui.entrypoints=websecure
      - traefik.http.routers.redis-ui.tls=true
      - traefik.http.routers.redis-ui.tls.certresolver=letsencrypt
      - traefik.http.routers.redis-ui.middlewares=default-chain@file,redis-ui-auth@docker
      - traefik.http.services.redis-ui.loadbalancer.server.port=5540
      - traefik.http.middlewares.redis-ui-auth.basicauth.users=${REDIS_UI_BASIC_AUTH_USERS}
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://127.0.0.1:5540/api/health/ || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
    logging: *default-logging

volumes:
  redis-data:
    name: redis-data
  redis-ui-data:
    name: redis-ui-data

networks:
  data:
    external: true
    name: ${DATA_NETWORK}
  proxy:
    external: true
    name: ${PROXY_NETWORK}
```

- [ ] **Step 4: Create `redis/.env.example`**

Write this exact file:

```dotenv
COMPOSE_PROJECT_NAME=redis

TZ=UTC
DATA_NETWORK=data
PROXY_NETWORK=proxy

REDIS_VERSION=8.6.3-alpine
REDIS_PASSWORD=change-me

REDIS_UI_VERSION=3.4.2
REDIS_UI_HOST=redis.example.com
REDIS_UI_ENCRYPTION_KEY=change-me-long-random-string
# Example hash for password "change-me-now". Replace before production usage.
REDIS_UI_BASIC_AUTH_USERS=admin:$$apr1$$B0n9m8eP$$yVZqzjYw2GvUf1Stj6G2j0
```

- [ ] **Step 5: Create `redis/README.md`**

Write this exact file:

````markdown
# Redis

`redis/` runs a single Redis server and Redis Insight behind the shared Traefik gateway.

The Redis server is internal only. It joins the external `data` network and exposes no host ports. Redis Insight joins `data` and `proxy`; Traefik exposes only the UI at `https://<REDIS_UI_HOST>/` with Basic Auth.

## Setup

Copy the env example:

```bash
cp redis/.env.example redis/.env
chmod 600 redis/.env
```

Set production values in `redis/.env`:

- `REDIS_PASSWORD`
- `REDIS_UI_HOST`
- `REDIS_UI_ENCRYPTION_KEY`
- `REDIS_UI_BASIC_AUTH_USERS`
- `TZ`

Generate Basic Auth with:

```bash
docker run --rm --entrypoint htpasswd httpd:2 -Bbn admin 'strong-password'
```

Generate `REDIS_UI_ENCRYPTION_KEY` with:

```bash
openssl rand -hex 32
```

## Start

```bash
make up-gateway
make up-redis
```

Open `https://<REDIS_UI_HOST>/`.

Redis Insight is preconfigured to connect to `infra-redis:6379` with the `default` user and `REDIS_PASSWORD`.

## Internal Connections

Containers on the `data` network can use:

```text
redis://:<REDIS_PASSWORD>@infra-redis:6379/0
```

For clients that split connection settings:

- Host: `infra-redis`
- Port: `6379`
- Username: `default`
- Password: value of `REDIS_PASSWORD`
- Database: `0`

## Operations

```bash
./scripts/healthcheck.sh redis
./scripts/logs.sh redis
./scripts/restart.sh redis
```

## Smoke Test

```bash
docker exec -it infra-redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping'
```

Expected output:

```text
PONG
```

## Backup

```bash
./scripts/backup-volumes.sh --stack redis
```

The backup includes `redis-data` and `redis-ui-data`.
````

- [ ] **Step 6: Validate Redis compose config**

Run:

```bash
docker compose --env-file redis/.env.example -f redis/docker-compose.yml config >/tmp/redis-compose-config.yml
```

Expected: PASS with exit code `0`.

Run:

```bash
rg -n "infra-redis|infra-redis-ui|redis-data|redis-ui-data|redis.example.com" /tmp/redis-compose-config.yml
```

Expected: PASS and prints matching lines.

- [ ] **Step 7: Commit Redis stack**

Run:

```bash
git status --short
git add redis/docker-compose.yml redis/.env.example redis/README.md
git diff --cached --check
git commit -m "feat: add redis infra stack"
```

Expected: commit succeeds and includes only the three Redis files.

## Task 2: Add Mailpit Stack

**Files:**
- Create: `mailpit/docker-compose.yml`
- Create: `mailpit/.env.example`
- Create: `mailpit/README.md`

- [ ] **Step 1: Write the failing stack existence check**

Run:

```bash
test -f mailpit/docker-compose.yml
```

Expected: FAIL with exit code `1` because the Mailpit stack does not exist yet.

- [ ] **Step 2: Create the stack directory**

Run:

```bash
mkdir -p mailpit
```

Expected: command exits with status `0`.

- [ ] **Step 3: Create `mailpit/docker-compose.yml`**

Write this exact file:

```yaml
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"

services:
  mailpit:
    image: axllent/mailpit:${MAILPIT_VERSION}
    container_name: infra-mailpit
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      MP_DATABASE: /data/mailpit.db
      MP_MAX_MESSAGES: ${MAILPIT_MAX_MESSAGES}
      MP_DISABLE_VERSION_CHECK: "true"
    security_opt:
      - no-new-privileges:true
    volumes:
      - mailpit-data:/data
    networks:
      data:
        aliases:
          - infra-mailpit
          - mailpit
      proxy:
    labels:
      - traefik.enable=true
      - traefik.docker.network=${PROXY_NETWORK}
      - traefik.http.routers.mailpit.rule=Host(`${MAILPIT_HOST}`)
      - traefik.http.routers.mailpit.entrypoints=websecure
      - traefik.http.routers.mailpit.tls=true
      - traefik.http.routers.mailpit.tls.certresolver=letsencrypt
      - traefik.http.routers.mailpit.middlewares=default-chain@file,mailpit-auth@docker
      - traefik.http.services.mailpit.loadbalancer.server.port=8025
      - traefik.http.middlewares.mailpit-auth.basicauth.users=${MAILPIT_UI_BASIC_AUTH_USERS}
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://127.0.0.1:8025/readyz || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 10s
    logging: *default-logging

volumes:
  mailpit-data:
    name: mailpit-data

networks:
  data:
    external: true
    name: ${DATA_NETWORK}
  proxy:
    external: true
    name: ${PROXY_NETWORK}
```

- [ ] **Step 4: Create `mailpit/.env.example`**

Write this exact file:

```dotenv
COMPOSE_PROJECT_NAME=mailpit

TZ=UTC
DATA_NETWORK=data
PROXY_NETWORK=proxy

MAILPIT_VERSION=v1.30.0
MAILPIT_HOST=mailpit.example.com
MAILPIT_MAX_MESSAGES=5000
# Example hash for password "change-me-now". Replace before production usage.
MAILPIT_UI_BASIC_AUTH_USERS=admin:$$apr1$$B0n9m8eP$$yVZqzjYw2GvUf1Stj6G2j0
```

- [ ] **Step 5: Create `mailpit/README.md`**

Write this exact file:

````markdown
# Mailpit

`mailpit/` runs Mailpit for SMTP capture with its web UI behind the shared Traefik gateway.

Mailpit SMTP is internal only. It joins the external `data` network and exposes no host ports. The web UI joins `proxy`; Traefik exposes only the UI at `https://<MAILPIT_HOST>/` with Basic Auth.

## Setup

Copy the env example:

```bash
cp mailpit/.env.example mailpit/.env
chmod 600 mailpit/.env
```

Set production values in `mailpit/.env`:

- `MAILPIT_HOST`
- `MAILPIT_MAX_MESSAGES`
- `MAILPIT_UI_BASIC_AUTH_USERS`
- `TZ`

Generate Basic Auth with:

```bash
docker run --rm --entrypoint htpasswd httpd:2 -Bbn admin 'strong-password'
```

## Start

```bash
make up-gateway
make up-mailpit
```

Open `https://<MAILPIT_HOST>/`.

## Internal SMTP

Containers on the `data` network can send test email to:

```text
infra-mailpit:1025
```

Typical application settings:

- SMTP host: `infra-mailpit`
- SMTP port: `1025`
- SMTP auth: disabled
- SMTP TLS: disabled

Mailpit stores messages in `mailpit-data` through `MP_DATABASE=/data/mailpit.db` and keeps up to `MAILPIT_MAX_MESSAGES` messages.

## Operations

```bash
./scripts/healthcheck.sh mailpit
./scripts/logs.sh mailpit
./scripts/restart.sh mailpit
```

## Smoke Test

From another container attached to the `data` network, send SMTP to:

```text
infra-mailpit:1025
```

Then open `https://<MAILPIT_HOST>/` and confirm the message appears.

## Backup

```bash
./scripts/backup-volumes.sh --stack mailpit
```

The backup includes `mailpit-data`.
````

- [ ] **Step 6: Validate Mailpit compose config**

Run:

```bash
docker compose --env-file mailpit/.env.example -f mailpit/docker-compose.yml config >/tmp/mailpit-compose-config.yml
```

Expected: PASS with exit code `0`.

Run:

```bash
rg -n "infra-mailpit|mailpit-data|mailpit.example.com|MP_DATABASE|MP_MAX_MESSAGES" /tmp/mailpit-compose-config.yml
```

Expected: PASS and prints matching lines.

- [ ] **Step 7: Commit Mailpit stack**

Run:

```bash
git status --short
git add mailpit/docker-compose.yml mailpit/.env.example mailpit/README.md
git diff --cached --check
git commit -m "feat: add mailpit infra stack"
```

Expected: commit succeeds and includes only the three Mailpit files.

## Task 3: Wire Commands and Shared Scripts

**Files:**
- Modify: `Makefile`
- Modify: `scripts/lib.sh`
- Modify: `scripts/logs.sh`
- Modify: `scripts/restart.sh`
- Modify: `scripts/healthcheck.sh`
- Modify: `scripts/backup-volumes.sh`
- Modify: `scripts/init-server.sh`

- [ ] **Step 1: Write the failing Makefile target check**

Run:

```bash
make help | rg "up-redis|up-mailpit"
```

Expected: FAIL because neither target is listed yet.

- [ ] **Step 2: Update `Makefile` phony targets**

Replace the existing `.PHONY` line with:

```make
.PHONY: help up-gateway up-postgres up-registry up-observability up-admin up-uptime up-centrifugo up-n8n up-clickhouse up-kafka up-redis up-mailpit import-n8n-workflows check-telegram-elevenlabs-workflow deploy logs status init-server
```

- [ ] **Step 3: Update `Makefile` help output**

In the `help` target, add these two lines after the existing `make up-kafka` line:

```make
	  '  make up-redis' \
	  '  make up-mailpit' \
```

- [ ] **Step 4: Add `Makefile` targets**

Add these targets after `up-kafka`:

```make
up-redis:
	./scripts/create-network.sh proxy
	./scripts/create-network.sh data
	cd redis && docker compose --env-file .env up -d --remove-orphans

up-mailpit:
	./scripts/create-network.sh proxy
	./scripts/create-network.sh data
	cd mailpit && docker compose --env-file .env up -d --remove-orphans
```

- [ ] **Step 5: Update `scripts/lib.sh` infra stack recognition**

Replace the body of `is_infra_stack()` with this exact function:

```bash
is_infra_stack() {
  local stack="$1"
  [[ "$stack" == "gateway" || "$stack" == "postgres" || "$stack" == "registry" || "$stack" == "observability" || "$stack" == "admin" || "$stack" == "uptime" || "$stack" == "centrifugo" || "$stack" == "n8n" || "$stack" == "clickhouse" || "$stack" == "kafka" || "$stack" == "redis" || "$stack" == "mailpit" ]]
}
```

- [ ] **Step 6: Update usage text in shared scripts**

In `scripts/logs.sh` and `scripts/restart.sh`, replace:

```text
$0 <gateway|postgres|registry|observability|admin|uptime|centrifugo|n8n|clickhouse|kafka> [service]
```

with:

```text
$0 <gateway|postgres|registry|observability|admin|uptime|centrifugo|n8n|clickhouse|kafka|redis|mailpit> [service]
```

In `scripts/healthcheck.sh`, replace:

```text
$0 <gateway|postgres|registry|observability|admin|uptime|centrifugo|n8n|clickhouse|kafka>
```

with:

```text
$0 <gateway|postgres|registry|observability|admin|uptime|centrifugo|n8n|clickhouse|kafka|redis|mailpit>
```

In `scripts/backup-volumes.sh`, replace:

```text
$0 --stack <gateway|postgres|registry|observability|admin|uptime|centrifugo|n8n|clickhouse|kafka>
```

with:

```text
$0 --stack <gateway|postgres|registry|observability|admin|uptime|centrifugo|n8n|clickhouse|kafka|redis|mailpit>
```

- [ ] **Step 7: Update `scripts/init-server.sh` startup hints**

Replace the final `Next steps` list with:

```text
Next steps:
  1. Copy each *.env.example to .env in the relevant stack directory.
  2. Put real application env files into env/prod and env/stage.
  3. Start gateway: make up-gateway
  4. Start postgres if needed: make up-postgres
  5. Start registry if needed: make up-registry
  6. Start observability: make up-observability
  7. Start n8n if needed: make up-n8n
  8. Start ClickHouse if needed: make up-clickhouse
  9. Start Kafka if needed: make up-kafka
  10. Start Redis if needed: make up-redis
  11. Start Mailpit if needed: make up-mailpit
```

- [ ] **Step 8: Verify command wiring**

Run:

```bash
make help | rg "up-redis|up-mailpit"
```

Expected output includes:

```text
  make up-redis
  make up-mailpit
```

Run:

```bash
source scripts/lib.sh && is_infra_stack redis && is_infra_stack mailpit
```

Expected: PASS with exit code `0`.

Run:

```bash
./scripts/healthcheck.sh
```

Expected: FAIL with usage text that includes `redis|mailpit`.

- [ ] **Step 9: Commit command wiring**

Run:

```bash
git status --short
git add Makefile scripts/lib.sh scripts/logs.sh scripts/restart.sh scripts/healthcheck.sh scripts/backup-volumes.sh scripts/init-server.sh
git diff --cached --check
git commit -m "chore: wire redis and mailpit infra commands"
```

Expected: commit succeeds and includes only the command and script files.

## Task 4: Update Root Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/backup-restore.md`

- [ ] **Step 1: Write the failing documentation check**

Run:

```bash
rg -n "redis|mailpit|Redis|Mailpit" README.md docs/backup-restore.md
```

Expected: FAIL with exit code `1` because the root documentation does not mention the new stacks yet.

- [ ] **Step 2: Update root README service list**

In `README.md`, add these bullets after the `kafka/` bullet:

```markdown
- `redis/` — Redis server с публичным Redis Insight через Traefik и Basic Auth.
- `mailpit/` — Mailpit SMTP capture с публичным web UI через Traefik и Basic Auth.
```

- [ ] **Step 3: Update root README env copy commands**

In the quick start env copy block, add these lines after `cp kafka/.env.example kafka/.env`:

```bash
cp redis/.env.example redis/.env
cp mailpit/.env.example mailpit/.env
```

- [ ] **Step 4: Update root README start commands**

In the startup command block, add these lines after `make up-kafka`:

```bash
make up-redis
make up-mailpit
```

- [ ] **Step 5: Update root README public UI notes**

After the Kafka UI sentence, add:

```markdown
   После `make up-redis` Redis Insight будет доступен по `https://<REDIS_UI_HOST>/`.
   После `make up-mailpit` Mailpit UI будет доступен по `https://<MAILPIT_HOST>/`.
```

- [ ] **Step 6: Update root README compose conventions**

In the Compose conventions list, add these bullets after the Kafka convention:

```markdown
- Redis port не публикуется на host; публичен только Redis Insight через Traefik с Basic Auth.
- Mailpit SMTP port не публикуется на host; публичен только Mailpit UI через Traefik с Basic Auth.
- Внутренние клиенты подключаются к Redis как `infra-redis:6379` и к Mailpit SMTP как `infra-mailpit:1025` в сети `data`.
```

- [ ] **Step 7: Update root README command list**

In both the "Основные команды" prose list and the fenced command block, add:

```bash
make up-redis
make up-mailpit
```

- [ ] **Step 8: Update root README useful docs**

In "Полезные документы", add:

```markdown
- `redis/README.md`
- `mailpit/README.md`
```

- [ ] **Step 9: Update backup documentation**

In `docs/backup-restore.md`, add these bullets to the minimal backup set after the Kafka volume bullet:

```markdown
- volumes `redis-data` и `redis-ui-data`;
- volume `mailpit-data`;
```

In the stack backup command block, add these commands after `./scripts/backup-volumes.sh --stack kafka`:

```bash
./scripts/backup-volumes.sh --stack redis
./scripts/backup-volumes.sh --stack mailpit
```

- [ ] **Step 10: Verify documentation**

Run:

```bash
rg -n "redis|mailpit|Redis|Mailpit|REDIS_UI_HOST|MAILPIT_HOST|infra-redis|infra-mailpit" README.md docs/backup-restore.md redis/README.md mailpit/README.md
```

Expected: PASS and prints entries from all four documentation files.

- [ ] **Step 11: Commit documentation**

Run:

```bash
git status --short
git add README.md docs/backup-restore.md
git diff --cached --check
git commit -m "docs: document redis and mailpit stacks"
```

Expected: commit succeeds and includes only `README.md` and `docs/backup-restore.md`.

## Task 5: Final Verification

**Files:**
- Read: all files touched by Tasks 1-4

- [ ] **Step 1: Verify compose configs**

Run:

```bash
docker compose --env-file redis/.env.example -f redis/docker-compose.yml config >/tmp/redis-compose-config.yml
docker compose --env-file mailpit/.env.example -f mailpit/docker-compose.yml config >/tmp/mailpit-compose-config.yml
```

Expected: both commands pass with exit code `0`.

- [ ] **Step 2: Verify expected services and volumes**

Run:

```bash
rg -n "infra-redis|infra-redis-ui|redis-data|redis-ui-data|5540|6379" /tmp/redis-compose-config.yml
rg -n "infra-mailpit|mailpit-data|8025|1025|MP_DATABASE|MP_MAX_MESSAGES" /tmp/mailpit-compose-config.yml
```

Expected: both commands pass and print matching lines.

- [ ] **Step 3: Verify helper scripts**

Run:

```bash
make help | rg "up-redis|up-mailpit"
source scripts/lib.sh && is_infra_stack redis && is_infra_stack mailpit
rg -n "redis\\|mailpit" scripts/healthcheck.sh scripts/backup-volumes.sh scripts/logs.sh scripts/restart.sh
```

Expected: all commands pass. The script usage text contains `redis|mailpit`.

- [ ] **Step 4: Verify docs**

Run:

```bash
rg -n "REDIS_UI_HOST|MAILPIT_HOST|infra-redis:6379|infra-mailpit:1025|redis-data|redis-ui-data|mailpit-data" README.md docs/backup-restore.md redis/README.md mailpit/README.md
```

Expected: PASS and prints matching documentation lines.

- [ ] **Step 5: Verify final git state**

Run:

```bash
git status --short
```

Expected: only unrelated pre-existing user changes remain unstaged. There should be no unstaged changes from Redis or Mailpit implementation files.

## Do Not Start Runtime Containers During Plan Execution

Do not run `make up-redis`, `make up-mailpit`, or `docker compose up` during implementation unless the user explicitly asks for runtime startup. Those commands may pull images and mutate the local Docker runtime. Compose config validation is sufficient for this implementation pass.
