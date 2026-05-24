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
