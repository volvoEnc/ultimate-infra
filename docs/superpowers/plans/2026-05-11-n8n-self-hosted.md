# n8n Self-Hosted Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a production-ready n8n self-hosted Docker Compose stack backed by the existing shared PostgreSQL service.

**Architecture:** n8n runs as a dedicated infra stack in `n8n/`, joins the existing external `proxy` and `data` networks, and is exposed by the existing Traefik gateway. Runtime data persists in a named Docker volume while application state uses a dedicated database/user in shared PostgreSQL.

**Tech Stack:** Docker Compose, Traefik, PostgreSQL, bash helper scripts, Markdown runbooks.

---

## Source References

- n8n Docker docs: `https://docs.n8n.io/hosting/installation/docker/`
- n8n Docker Compose docs: `https://docs.n8n.io/hosting/installation/server-setups/docker-compose/`
- n8n database environment variables: `https://docs.n8n.io/hosting/configuration/environment-variables/database/`
- n8n endpoint environment variables: `https://docs.n8n.io/hosting/configuration/environment-variables/endpoints/`
- n8n security environment variables: `https://docs.n8n.io/hosting/configuration/environment-variables/security/`
- n8n encryption key docs: `https://docs.n8n.io/hosting/configuration/configuration-examples/encryption-key/`

## File Structure

- Create `n8n/docker-compose.yml`: defines the single n8n service, Traefik labels, healthcheck, persistent volume, and external network joins.
- Create `n8n/.env.example`: documents all required stack variables with non-secret example values.
- Create `n8n/README.md`: explains database creation, env setup, startup, health checks, logs, restart, update, and backup.
- Modify `Makefile`: adds `up-n8n` to help output and target list.
- Modify `scripts/lib.sh`: recognizes `n8n` as an infra stack.
- Modify `scripts/healthcheck.sh`, `scripts/logs.sh`, `scripts/restart.sh`, and `scripts/backup-volumes.sh`: updates usage text to include `n8n`.
- Modify `scripts/init-server.sh`: adds `make up-n8n` to suggested next steps.
- Modify `README.md`: adds n8n to the stack list, quick start env copies, startup commands, compose conventions, and command list.
- Modify `docs/backup-restore.md`: documents n8n volume and database backup expectations.

## Task 1: Add n8n Compose Stack

**Files:**
- Create: `n8n/docker-compose.yml`
- Create: `n8n/.env.example`
- Create: `n8n/README.md`

- [ ] **Step 1: Write the failing stack existence check**

Run:

```bash
test -f n8n/docker-compose.yml
```

Expected: FAIL with a shell error because `n8n/docker-compose.yml` does not exist.

- [ ] **Step 2: Create the n8n stack directory**

Run:

```bash
mkdir -p n8n
```

Expected: command exits with status 0.

- [ ] **Step 3: Create `n8n/docker-compose.yml`**

Write this exact file:

```yaml
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"

services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:${N8N_VERSION}
    container_name: infra-n8n
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      NODE_ENV: production
      N8N_HOST: ${N8N_HOST}
      N8N_PROTOCOL: ${N8N_PROTOCOL}
      N8N_PORT: ${N8N_PORT}
      WEBHOOK_URL: ${WEBHOOK_URL}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: ${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}
      N8N_RUNNERS_ENABLED: ${N8N_RUNNERS_ENABLED}
      N8N_DIAGNOSTICS_ENABLED: ${N8N_DIAGNOSTICS_ENABLED}
      N8N_PERSONALIZATION_ENABLED: ${N8N_PERSONALIZATION_ENABLED}
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: ${DB_POSTGRESDB_HOST}
      DB_POSTGRESDB_PORT: ${DB_POSTGRESDB_PORT}
      DB_POSTGRESDB_DATABASE: ${DB_POSTGRESDB_DATABASE}
      DB_POSTGRESDB_USER: ${DB_POSTGRESDB_USER}
      DB_POSTGRESDB_PASSWORD: ${DB_POSTGRESDB_PASSWORD}
      DB_POSTGRESDB_SCHEMA: ${DB_POSTGRESDB_SCHEMA}
    security_opt:
      - no-new-privileges:true
    volumes:
      - n8n-data:/home/node/.n8n
    networks:
      data:
        aliases:
          - infra-n8n
          - n8n
      proxy:
    healthcheck:
      test: ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:${N8N_PORT}/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    labels:
      - traefik.enable=true
      - traefik.docker.network=${PROXY_NETWORK}
      - traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.tls.certresolver=letsencrypt
      - traefik.http.routers.n8n.middlewares=default-chain@file
      - traefik.http.services.n8n.loadbalancer.server.port=${N8N_PORT}
    logging: *default-logging

volumes:
  n8n-data:
    name: n8n-data

networks:
  data:
    external: true
    name: ${DATA_NETWORK}
  proxy:
    external: true
    name: ${PROXY_NETWORK}
```

- [ ] **Step 4: Create `n8n/.env.example`**

Write this exact file:

```dotenv
COMPOSE_PROJECT_NAME=n8n

TZ=UTC
GENERIC_TIMEZONE=UTC
PROXY_NETWORK=proxy
DATA_NETWORK=data

N8N_VERSION=2.19.4
N8N_HOST=n8n.example.com
N8N_PROTOCOL=https
N8N_PORT=5678
WEBHOOK_URL=https://n8n.example.com/
N8N_ENCRYPTION_KEY=replace-with-long-random-secret
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
N8N_RUNNERS_ENABLED=true
N8N_DIAGNOSTICS_ENABLED=false
N8N_PERSONALIZATION_ENABLED=false

DB_POSTGRESDB_HOST=infra-postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n_prod
DB_POSTGRESDB_USER=n8n_prod
DB_POSTGRESDB_PASSWORD=replace-with-database-password
DB_POSTGRESDB_SCHEMA=public
```

- [ ] **Step 5: Create `n8n/README.md`**

Write this exact file:

````markdown
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
````

- [ ] **Step 6: Verify Compose config resolves with the example env**

Run:

```bash
docker compose --env-file n8n/.env.example -f n8n/docker-compose.yml config --quiet
```

Expected: PASS with exit status 0 and no missing-variable warnings.

- [ ] **Step 7: Commit the n8n stack**

Run:

```bash
git add n8n/docker-compose.yml n8n/.env.example n8n/README.md
git commit -m "feat: add n8n self-hosted stack"
```

Expected: commit succeeds.

## Task 2: Wire n8n Into Operations

**Files:**
- Modify: `Makefile`
- Modify: `scripts/lib.sh`
- Modify: `scripts/healthcheck.sh`
- Modify: `scripts/logs.sh`
- Modify: `scripts/restart.sh`
- Modify: `scripts/backup-volumes.sh`
- Modify: `scripts/init-server.sh`

- [ ] **Step 1: Write the failing Makefile check**

Run:

```bash
make -n up-n8n
```

Expected: FAIL with `No rule to make target 'up-n8n'`.

- [ ] **Step 2: Write the failing infra stack recognition check**

Run:

```bash
bash -c 'source scripts/lib.sh; is_infra_stack n8n'
```

Expected: FAIL with exit status 1.

- [ ] **Step 3: Update `Makefile` phony targets**

Replace the `.PHONY` line with:

```makefile
.PHONY: help up-gateway up-postgres up-registry up-observability up-admin up-uptime up-centrifugo up-n8n deploy logs status init-server
```

- [ ] **Step 4: Update `Makefile` help output**

Add this line after `make up-centrifugo` in the help output:

```makefile
	  '  make up-n8n' \
```

- [ ] **Step 5: Add the `up-n8n` target to `Makefile`**

Add this block after `up-centrifugo`:

```makefile
up-n8n:
	./scripts/create-network.sh proxy
	./scripts/create-network.sh data
	cd n8n && docker compose --env-file .env up -d --remove-orphans
```

- [ ] **Step 6: Update `scripts/lib.sh` infra stack recognition**

Replace the `is_infra_stack` function with:

```bash
is_infra_stack() {
  local stack="$1"
  [[ "$stack" == "gateway" || "$stack" == "postgres" || "$stack" == "registry" || "$stack" == "observability" || "$stack" == "admin" || "$stack" == "uptime" || "$stack" == "n8n" ]]
}
```

- [ ] **Step 7: Update `scripts/healthcheck.sh` usage text**

Replace the first usage line with:

```bash
  $0 <gateway|postgres|registry|observability|admin|uptime|n8n>
```

- [ ] **Step 8: Update `scripts/logs.sh` usage text**

Replace the first usage line with:

```bash
  $0 <gateway|postgres|registry|observability|admin|uptime|n8n> [service]
```

- [ ] **Step 9: Update `scripts/restart.sh` usage text**

Replace the first usage line with:

```bash
  $0 <gateway|postgres|registry|observability|admin|uptime|n8n> [service]
```

- [ ] **Step 10: Update `scripts/backup-volumes.sh` usage text**

Replace the first stack usage line with:

```bash
  $0 --stack <gateway|postgres|registry|observability|admin|uptime|n8n>
```

- [ ] **Step 11: Update `scripts/init-server.sh` next steps**

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
```

- [ ] **Step 12: Verify Makefile dry run**

Run:

```bash
make -n up-n8n
```

Expected: PASS and prints these commands:

```text
./scripts/create-network.sh proxy
./scripts/create-network.sh data
cd n8n && docker compose --env-file .env up -d --remove-orphans
```

- [ ] **Step 13: Verify infra stack recognition**

Run:

```bash
bash -c 'source scripts/lib.sh; is_infra_stack n8n && resolve_stack_dir n8n'
```

Expected: PASS and prints the absolute path ending with `/infra/n8n`.

- [ ] **Step 14: Verify usage text mentions n8n**

Run:

```bash
rg -n "uptime\\|n8n" scripts/healthcheck.sh scripts/logs.sh scripts/restart.sh scripts/backup-volumes.sh
```

Expected: PASS and shows one usage line in each script.

- [ ] **Step 15: Commit operations wiring**

Run:

```bash
git add Makefile scripts/lib.sh scripts/healthcheck.sh scripts/logs.sh scripts/restart.sh scripts/backup-volumes.sh scripts/init-server.sh
git commit -m "feat: wire n8n into infra operations"
```

Expected: commit succeeds.

## Task 3: Update Repository Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/backup-restore.md`

- [ ] **Step 1: Write the failing docs coverage check**

Run:

```bash
rg -n "n8n" README.md docs/backup-restore.md
```

Expected: FAIL with exit status 1 because neither file documents n8n yet.

- [ ] **Step 2: Update `README.md` stack list**

Add this bullet after `centrifugo/`:

```markdown
- `n8n/` — self-hosted workflow automation через Traefik и shared PostgreSQL.
```

- [ ] **Step 3: Update `README.md` quick start env copy commands**

Add this line after `cp centrifugo/.env.example centrifugo/.env`:

```bash
   cp n8n/.env.example n8n/.env
```

- [ ] **Step 4: Update `README.md` startup commands**

Add this command after `make up-centrifugo`:

```bash
   make up-n8n
```

- [ ] **Step 5: Update `README.md` post-start note**

Add this sentence after the Adminer sentence:

```markdown
   После `make up-n8n` n8n будет доступен по `https://<N8N_HOST>/`.
```

- [ ] **Step 6: Update `README.md` compose conventions**

Add this bullet near the PostgreSQL/networking bullets:

```markdown
- n8n использует отдельную PostgreSQL базу в shared `infra-postgres` и named volume `n8n-data`.
```

- [ ] **Step 7: Update `README.md` command list**

Add `make up-n8n` to both the "Основные команды" code block and help-oriented command lists:

```bash
make up-n8n
```

- [ ] **Step 8: Update `README.md` useful docs list**

Add this bullet:

```markdown
- `n8n/README.md`
```

- [ ] **Step 9: Update `docs/backup-restore.md` backup list**

Add n8n to the list of important volumes:

```markdown
- volume `n8n-data` plus the dedicated n8n PostgreSQL database;
```

- [ ] **Step 10: Update `docs/backup-restore.md` volume examples**

Add this command near the infra stack backup examples:

```bash
./scripts/backup-volumes.sh --stack n8n
```

- [ ] **Step 11: Add n8n database warning to `docs/backup-restore.md`**

Add this paragraph near the restore verification guidance:

```markdown
Для n8n backup volume не заменяет backup PostgreSQL: workflows, credentials и executions хранятся в выделенной базе shared PostgreSQL. Перед обновлениями n8n сохраняйте `n8n-data`, env и дамп базы.
```

- [ ] **Step 12: Verify docs coverage**

Run:

```bash
rg -n "n8n|up-n8n|n8n-data" README.md docs/backup-restore.md n8n/README.md
```

Expected: PASS and shows matches in all three files.

- [ ] **Step 13: Commit docs updates**

Run:

```bash
git add README.md docs/backup-restore.md
git commit -m "docs: document n8n operations"
```

Expected: commit succeeds.

## Task 4: Final Verification

**Files:**
- Verify all changed files.

- [ ] **Step 1: Check working tree state**

Run:

```bash
git status --short
```

Expected: either clean output or only intentional uncommitted changes for the current task.

- [ ] **Step 2: Verify Compose config**

Run:

```bash
docker compose --env-file n8n/.env.example -f n8n/docker-compose.yml config --quiet
```

Expected: PASS with exit status 0.

- [ ] **Step 3: Verify Makefile target**

Run:

```bash
make -n up-n8n
```

Expected: PASS and prints the n8n startup commands.

- [ ] **Step 4: Verify script stack resolution**

Run:

```bash
bash -c 'source scripts/lib.sh; is_infra_stack n8n && resolve_stack_dir n8n'
```

Expected: PASS and prints the absolute `n8n` stack directory.

- [ ] **Step 5: Verify docs and scripts reference n8n**

Run:

```bash
rg -n "n8n|up-n8n|n8n-data" README.md docs/backup-restore.md n8n/README.md Makefile scripts
```

Expected: PASS and shows references in docs, Makefile, and script usage text.

- [ ] **Step 6: Check formatting whitespace**

Run:

```bash
git diff --check
```

Expected: PASS with no output.

- [ ] **Step 7: Review final diff**

Run:

```bash
git diff --stat HEAD~3..HEAD
```

Expected: shows the n8n stack, operation wiring, and docs commits only.
