# PostgreSQL

## Схема

`postgres/` поднимает один shared PostgreSQL instance для приложений на этой VDS.

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

## Как это связано с infra app stack

Шаблон приложения в `deployments/app-template/` уже подключён к external network `data`, поэтому app / worker / cron могут ходить в PostgreSQL напрямую.

Для нового приложения типовой порядок такой:

1. `./scripts/create-postgres-app-db.sh <app> prod`
2. `./scripts/create-postgres-app-db.sh <app> stage`
3. положить выведенные переменные в `env/prod/<app>.env` и `env/stage/<app>.env`
4. задеплоить stack через `./scripts/deploy.sh <app> <env>`
