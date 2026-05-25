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
