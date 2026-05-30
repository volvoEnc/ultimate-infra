# Docker Registry

## Что это

`registry/` поднимает приватный Docker Registry за Traefik на отдельном домене.

Схема:

- HTTPS и сертификаты выдаёт Traefik;
- аутентификация делается самим Registry через `htpasswd`;
- данные образов лежат в volume `registry-data`.
- OTLP traces export в образе Registry 3 отключён явно через `OTEL_TRACES_EXPORTER=none`.
- браузерный UI поднимается отдельным сервисом `registry-ui`.

## Подготовка

1. Скопируйте env:

```bash
cp registry/.env.example registry/.env
```

2. Создайте файл пользователей:

```bash
mkdir -p env/prod
docker run --rm --entrypoint htpasswd httpd:2 -Bbn registry change-me > env/prod/registry.htpasswd
chmod 600 env/prod/registry.htpasswd
```

3. Проверьте `registry/.env`:

- `REGISTRY_HOST` — домен registry, например `registry.example.com`;
- `REGISTRY_UI_HOST` — отдельный домен UI, например `registry-ui.example.com`;
- `REGISTRY_HTTP_SECRET` — длинная случайная строка;
- `REGISTRY_AUTH_FILE` — путь к `htpasswd` файлу.

## Запуск

```bash
make up-registry
./scripts/healthcheck.sh registry
./scripts/logs.sh registry
```

## Использование

Логин:

```bash
docker login registry.example.com
```

UI:

```text
https://registry-ui.example.com
```

UI использует тот же basic auth, что и сам registry.

Пуш:

```bash
docker tag my-app:1.0.0 registry.example.com/my-app:1.0.0
docker push registry.example.com/my-app:1.0.0
```

## Большие push

Registry доступен через Traefik, поэтому долгие upload-запросы зависят от gateway timeout. В `gateway/docker-compose.yml` для `web` и `websecure` выставлен `readTimeout=10m`, чтобы push больших слоёв не падал на дефолтных 60 секундах Traefik.

Если CI падает примерно через минуту с `499 Client Closed Request` на `PUT /v2/.../blobs/uploads/...`, это обычно не лимит размера registry, а таймаут чтения request body на gateway. После изменения timeout перезапустите gateway:

```bash
make up-gateway
```

Если слой всё ещё загружается дольше 10 минут, лучше сначала уменьшить образ. Бесконечный timeout — это не DevOps, а публичное письмо шантажистам: "держите соединение сколько хотите".

Пул:

```bash
docker pull registry.example.com/my-app:1.0.0
```

## Backup

Для данных registry используйте:

```bash
./scripts/backup-volumes.sh --stack registry
```
