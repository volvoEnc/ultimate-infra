# Infra repo для одной VDS

Репозиторий предназначен для управления инфраструктурой одной Linux VDS, на которой запускаются несколько Docker-приложений в окружениях `prod` и `stage` без Kubernetes.

## Состав

- `gateway/` — отдельный stack с Traefik, HTTPS, Let's Encrypt и общими middleware.
- `postgres/` — общий PostgreSQL stack для приложений на этой VDS, включая `Adminer` web UI.
- `registry/` — приватный Docker Registry с HTTPS через Traefik и `htpasswd` auth.
- `observability/` — Loki, Promtail, Prometheus, Grafana, node_exporter и cAdvisor.
- `admin/` — Portainer и Dozzle для оперативного управления и просмотра логов.
- `uptime/` — Uptime Kuma для внешних healthchecks и мониторинга доступности.
- `centrifugo/` — Centrifugo для realtime/WebSocket, с публичным endpoint через Traefik и внутренними `/api`, `/health`, `/metrics`.
- `n8n/` — self-hosted workflow automation через Traefik и shared PostgreSQL.
- `deployments/app-template/` — шаблон приложения с `app`, `worker`, `cron`, `env_file`, healthcheck и Traefik labels.
- `env/` — каталог для реальных env-файлов по окружениям, без коммита в git.
- `scripts/` — bash-скрипты для инициализации сервера, деплоя, логов и резервных копий.
- `docs/` — эксплуатационная документация по bootstrap, deploy flow, env и backup/restore.

## Быстрый старт

1. Установите Docker Engine и Docker Compose Plugin по официальной инструкции для вашей Linux-дистрибуции.
2. Склонируйте репозиторий на сервер, например в `/opt/apps/infra`.
3. Запустите базовую инициализацию:

   ```bash
   ./scripts/init-server.sh
   ```

4. Скопируйте примеры переменных окружения:

   ```bash
   cp gateway/.env.example gateway/.env
   cp postgres/.env.example postgres/.env
   cp registry/.env.example registry/.env
   cp observability/.env.example observability/.env
   cp admin/.env.example admin/.env
   cp uptime/.env.example uptime/.env
   cp centrifugo/.env.example centrifugo/.env
   cp n8n/.env.example n8n/.env
   ```

5. Если нужен приватный Registry, создайте `htpasswd` файл, например:

   ```bash
   mkdir -p env/prod
   docker run --rm --entrypoint htpasswd httpd:2 -Bbn registry change-me > env/prod/registry.htpasswd
   chmod 600 env/prod/registry.htpasswd
   ```

6. Заполните реальные env-файлы приложений в `env/prod` и `env/stage`.
7. Если нужен n8n, перед запуском `make up-n8n` создайте отдельную PostgreSQL базу и пользователя:

   ```bash
   make up-postgres
   ./scripts/create-postgres-app-db.sh n8n prod
   ```

   Затем перенесите выведенные значения БД в `n8n/.env`: `DB_POSTGRESDB_DATABASE`, `DB_POSTGRESDB_USER` и `DB_POSTGRESDB_PASSWORD`.

8. Поднимите gateway и наблюдаемость:

   ```bash
   make up-gateway
   make up-postgres
   make up-registry
   make up-observability
   make up-admin
   make up-uptime
   make up-centrifugo
   make up-n8n
   ```

   Если запускаете stack вручную не из его каталога, передавайте `--env-file`, например:

   ```bash
   docker compose --env-file gateway/.env -f gateway/docker-compose.yml up -d
   ```

   После `make up-postgres` UI PostgreSQL будет доступен по `https://<ADMINER_HOST>/`.
   После `make up-n8n` n8n будет доступен по `https://<N8N_HOST>/`.

9. Скопируйте шаблон приложения:

   ```bash
   cp -R deployments/app-template deployments/app1-prod
   cp deployments/app-template/.env.example deployments/app1-prod/.env
   ```

10. Отредактируйте `deployments/app1-prod/.env`, создайте `env/prod/app1.env` и выполните деплой:

   ```bash
   make deploy APP=app1 ENV=prod
   ```

## Схема директорий на сервере

Базовый и самый простой вариант — хранить всё внутри клона репозитория:

```text
/opt/apps/infra
/opt/apps/infra/deployments/app1-prod
/opt/apps/infra/deployments/app1-stage
/opt/apps/infra/env/prod
/opt/apps/infra/env/stage
/opt/apps/infra/backups
```

Если удобнее, `deployments/` и `env/` можно вынести рядом с репозиторием, но тогда обновите пути в `.env` конкретных stack'ов.

## Flow деплоя

1. Приложение собирается в своём app repo.
2. Образ публикуется в registry с фиксированным тегом.
3. На сервере infra repo хранит compose-файл, env и routing labels.
4. Деплой выполняется командой:

   ```bash
   docker compose pull
   docker compose up -d --remove-orphans
   ```

5. Скрипт `./scripts/deploy.sh app1 prod` делает эти шаги автоматически и затем запускает healthcheck.

## Как смотреть логи

- Быстрый просмотр: Dozzle из stack `admin`.
- Поиск и история: Grafana Explore + Loki.
- Примеры запросов в Loki:

  ```logql
  {compose_project="app1-prod"}
  {compose_project="app1-prod", compose_service="app"}
  ```

- CLI:

  ```bash
  ./scripts/logs.sh app1 prod
  ./scripts/logs.sh app1 prod worker
  ./scripts/logs.sh gateway
  ```

## Как добавить новое приложение

1. Скопируйте `deployments/app-template` в `deployments/<app>-<env>`.
2. Скопируйте `.env.example` в `.env` и задайте образ, домен, env-файл и health endpoint.
3. Создайте реальный env-файл в `env/prod/<app>.env` или `env/stage/<app>.env`.
4. Проверьте, что приложение слушает `APP_PORT` и корректно отвечает на `APP_HEALTHCHECK_PATH`.
5. Запустите `make deploy APP=<app> ENV=<env>`.
6. Добавьте внешний monitor в Uptime Kuma и проверьте дашборды Grafana.

Подробности — в `docs/add-new-app.md`.

## Compose conventions

- Везде используется `restart: unless-stopped`.
- Для данных применяются именованные volumes.
- Для всех инфраструктурных stack'ов включён Docker log rotation через `json-file`.
- Gateway и приложения подключаются к общей external network `proxy`.
- Приложения и PostgreSQL подключаются к общей external network `data`.
- n8n использует отдельную PostgreSQL базу в shared `infra-postgres` и named volume `n8n-data`.
- Приватные сервисы общаются по внутренним сетям stack'ов.
- Секреты не захардкожены и не хранятся в git.

## Traefik notes

- Dashboard открывается по `https://<TRAEFIK_DASHBOARD_HOST>/dashboard/`.
- Для первой выдачи сертификата через Cloudflare используйте `SSL/TLS: Full`; после выпуска origin-сертификата можно переключить на `Full (strict)`.
- Если Cloudflare proxy мешает bootstrap TLS, временно включите `DNS only` для dashboard host.

## Основные команды

```bash
make up-gateway
make up-postgres
make up-registry
make up-observability
make up-admin
make up-uptime
make up-centrifugo
make up-n8n
make deploy APP=app1 ENV=prod
make logs APP=app1 ENV=prod
make status
./scripts/backup-env.sh
./scripts/backup-volumes.sh --stack app1 prod
```

## Полезные документы

- `docs/server-bootstrap.md`
- `docs/deploy-flow.md`
- `docs/add-new-app.md`
- `docs/postgres.md`
- `docs/app-repo-agents-template.md`
- `docs/env-management.md`
- `docs/backup-restore.md`
- `docs/observability.md`
- `centrifugo/README.md`
- `n8n/README.md`
