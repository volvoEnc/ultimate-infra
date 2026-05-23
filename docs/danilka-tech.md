# danilka.tech Production Deployment

`danilka.tech` деплоится как обычное app-only приложение через Traefik, shared PostgreSQL и private Docker Registry.

## Server Preparation

Создайте stack env из примера:

```bash
cp deployments/danilka-tech-prod/.env.example deployments/danilka-tech-prod/.env
```

Создайте runtime env приложения:

```bash
cp env/prod/danilka-tech.env.example env/prod/danilka-tech.env
chmod 600 env/prod/danilka-tech.env
```

Создайте БД и пользователя в shared PostgreSQL:

```bash
make up-postgres
./scripts/create-postgres-app-db.sh danilka-tech prod
```

Перенесите выведенный `DATABASE_URL` в `env/prod/danilka-tech.env`.

## GitHub Actions Variables

Для repository или environment `Build` в `danilka.tech` задайте:

```text
DOCKER_REGISTRY=<registry-host>
DOCKER_IMAGE_NAMESPACE=<namespace>
DOCKER_PLATFORMS=linux/amd64
DEPLOY_PATH=/opt/apps/infra
DEPLOY_COMPOSE_FILE=deployments/danilka-tech-prod/docker-compose.yml
DEPLOY_ENV_FILE=deployments/danilka-tech-prod/.env
DEPLOY_IMAGE_VAR_NAME=APP_IMAGE
DEPLOY_MIGRATION_COMMAND=prisma migrate deploy
DEPLOY_SERVICE_NAME=app
DEPLOY_HEALTHCHECK_COMMAND=./scripts/healthcheck.sh danilka-tech prod
```

Если VDS лежит в другом каталоге, замените `DEPLOY_PATH`. Не превращайте это в археологию с двумя infra-клонами.

## GitHub Actions Secrets

```text
DEPLOY_HOST=<server-host>
DEPLOY_PORT=22
DEPLOY_USER=<ssh-user>
DEPLOY_SSH_KEY=<private-ssh-key>
REGISTRY_USERNAME=<registry-user>
REGISTRY_PASSWORD=<registry-password>
```

## Deploy Flow

На `push` в `master` workflow приложения:

1. запускает проверки;
2. собирает Docker image;
3. публикует image с тегом `sha-<commit>`;
4. обновляет `APP_IMAGE` в `deployments/danilka-tech-prod/.env` на сервере;
5. выполняет `prisma migrate deploy`;
6. перезапускает `app`;
7. запускает `./scripts/healthcheck.sh danilka-tech prod`.
