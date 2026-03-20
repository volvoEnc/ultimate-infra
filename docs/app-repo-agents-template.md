# AGENTS.md Template For App Repositories

Скопируйте этот файл в корень application repository и переименуйте в `AGENTS.md`.

Цель: помочь Codex в app repo подготовить сервис так, чтобы его можно было без сюрпризов задеплоить в infra repo `ultimate-home/infra`.

## Deployment Target

Приложение будет деплоиться не своим production compose, а через infra repo:

- ingress: `Traefik` из `gateway/`
- app stack template: `deployments/app-template/`
- shared PostgreSQL: `infra-postgres:5432` через external network `data`
- private registry: домен из infra stack `registry/`
- observability: `Prometheus`, `Loki`, `Grafana`, `Uptime Kuma`

## What Codex Must Optimize For

Codex должен готовить проект под следующие свойства:

- production image запускается в Docker без ручных шагов;
- приложение слушает один HTTP port;
- сервис можно маршрутизировать через Traefik по `Host(...)`;
- healthcheck можно проверить простым HTTP GET из контейнера;
- runtime-конфигурация приходит через env;
- образ публикуется в registry с фиксированным тегом;
- deploy не требует kubernetes, helm, nomad или swarm.

## Hard Runtime Contract

Если Codex меняет код или инфраструктурные файлы app repo, он должен соблюдать эти правила.

### 1. HTTP service

- Приложение обязано слушать `0.0.0.0`, не `127.0.0.1`.
- Порт должен быть конфигурируемым, предпочтительно через `PORT` или аналог.
- В infra repo этот порт попадёт в `APP_PORT`.
- TLS внутри приложения не нужен: HTTPS терминируется в Traefik.
- Не включать собственный forced HTTP->HTTPS redirect без явной необходимости.

### 2. Healthcheck

- Нужен endpoint вроде `/health`, `/healthz` или `/ready`.
- Endpoint должен отвечать `200 OK`, без HTML login page и без редиректов.
- Endpoint должен быть доступен локально внутри контейнера.
- Если image минимальный, Codex должен либо добавить `wget`/`curl`, либо явно сказать, что infra healthcheck надо менять.

### 3. Logging

- Логи только в stdout/stderr.
- Не писать production logs в локальные файлы внутри контейнера.
- Формат JSON допустим, plain text тоже допустим.

### 4. Configuration

- Секреты не хранятся в git.
- Production конфигурация должна быть совместима с env-based runtime config.
- Нельзя требовать ручного редактирования файлов внутри контейнера после запуска.

### 5. Stateful data

- Постоянные данные должны храниться либо во внешней БД/объектном хранилище, либо в выделенном volume.
- Нельзя рассчитывать на ephemeral filesystem контейнера как на основное хранилище.

### 6. Graceful shutdown

- Приложение должно корректно завершаться по `SIGTERM`.
- Долгие фоновые задачи должны завершаться предсказуемо.

### 7. Database contract

- Если приложению нужен PostgreSQL, оно должно уметь работать с host `infra-postgres` и port `5432`.
- Предпочтителен один `DATABASE_URL` или стандартные `PGHOST` / `PGPORT` / `PGUSER` / `PGPASSWORD` / `PGDATABASE`.
- Миграции должны быть идемпотентными.
- Если миграции обязательны, Codex должен вынести их в отдельную команду или чётко описать порядок запуска.

### 8. Background workers and cron

- Если проекту нужны `worker` и/или `cron`, они должны запускаться отдельной командой.
- Допустимо использовать тот же image с разными `CMD`.
- Если worker/cron не нужны, Codex должен явно это отметить в handoff.

### 9. Registry and image tags

- Нельзя использовать `latest` как основной production tag.
- Нужны фиксированные теги: semver, git sha или release tag.
- Image name и registry host не должны быть захардкожены в коде.
- Codex должен подготовить проект к `docker build` и `docker push`.

### 10. Reverse proxy awareness

- Если приложение формирует absolute URLs, оно должно корректно работать за reverse proxy.
- Нужно уважать `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-For`, если это требуется фреймворком.
- WebSocket/SSE допустимы, если идут через тот же HTTP service и порт.

## Expected Deliverables In App Repo

Когда Codex готовит app repo под эту infra, он должен по возможности сделать следующее:

- production `Dockerfile`
- `.dockerignore`
- `.env.example` или эквивалентный список env variables
- health endpoint
- README section `Deployment` или `Production`
- список команд:
  - app start
  - worker start
  - cron start
  - migrations
- если есть CI:
  - build image
  - tag image
  - push image в private registry

## Infra Handoff That Codex Must Produce

В конце работы Codex должен оставить блок, который можно перенести в infra repo при создании stack.

Использовать такой шаблон:

```md
## Infra Handoff

APP_NAME=<service-name>
APP_ENV=<prod|stage>
APP_IMAGE=<registry-host>/<image>:<tag>
WORKER_IMAGE=<registry-host>/<worker-image>:<tag>
CRON_IMAGE=<registry-host>/<cron-image>:<tag>
APP_PORT=<port>
APP_HEALTHCHECK_PATH=</health>
APP_HOST=<public-domain>
APP_URL=https://<public-domain><health-path>
APP_DATA_PATH=<path-inside-container-if-volume-needed>
WORKER_COMMAND=<worker start command or "not used">
CRON_COMMAND=<cron start command or "not used">

Required runtime env:
- KEY=value description
- KEY=value description

Required secrets:
- SECRET_NAME
- SECRET_NAME

Dependencies:
- postgres: yes/no
- redis: yes/no
- object storage: yes/no

Migrations:
- command: <command>
- when to run: <before app start / once per deploy / not required>
```

## Constraints For Codex

Codex в app repo не должен:

- предлагать kubernetes как основной deploy path;
- привязывать production к `docker compose up` внутри app repo как единственному сценарию;
- хранить реальные production secrets в репозитории;
- включать собственный TLS termination в приложении;
- рассчитывать на ручные post-deploy правки контейнера.

## Useful Infra Facts

- Infra app stack template ожидает `APP_IMAGE`, `WORKER_IMAGE`, `CRON_IMAGE`, `APP_PORT`, `APP_HEALTHCHECK_PATH`, `APP_HOST`.
- Infra healthcheck по шаблону использует `wget` внутри app container.
- Shared PostgreSQL доступен как `infra-postgres:5432`.
- Shared Docker Registry работает через отдельный домен и HTTPS.
- Dashboard Traefik и остальные infra services не должны использоваться как runtime dependency приложения.

## Preferred Codex Workflow In App Repo

1. Проверить, можно ли собрать production image без ручных шагов.
2. Добавить или исправить Dockerfile.
3. Проверить runtime env contract.
4. Добавить health endpoint.
5. Проверить bind address и port config.
6. Выделить команды для app / worker / cron / migrations.
7. Подготовить краткий infra handoff.

## Definition Of Done

Проект считается подготовленным к этой infra, если:

- есть production-ready Docker image;
- приложение доступно по одному HTTP port;
- есть рабочий healthcheck;
- env и secrets вынесены из git;
- есть понятный handoff для infra repo;
- Codex может объяснить, как собрать image и какой tag должен попасть в infra `.env`.
