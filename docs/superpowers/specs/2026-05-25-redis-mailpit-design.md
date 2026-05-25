# Redis and Mailpit infra design

## Goal

Add self-hosted Redis, Redis UI, and Mailpit to the existing single-VDS infra repository.

The services must follow the repository's current Docker Compose conventions: independent top-level infra stacks, shared external `data` and `proxy` networks, public HTTPS UI routing through Traefik, Basic Auth on public UI routes, named volumes for persistent state, Docker log rotation, and operation through the Makefile plus shared scripts.

## Selected approach

Use two independent infra stacks:

- `redis/` for Redis server and Redis Insight UI.
- `mailpit/` for Mailpit SMTP capture and web UI.

This keeps state, lifecycle, logs, backups, and failure modes separated. A combined `dev-tools` stack would save a little typing, but it would also couple unrelated services into a small domestic tragedy.

## Redis stack

`redis/docker-compose.yml` defines:

- `redis`: official Redis image with append-only persistence enabled.
- `redis-ui`: Redis Insight for browsing and managing Redis.

The Redis server joins only the external `data` network and exposes no host port. Other containers can reach it through aliases:

- `infra-redis`
- `redis`

Redis must require a password from `REDIS_PASSWORD`. Internal clients should connect with:

```text
redis://:<REDIS_PASSWORD>@infra-redis:6379/0
```

Redis Insight joins both:

- external `data` network to reach Redis;
- external `proxy` network for Traefik.

The UI is exposed at `https://<REDIS_UI_HOST>/` through Traefik with `default-chain@file` and a Docker Basic Auth middleware.

## Mailpit stack

`mailpit/docker-compose.yml` defines:

- `mailpit`: Mailpit SMTP capture service with its built-in web UI and HTTP API.

Mailpit joins the external `data` network with aliases:

- `infra-mailpit`
- `mailpit`

Internal application containers send test email to:

```text
infra-mailpit:1025
```

Mailpit also joins the external `proxy` network for Traefik. Only the web UI/API port is exposed publicly through Traefik at `https://<MAILPIT_HOST>/` with `default-chain@file` and a Docker Basic Auth middleware.

The SMTP port is not published to the host. Mailpit is for development and test capture on this VDS, not a production SMTP relay.

## Runtime configuration

Each stack gets its own `.env.example` with placeholders only.

Redis variables include:

- `COMPOSE_PROJECT_NAME`
- `TZ`
- `DATA_NETWORK`
- `PROXY_NETWORK`
- `REDIS_VERSION`
- `REDIS_PASSWORD`
- `REDIS_UI_VERSION`
- `REDIS_UI_HOST`
- `REDIS_UI_BASIC_AUTH_USERS`

Mailpit variables include:

- `COMPOSE_PROJECT_NAME`
- `TZ`
- `DATA_NETWORK`
- `PROXY_NETWORK`
- `MAILPIT_VERSION`
- `MAILPIT_HOST`
- `MAILPIT_MAX_MESSAGES`
- `MAILPIT_UI_BASIC_AUTH_USERS`

Real credentials live only in untracked `.env` files.

## Persistence

Redis uses named volumes for:

- Redis data;
- Redis Insight data.

Mailpit uses a named volume for persistent message storage. The compose service must set `MP_DATABASE=/data/mailpit.db` and mount `mailpit-data` at `/data`, following Mailpit's documented persistent SQLite storage path. The stack should also set `MP_MAX_MESSAGES=${MAILPIT_MAX_MESSAGES}` so message retention is explicit instead of hiding behind image defaults.

Backups should use the existing `scripts/backup-volumes.sh --stack <stack>` path for named volumes. Application-level exports, seeded Redis data, and message export automation are out of scope for this first pass.

## Operations

Add Makefile targets:

```bash
make up-redis
make up-mailpit
```

Both targets create the required external networks and start the stack with:

```bash
docker compose --env-file .env up -d --remove-orphans
```

Extend infra stack recognition so these commands work:

```bash
./scripts/logs.sh redis
./scripts/restart.sh redis
./scripts/healthcheck.sh redis
./scripts/backup-volumes.sh --stack redis

./scripts/logs.sh mailpit
./scripts/restart.sh mailpit
./scripts/healthcheck.sh mailpit
./scripts/backup-volumes.sh --stack mailpit
```

## Documentation

Update the root `README.md` so both stacks appear in:

- service list;
- quick start `.env` copy commands;
- start commands;
- available Makefile commands;
- compose conventions.

Add focused runbooks:

- `redis/README.md`
- `mailpit/README.md`

Each README documents setup, public UI, internal connection details, operations, health checks, and backup notes.

## Health checks

Redis should have a container healthcheck based on `redis-cli ping` using `REDIS_PASSWORD`.

Redis Insight should depend on the Redis healthcheck when the selected image supports Compose health dependencies cleanly. If the image lacks a reliable local health endpoint, the container running state is sufficient for the shared healthcheck script.

Mailpit should have a container healthcheck that calls its local HTTP UI/API endpoint. Public URL checks are not required because public UI routes are Basic Auth protected.

## Testing

Implementation must verify:

- `docker compose --env-file .env.example config` succeeds for `redis/`.
- `docker compose --env-file .env.example config` succeeds for `mailpit/`.
- `make help` lists `up-redis` and `up-mailpit`.
- shared scripts accept `redis` and `mailpit` as infra stack names.
- documentation contains the internal Redis and Mailpit connection endpoints.

Starting the real stacks is optional and should be done only when network access and local Docker runtime are available, because it may pull images.

## Security

Public UI routes must use Traefik Basic Auth.

Redis and Mailpit SMTP ports are not published to the host. They are reachable only from containers attached to the `data` network.

Redis requires a password even on the internal network. No production secrets, generated data, message stores, or runtime files are committed.

## Out of scope

This design does not include:

- Redis Cluster;
- Redis Sentinel;
- externally reachable Redis TCP listener;
- Redis TLS or ACL user management beyond the initial password;
- Mailpit as a production SMTP relay;
- POP3 or other Mailpit host-published ports;
- Prometheus exporters and dashboards;
- automated Uptime Kuma monitors;
- seeded Redis databases or automated Mailpit message exports.

Those can be added later without changing the public UI URLs or internal service aliases.
