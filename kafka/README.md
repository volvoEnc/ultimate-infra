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
