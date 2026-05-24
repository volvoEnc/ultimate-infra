# ClickHouse and Kafka infra design

## Goal

Add self-hosted ClickHouse and Kafka stacks to the existing single-VDS infra repository.

The services must follow the repository's Docker Compose conventions: separate top-level infra stacks, Traefik for public HTTPS UI routing, Basic Auth on public UI routes, named volumes for persistent data, Docker log rotation, and operation through Makefile plus shared scripts.

## Selected approach

Use two independent infra stacks:

- `clickhouse/` for ClickHouse server and a simple public ClickHouse UI.
- `kafka/` for single-node Kafka in KRaft mode and a public Kafka UI.

This keeps lifecycle, logs, and backups separated. A combined "data-platform" stack would reduce command count, but it would also couple two unrelated stateful systems. That is convenient right until the first maintenance window turns into theatre.

## ClickHouse stack

`clickhouse/docker-compose.yml` defines:

- `clickhouse`: official ClickHouse server image.
- `clickhouse-ui`: lightweight web UI for browsing/querying ClickHouse.

The ClickHouse server joins only the external `data` network and exposes no host port. Other containers can reach it through aliases:

- `infra-clickhouse`
- `clickhouse`

The UI joins both:

- external `data` network to reach ClickHouse;
- external `proxy` network for Traefik.

The UI is exposed at `https://<CLICKHOUSE_UI_HOST>/` through Traefik with `default-chain@file` and a Docker Basic Auth middleware.

## Kafka stack

`kafka/docker-compose.yml` defines:

- `kafka`: single-node Apache Kafka-compatible broker in KRaft mode.
- `kafka-ui`: web UI for topics, brokers, consumers, and messages.

Kafka joins only the external `data` network and exposes no host port. Internal clients use:

- bootstrap server: `infra-kafka:9092`

The UI joins both:

- external `data` network to reach Kafka;
- external `proxy` network for Traefik.

The UI is exposed at `https://<KAFKA_UI_HOST>/` through Traefik with `default-chain@file` and a Docker Basic Auth middleware.

## Runtime configuration

Each stack gets its own `.env.example` with placeholders only.

ClickHouse variables include:

- `TZ`
- `DATA_NETWORK`
- `PROXY_NETWORK`
- `CLICKHOUSE_VERSION`
- `CLICKHOUSE_DB`
- `CLICKHOUSE_USER`
- `CLICKHOUSE_PASSWORD`
- `CLICKHOUSE_UI_HOST`
- `CLICKHOUSE_UI_BASIC_AUTH_USERS`

Kafka variables include:

- `TZ`
- `DATA_NETWORK`
- `PROXY_NETWORK`
- `KAFKA_VERSION`
- `KAFKA_UI_VERSION`
- `KAFKA_UI_HOST`
- `KAFKA_UI_BASIC_AUTH_USERS`

Real credentials live only in untracked `.env` files.

## Persistence

ClickHouse uses named volumes for:

- database data;
- server logs.

Kafka uses a named volume for broker data.

Backups should use the existing `scripts/backup-volumes.sh --stack <stack>` path. Application-level backups, schema exports, and Kafka topic export tooling are out of scope for this first pass.

## Operations

Add Makefile targets:

```bash
make up-clickhouse
make up-kafka
```

Both targets create the required external networks and start the stack with:

```bash
docker compose --env-file .env up -d --remove-orphans
```

Extend infra stack recognition so these commands work:

```bash
./scripts/logs.sh clickhouse
./scripts/restart.sh clickhouse
./scripts/healthcheck.sh clickhouse
./scripts/backup-volumes.sh --stack clickhouse

./scripts/logs.sh kafka
./scripts/restart.sh kafka
./scripts/healthcheck.sh kafka
./scripts/backup-volumes.sh --stack kafka
```

## Documentation

Update the root `README.md` so both stacks appear in:

- service list;
- quick start `.env` copy commands;
- start commands;
- available Makefile commands;
- compose conventions.

Add focused docs:

- `clickhouse/README.md`
- `kafka/README.md`

Each README documents setup, public UI, internal connection details, operations, and backup notes.

## Health checks

ClickHouse should have a container healthcheck that calls its local HTTP endpoint.

Kafka should have a broker healthcheck based on broker API readiness or metadata listing. Kafka UI should depend on the broker healthcheck when the selected image supports it cleanly.

UI services can be considered healthy if their containers are running unless the image provides a reliable local health endpoint without extra packages.

## Security

Public UI routes must use Traefik Basic Auth.

ClickHouse and Kafka broker ports are not published to the host. They are reachable only from containers attached to the `data` network.

No production secrets, generated data, cluster IDs, or runtime files are committed.

## Out of scope

This design does not include:

- multi-node Kafka;
- ZooKeeper;
- Kafka SASL/TLS;
- externally reachable Kafka listeners;
- ClickHouse clustering or replication;
- ClickHouse Keeper;
- Prometheus exporters and dashboards;
- automated topic/database bootstrap;
- automated Uptime Kuma monitors.

Those can be added later without changing the public UI URLs or internal service aliases.
