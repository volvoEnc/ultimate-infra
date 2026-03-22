# PostgreSQL

## Схема

`postgres/` поднимает один shared PostgreSQL instance для приложений на этой VDS.

В этот же stack входит `pgAdmin` для web-управления PostgreSQL через Traefik.

Рекомендуемая модель:

- одна app database на одно приложение и одно окружение;
- один database user на одну app database;
- отдельные базы для `prod` и `stage`.

Пример:

- `billing_prod`
- `billing_stage`

Используйте `_`, а не `-`.
Имена с дефисами в PostgreSQL работают, но создают лишние проблемы с quoting в SQL и tooling.

## Как создать БД и пользователя для приложения

Поднимите PostgreSQL:

```bash
make up-postgres
```

Создайте ресурсы для `prod`:

```bash
./scripts/create-postgres-app-db.sh billing prod
```

Создайте ресурсы для `stage`:

```bash
./scripts/create-postgres-app-db.sh billing stage
```

Скрипт:

- создаёт role `billing_prod` / `billing_stage`;
- создаёт database `billing_prod` / `billing_stage`;
- назначает владельца;
- печатает готовый `DATABASE_URL` и `PG*` переменные.

Если хотите задать пароль вручную:

```bash
./scripts/create-postgres-app-db.sh billing prod 'strong-password'
```

## Как подключать приложение

Из app containers используйте:

- host: `infra-postgres`
- port: `5432`

Пример:

```env
DATABASE_URL=postgresql://billing_prod:secret@infra-postgres:5432/billing_prod?sslmode=disable
```

или:

```env
PGHOST=infra-postgres
PGPORT=5432
PGDATABASE=billing_prod
PGUSER=billing_prod
PGPASSWORD=secret
```

Эти значения храните в:

- `env/prod/<app>.env`
- `env/stage/<app>.env`

## Web UI

`pgAdmin` поднимается в том же stack и доступен по:

`https://<PGADMIN_HOST>/`

Нужные переменные лежат в `postgres/.env`:

```env
PGADMIN_HOST=pgadmin.example.com
PGADMIN_DEFAULT_EMAIL=admin@example.com
PGADMIN_DEFAULT_PASSWORD=change-me-now
```

После первого запуска в `pgAdmin` автоматически появится сервер `Shared PostgreSQL`, уже настроенный на контейнер `infra-postgres`.

Важно:

- server definitions импортируются только на первом старте `pgAdmin`, пока пуст `postgres-pgadmin-data`;
- если меняете `POSTGRES_DB` или `POSTGRES_USER` уже после первого запуска, старую `pgAdmin` конфигурацию нужно либо поправить в UI, либо пересоздать volume `postgres-pgadmin-data`.

Быстрый запуск:

```bash
cp postgres/.env.example postgres/.env
make up-postgres
```

После входа в `pgAdmin` используйте:

- email: `PGADMIN_DEFAULT_EMAIL`
- password: `PGADMIN_DEFAULT_PASSWORD`

Для подключения к конкретной app database можно:

- открыть уже импортированный `Shared PostgreSQL`, если ваш `POSTGRES_USER` имеет доступ;
- или добавить отдельный server/connection с `host=infra-postgres` и app-specific учёткой вроде `billing_prod`.

## Как это связано с infra app stack

Шаблон приложения в `deployments/app-template/` уже подключён к external network `data`, поэтому app / worker / cron могут ходить в PostgreSQL напрямую.

Для нового приложения типовой порядок такой:

1. `./scripts/create-postgres-app-db.sh <app> prod`
2. `./scripts/create-postgres-app-db.sh <app> stage`
3. положить выведенные переменные в `env/prod/<app>.env` и `env/stage/<app>.env`
4. задеплоить stack через `./scripts/deploy.sh <app> <env>`
