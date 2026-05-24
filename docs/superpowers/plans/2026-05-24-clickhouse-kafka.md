# ClickHouse and Kafka Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add internal ClickHouse and Kafka services with public Basic Auth protected web UIs behind the existing Traefik gateway.

**Architecture:** Add two independent top-level infra stacks: `clickhouse/` and `kafka/`. The stateful services join only the external `data` Docker network, while each UI joins `data` plus `proxy` and is exposed by Traefik with Basic Auth.

**Tech Stack:** Docker Compose, Traefik, ClickHouse official Docker image, CH-UI, Apache Kafka official Docker image in KRaft mode, Kafbat UI, bash helper scripts, Markdown runbooks.

---

## Source References

- ClickHouse Docker official image: `https://hub.docker.com/_/clickhouse`
- CH-UI installation docs: `https://ch-ui.com/docs/installation/`
- CH-UI releases: `https://github.com/caioricciuti/ch-ui/releases`
- Apache Kafka Docker image docs: `https://hub.docker.com/r/apache/kafka`
- Kafbat UI getting started docs: `https://ui.docs.kafbat.io/overview/getting-started`
- Kafbat UI configuration docs: `https://ui.docs.kafbat.io/configuration/configuration-file`
- Kafbat UI releases: `https://github.com/kafbat/kafka-ui/releases`
- Existing design spec: `docs/superpowers/specs/2026-05-24-clickhouse-kafka-design.md`

## File Structure

- Create `clickhouse/docker-compose.yml`: defines `infra-clickhouse` and `infra-clickhouse-ui`, persistent volumes, internal-only database networking, and Traefik labels for the UI.
- Create `clickhouse/.env.example`: documents ClickHouse, CH-UI, network, and Basic Auth variables with placeholders.
- Create `clickhouse/README.md`: documents startup, public UI, internal connection strings, operations, and backup.
- Create `kafka/docker-compose.yml`: defines `infra-kafka` in single-node KRaft mode and `infra-kafka-ui`, persistent broker volume, internal-only broker networking, and Traefik labels for the UI.
- Create `kafka/.env.example`: documents Kafka, Kafbat UI, network, and Basic Auth variables with placeholders.
- Create `kafka/README.md`: documents startup, public UI, internal bootstrap server, operations, topic smoke test, and backup.
- Modify `Makefile`: add `up-clickhouse` and `up-kafka` to help, phony targets, and target definitions.
- Modify `scripts/lib.sh`: recognize `clickhouse` and `kafka` as infra stacks.
- Modify `scripts/logs.sh`, `scripts/restart.sh`, `scripts/healthcheck.sh`, and `scripts/backup-volumes.sh`: include both stacks in usage text.
- Modify `scripts/init-server.sh`: include both stack startup hints.
- Modify `README.md`: include both stacks in the service list, env setup, startup commands, compose conventions, and command list.
- Modify `docs/backup-restore.md`: include the new named volumes and stack backup commands.

## Task 1: Add ClickHouse Stack

**Files:**
- Create: `clickhouse/docker-compose.yml`
- Create: `clickhouse/.env.example`
- Create: `clickhouse/README.md`

- [ ] **Step 1: Write the failing stack existence check**

Run:

```bash
test -f clickhouse/docker-compose.yml
```

Expected: FAIL because the file does not exist yet.

- [ ] **Step 2: Create the stack directory**

Run:

```bash
mkdir -p clickhouse
```

Expected: command exits with status 0.

- [ ] **Step 3: Create `clickhouse/docker-compose.yml`**

Write this exact file:

```yaml
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"

services:
  clickhouse:
    image: clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}
    container_name: infra-clickhouse
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      CLICKHOUSE_DB: ${CLICKHOUSE_DB}
      CLICKHOUSE_USER: ${CLICKHOUSE_USER}
      CLICKHOUSE_PASSWORD: ${CLICKHOUSE_PASSWORD}
      CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT: "1"
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    volumes:
      - clickhouse-data:/var/lib/clickhouse
      - clickhouse-logs:/var/log/clickhouse-server
    networks:
      data:
        aliases:
          - infra-clickhouse
          - clickhouse
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://127.0.0.1:8123/ping || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
    logging: *default-logging

  clickhouse-ui:
    image: ghcr.io/caioricciuti/ch-ui:${CLICKHOUSE_UI_VERSION}
    container_name: infra-clickhouse-ui
    restart: unless-stopped
    depends_on:
      clickhouse:
        condition: service_healthy
    environment:
      TZ: ${TZ}
      CLICKHOUSE_URL: http://infra-clickhouse:8123
      CLICKHOUSE_USER: ${CLICKHOUSE_USER}
      CLICKHOUSE_PASSWORD: ${CLICKHOUSE_PASSWORD}
      CONNECTION_NAME: ${CLICKHOUSE_UI_CONNECTION_NAME}
    security_opt:
      - no-new-privileges:true
    volumes:
      - clickhouse-ui-data:/app/data
    networks:
      - data
      - proxy
    labels:
      - traefik.enable=true
      - traefik.docker.network=${PROXY_NETWORK}
      - traefik.http.routers.clickhouse-ui.rule=Host(`${CLICKHOUSE_UI_HOST}`)
      - traefik.http.routers.clickhouse-ui.entrypoints=websecure
      - traefik.http.routers.clickhouse-ui.tls=true
      - traefik.http.routers.clickhouse-ui.tls.certresolver=letsencrypt
      - traefik.http.routers.clickhouse-ui.middlewares=default-chain@file,clickhouse-ui-auth@docker
      - traefik.http.services.clickhouse-ui.loadbalancer.server.port=3488
      - traefik.http.middlewares.clickhouse-ui-auth.basicauth.users=${CLICKHOUSE_UI_BASIC_AUTH_USERS}
    logging: *default-logging

volumes:
  clickhouse-data:
    name: clickhouse-data
  clickhouse-logs:
    name: clickhouse-logs
  clickhouse-ui-data:
    name: clickhouse-ui-data

networks:
  data:
    external: true
    name: ${DATA_NETWORK}
  proxy:
    external: true
    name: ${PROXY_NETWORK}
```

- [ ] **Step 4: Create `clickhouse/.env.example`**

Write this exact file:

```dotenv
COMPOSE_PROJECT_NAME=clickhouse

TZ=UTC
DATA_NETWORK=data
PROXY_NETWORK=proxy

CLICKHOUSE_VERSION=26.3.10.62
CLICKHOUSE_DB=app
CLICKHOUSE_USER=app
CLICKHOUSE_PASSWORD=change-me

CLICKHOUSE_UI_VERSION=v2.1.1
CLICKHOUSE_UI_HOST=clickhouse.example.com
CLICKHOUSE_UI_CONNECTION_NAME=Infra ClickHouse
# Example hash for password "change-me-now". Replace before production usage.
CLICKHOUSE_UI_BASIC_AUTH_USERS=admin:$$apr1$$B0n9m8eP$$yVZqzjYw2GvUf1Stj6G2j0
```

- [ ] **Step 5: Create `clickhouse/README.md`**

Write a runbook with these sections and exact operational facts:

````markdown
# ClickHouse

`clickhouse/` runs a single ClickHouse server and CH-UI behind the shared Traefik gateway.

The ClickHouse server is internal only. It joins the external `data` network and exposes no host ports. CH-UI joins `data` and `proxy`; Traefik exposes only the UI at `https://<CLICKHOUSE_UI_HOST>/` with Basic Auth.

## Setup

Copy the env example:

```bash
cp clickhouse/.env.example clickhouse/.env
chmod 600 clickhouse/.env
```

Set production values in `clickhouse/.env`:

- `CLICKHOUSE_DB`
- `CLICKHOUSE_USER`
- `CLICKHOUSE_PASSWORD`
- `CLICKHOUSE_UI_HOST`
- `CLICKHOUSE_UI_BASIC_AUTH_USERS`
- `TZ`

Generate Basic Auth with:

```bash
docker run --rm --entrypoint htpasswd httpd:2 -Bbn admin 'strong-password'
```

## Start

```bash
make up-gateway
make up-clickhouse
```

Open `https://<CLICKHOUSE_UI_HOST>/`.

## Internal Connections

Containers on the `data` network can use:

- HTTP endpoint: `http://infra-clickhouse:8123`
- Native endpoint: `infra-clickhouse:9000`
- Database: value of `CLICKHOUSE_DB`
- User: value of `CLICKHOUSE_USER`

## Operations

```bash
./scripts/healthcheck.sh clickhouse
./scripts/logs.sh clickhouse
./scripts/restart.sh clickhouse
```

## Backup

```bash
./scripts/backup-volumes.sh --stack clickhouse
```

The backup includes `clickhouse-data`, `clickhouse-logs`, and `clickhouse-ui-data`.
````

- [ ] **Step 6: Verify ClickHouse Compose config resolves with the example env**

Run:

```bash
cp clickhouse/.env.example clickhouse/.env
(cd clickhouse && docker compose --env-file .env config >/tmp/clickhouse-compose.yml)
```

Expected: command exits with status 0.

- [ ] **Step 7: Confirm ClickHouse exposes no host ports**

Run:

```bash
rg -n "ports:" clickhouse/docker-compose.yml
```

Expected: no matches.

- [ ] **Step 8: Remove generated local env**

Run:

```bash
rm -f clickhouse/.env
```

Expected: command exits with status 0.

## Task 2: Add Kafka Stack

**Files:**
- Create: `kafka/docker-compose.yml`
- Create: `kafka/.env.example`
- Create: `kafka/README.md`

- [ ] **Step 1: Write the failing stack existence check**

Run:

```bash
test -f kafka/docker-compose.yml
```

Expected: FAIL because the file does not exist yet.

- [ ] **Step 2: Create the stack directory**

Run:

```bash
mkdir -p kafka
```

Expected: command exits with status 0.

- [ ] **Step 3: Create `kafka/docker-compose.yml`**

Write this exact file:

```yaml
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"

services:
  kafka:
    image: apache/kafka:${KAFKA_VERSION}
    container_name: infra-kafka
    restart: unless-stopped
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: PLAINTEXT://:9092,CONTROLLER://:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://infra-kafka:9092
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@infra-kafka:9093
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      KAFKA_NUM_PARTITIONS: ${KAFKA_NUM_PARTITIONS}
      KAFKA_LOG_DIRS: /var/lib/kafka/data
      TZ: ${TZ}
    security_opt:
      - no-new-privileges:true
    volumes:
      - kafka-data:/var/lib/kafka/data
    networks:
      data:
        aliases:
          - infra-kafka
          - kafka
    healthcheck:
      test: ["CMD-SHELL", "/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server 127.0.0.1:9092 >/dev/null 2>&1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 45s
    logging: *default-logging

  kafka-ui:
    image: ghcr.io/kafbat/kafka-ui:${KAFKA_UI_VERSION}
    container_name: infra-kafka-ui
    restart: unless-stopped
    depends_on:
      kafka:
        condition: service_healthy
    environment:
      TZ: ${TZ}
      SERVER_PORT: 8080
      DYNAMIC_CONFIG_ENABLED: "false"
      KAFKA_CLUSTERS_0_NAME: ${KAFKA_UI_CLUSTER_NAME}
      KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: infra-kafka:9092
    security_opt:
      - no-new-privileges:true
    networks:
      - data
      - proxy
    labels:
      - traefik.enable=true
      - traefik.docker.network=${PROXY_NETWORK}
      - traefik.http.routers.kafka-ui.rule=Host(`${KAFKA_UI_HOST}`)
      - traefik.http.routers.kafka-ui.entrypoints=websecure
      - traefik.http.routers.kafka-ui.tls=true
      - traefik.http.routers.kafka-ui.tls.certresolver=letsencrypt
      - traefik.http.routers.kafka-ui.middlewares=default-chain@file,kafka-ui-auth@docker
      - traefik.http.services.kafka-ui.loadbalancer.server.port=8080
      - traefik.http.middlewares.kafka-ui-auth.basicauth.users=${KAFKA_UI_BASIC_AUTH_USERS}
    logging: *default-logging

volumes:
  kafka-data:
    name: kafka-data

networks:
  data:
    external: true
    name: ${DATA_NETWORK}
  proxy:
    external: true
    name: ${PROXY_NETWORK}
```

- [ ] **Step 4: Create `kafka/.env.example`**

Write this exact file:

```dotenv
COMPOSE_PROJECT_NAME=kafka

TZ=UTC
DATA_NETWORK=data
PROXY_NETWORK=proxy

KAFKA_VERSION=4.3.0
KAFKA_NUM_PARTITIONS=3

KAFKA_UI_VERSION=v1.5.0
KAFKA_UI_CLUSTER_NAME=infra
KAFKA_UI_HOST=kafka.example.com
# Example hash for password "change-me-now". Replace before production usage.
KAFKA_UI_BASIC_AUTH_USERS=admin:$$apr1$$B0n9m8eP$$yVZqzjYw2GvUf1Stj6G2j0
```

- [ ] **Step 5: Create `kafka/README.md`**

Write a runbook with these sections and exact operational facts:

````markdown
# Kafka

`kafka/` runs a single Kafka broker in KRaft mode and Kafbat UI behind the shared Traefik gateway.

The broker is internal only. It joins the external `data` network and exposes no host ports. Kafbat UI joins `data` and `proxy`; Traefik exposes only the UI at `https://<KAFKA_UI_HOST>/` with Basic Auth.

## Setup

Copy the env example:

```bash
cp kafka/.env.example kafka/.env
chmod 600 kafka/.env
```

Set production values in `kafka/.env`:

- `KAFKA_UI_HOST`
- `KAFKA_UI_BASIC_AUTH_USERS`
- `KAFKA_NUM_PARTITIONS`
- `TZ`

Generate Basic Auth with:

```bash
docker run --rm --entrypoint htpasswd httpd:2 -Bbn admin 'strong-password'
```

## Start

```bash
make up-gateway
make up-kafka
```

Open `https://<KAFKA_UI_HOST>/`.

## Internal Connections

Containers on the `data` network can use:

```text
infra-kafka:9092
```

## Operations

```bash
./scripts/healthcheck.sh kafka
./scripts/logs.sh kafka
./scripts/restart.sh kafka
```

## Topic Smoke Test

```bash
docker exec -it infra-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server infra-kafka:9092 --list
```

## Backup

```bash
./scripts/backup-volumes.sh --stack kafka
```

The backup includes the `kafka-data` broker volume.
````

- [ ] **Step 6: Verify Kafka Compose config resolves with the example env**

Run:

```bash
cp kafka/.env.example kafka/.env
(cd kafka && docker compose --env-file .env config >/tmp/kafka-compose.yml)
```

Expected: command exits with status 0.

- [ ] **Step 7: Confirm Kafka exposes no host ports**

Run:

```bash
rg -n "ports:" kafka/docker-compose.yml
```

Expected: no matches.

- [ ] **Step 8: Remove generated local env**

Run:

```bash
rm -f kafka/.env
```

Expected: command exits with status 0.

## Task 3: Wire Operations

**Files:**
- Modify: `Makefile`
- Modify: `scripts/lib.sh`
- Modify: `scripts/logs.sh`
- Modify: `scripts/restart.sh`
- Modify: `scripts/healthcheck.sh`
- Modify: `scripts/backup-volumes.sh`
- Modify: `scripts/init-server.sh`

- [ ] **Step 1: Update `Makefile`**

Add `up-clickhouse` and `up-kafka` to `.PHONY`, help output, and target definitions:

```make
up-clickhouse:
	./scripts/create-network.sh proxy
	./scripts/create-network.sh data
	cd clickhouse && docker compose --env-file .env up -d --remove-orphans

up-kafka:
	./scripts/create-network.sh proxy
	./scripts/create-network.sh data
	cd kafka && docker compose --env-file .env up -d --remove-orphans
```

- [ ] **Step 2: Update infra stack recognition**

In `scripts/lib.sh`, make `is_infra_stack()` return true for:

```bash
gateway postgres registry observability admin uptime centrifugo n8n clickhouse kafka
```

- [ ] **Step 3: Update usage text in scripts**

In `scripts/logs.sh`, `scripts/restart.sh`, `scripts/healthcheck.sh`, and `scripts/backup-volumes.sh`, replace usage unions with:

```text
gateway|postgres|registry|observability|admin|uptime|centrifugo|n8n|clickhouse|kafka
```

- [ ] **Step 4: Update bootstrap hints**

In `scripts/init-server.sh`, add:

```text
  8. Start ClickHouse if needed: make up-clickhouse
  9. Start Kafka if needed: make up-kafka
```

- [ ] **Step 5: Verify helper resolution**

Run:

```bash
bash -n scripts/lib.sh scripts/logs.sh scripts/restart.sh scripts/healthcheck.sh scripts/backup-volumes.sh scripts/init-server.sh
```

Expected: command exits with status 0.

## Task 4: Update Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/backup-restore.md`

- [ ] **Step 1: Update root README service list**

Add:

```markdown
- `clickhouse/` — ClickHouse server with public CH-UI through Traefik and Basic Auth.
- `kafka/` — single-node Kafka in KRaft mode with public Kafbat UI through Traefik and Basic Auth.
```

- [ ] **Step 2: Update root README quick start env copy commands**

Add:

```bash
cp clickhouse/.env.example clickhouse/.env
cp kafka/.env.example kafka/.env
```

- [ ] **Step 3: Update root README startup commands and command lists**

Add:

```bash
make up-clickhouse
make up-kafka
```

- [ ] **Step 4: Update root README compose conventions**

Add:

```markdown
- ClickHouse and Kafka broker ports are not published on the host; only their UIs are exposed through Traefik with Basic Auth.
- Internal clients reach ClickHouse as `infra-clickhouse` and Kafka as `infra-kafka:9092` on the `data` network.
```

- [ ] **Step 5: Update backup docs**

In `docs/backup-restore.md`, include:

```markdown
- volumes `clickhouse-data`, `clickhouse-logs`, and `clickhouse-ui-data`;
- volume `kafka-data`;
```

Add stack backup commands:

```bash
./scripts/backup-volumes.sh --stack clickhouse
./scripts/backup-volumes.sh --stack kafka
```

## Task 5: Final Verification

**Files:**
- Verify all created and modified files.

- [ ] **Step 1: Validate shell scripts**

Run:

```bash
bash -n scripts/*.sh
```

Expected: command exits with status 0.

- [ ] **Step 2: Validate ClickHouse Compose config**

Run:

```bash
cp clickhouse/.env.example clickhouse/.env
(cd clickhouse && docker compose --env-file .env config >/tmp/clickhouse-compose.yml)
rm -f clickhouse/.env
```

Expected: command exits with status 0.

- [ ] **Step 3: Validate Kafka Compose config**

Run:

```bash
cp kafka/.env.example kafka/.env
(cd kafka && docker compose --env-file .env config >/tmp/kafka-compose.yml)
rm -f kafka/.env
```

Expected: command exits with status 0.

- [ ] **Step 4: Confirm no service ports are published**

Run:

```bash
! rg -n "^[[:space:]]+ports:" clickhouse/docker-compose.yml kafka/docker-compose.yml
```

Expected: command exits with status 0.

- [ ] **Step 5: Review git diff**

Run:

```bash
git diff --stat
git diff -- clickhouse kafka Makefile scripts README.md docs/backup-restore.md
```

Expected: diff contains only ClickHouse/Kafka infra changes and docs. Existing unrelated `danilka-tech` deletions remain unstaged and untouched.

- [ ] **Step 6: Commit implementation**

Run:

```bash
git add clickhouse kafka Makefile scripts README.md docs/backup-restore.md
git commit -m "feat: add clickhouse and kafka infra stacks"
```

Expected: commit succeeds and does not include unrelated `danilka-tech` deletions.
