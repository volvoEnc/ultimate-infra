# PostgreSQL

## Схема

`postgres/` поднимает один shared PostgreSQL instance для приложений на этой VDS.

В этот же stack входит `Adminer` для web-управления PostgreSQL через Traefik.

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

`Adminer` поднимается в том же stack и доступен по:

`https://<ADMINER_HOST>/`

Нужные переменные лежат в `postgres/.env`:

```env
ADMINER_HOST=postgres.example.com
ADMINER_BASIC_AUTH_USERS=admin:$$apr1$$...
```

`Adminer` проще: он не хранит отдельный каталог server definitions и сразу открывает форму подключения к `infra-postgres`.

Быстрый запуск:

```bash
cp postgres/.env.example postgres/.env
make up-postgres
```

После открытия UI сначала сработает HTTP Basic Auth из Traefik:

- login/password берутся из `ADMINER_BASIC_AUTH_USERS`

Дальше в форме Adminer используйте уже PostgreSQL credentials:

- System: `PostgreSQL`
- Server: `infra-postgres`
- Username: например `billing_prod`
- Password: пароль пользователя БД
- Database: например `billing_prod`

Если хотите войти суперпользователем stack'а:

- Username: `POSTGRES_USER`
- Password: `POSTGRES_PASSWORD`
- Database: `POSTGRES_DB`

## Как это связано с infra app stack

Шаблон приложения в `deployments/app-template/` уже подключён к external network `data`, поэтому app / worker / cron могут ходить в PostgreSQL напрямую.

Для нового приложения типовой порядок такой:

1. `./scripts/create-postgres-app-db.sh <app> prod`
2. `./scripts/create-postgres-app-db.sh <app> stage`
3. положить выведенные переменные в `env/prod/<app>.env` и `env/stage/<app>.env`
4. задеплоить stack через `./scripts/deploy.sh <app> <env>`
