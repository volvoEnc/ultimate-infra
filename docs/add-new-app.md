# Как добавить новое приложение

## 1. Создать stack

```bash
cp -R deployments/app-template deployments/app1-prod
cp deployments/app-template/.env.example deployments/app1-prod/.env
```

Для stage создайте отдельный каталог:

```bash
cp -R deployments/app-template deployments/app1-stage
cp deployments/app-template/.env.example deployments/app1-stage/.env
```

## 2. Подготовить `.env` stack'а

Обязательно задайте:

- `COMPOSE_PROJECT_NAME`
- `APP_NAME`
- `APP_ENV`
- `APP_IMAGE`
- `WORKER_IMAGE`
- `CRON_IMAGE`
- `APP_ENV_FILE`
- `APP_HOST`
- `APP_URL`
- `APP_PORT`
- `DATA_NETWORK`

## 3. Создать реальный env-файл

Пример:

```bash
touch env/prod/app1.env
chmod 600 env/prod/app1.env
```

Добавьте в него секреты и runtime-конфиг приложения.

## 4. Проверить healthcheck

Шаблон ожидает endpoint вроде `/health`. Если приложение использует другой путь или другой способ проверки, поменяйте `APP_HEALTHCHECK_PATH` либо сам блок `healthcheck` в compose.

## 5. Проверить routing

- домен должен указывать на VDS;
- приложение должно быть подключено к сети `proxy`;
- Traefik labels должны ссылаться на правильный `APP_HOST` и `APP_PORT`.

## 6. Если приложению нужен PostgreSQL

- stack приложения должен быть подключён к external network `data`;
- по шаблону это уже сделано через `DATA_NETWORK=data`;
- host базы внутри контейнеров: `infra-postgres`;
- стандартный порт: `5432`;
- реальные `DATABASE_URL` или `PG*` переменные храните в `env/prod/*.env` или `env/stage/*.env`.
- для создания отдельной базы и пользователя используйте `./scripts/create-postgres-app-db.sh <app> <prod|stage>`.

## 7. Задеплоить

```bash
./scripts/deploy.sh app1 prod
./scripts/healthcheck.sh app1 prod
```

## 8. Добавить мониторинг

- создайте monitor в Uptime Kuma;
- откройте Grafana dashboards `Server Overview`, `Docker Containers`, `Traefik Overview`;
- проверьте Loki-запрос `{compose_project="app1-prod"}`.
