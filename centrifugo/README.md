# Centrifugo

Отдельный stack для `Centrifugo` с публичным websocket/API endpoint через `Traefik` и внутренним портом для `/api`, `/health`, `/metrics` и опционального admin UI.

## Подготовка

```bash
cp centrifugo/.env.example centrifugo/.env
```

Заполните минимум:

- `CENTRIFUGO_HOST` — публичный домен для клиентских подключений;
- `CENTRIFUGO_CLIENT_ALLOWED_ORIGINS` — origin вашего frontend;
- `CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY` — секрет подписи JWT для подключений клиентов;
- `CENTRIFUGO_HTTP_API_KEY` — ключ для backend-публикаций в HTTP API.

Если хотите включить встроенную admin UI, установите `CENTRIFUGO_ADMIN_ENABLED=true` и задайте сильный `CENTRIFUGO_ADMIN_PASSWORD`. UI останется только на внутреннем порту и не будет опубликован наружу через Traefik.

## Запуск

```bash
make up-centrifugo
```

Или вручную:

```bash
./scripts/create-network.sh proxy
./scripts/create-network.sh data
cd centrifugo && docker compose --env-file .env up -d --remove-orphans
```

## Endpoint'ы

- Публичное websocket-подключение: `wss://<CENTRIFUGO_HOST>/connection/websocket`
- Внутренний HTTP API из контейнеров: `http://infra-centrifugo:<CENTRIFUGO_INTERNAL_PORT>/api`
- Healthcheck: `http://infra-centrifugo:<CENTRIFUGO_INTERNAL_PORT>/health`
- Metrics для Prometheus: `http://infra-centrifugo:<CENTRIFUGO_INTERNAL_PORT>/metrics`

## Примечания

- Stack использует `memory` engine по умолчанию, этого достаточно для одного инстанса на одной VDS.
- Контейнер подключён к `data`, поэтому backend-сервисы могут ходить в Centrifugo по имени `infra-centrifugo`.
- В `observability/prometheus/prometheus.yml` уже добавлен scrape job `centrifugo`.
