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

Пул:

```bash
docker pull registry.example.com/my-app:1.0.0
```

## Backup

Для данных registry используйте:

```bash
./scripts/backup-volumes.sh --stack registry
```
