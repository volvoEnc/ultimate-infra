# Flow деплоя приложений

## Общий сценарий

1. В app repo собирается Docker image.
2. Образ публикуется в registry с конкретным тегом.
3. В infra repo обновляется `deployments/<app>-<env>/.env`.
4. На сервере выполняется деплой через infra repo.

## Команда деплоя

```bash
./scripts/deploy.sh app1 prod
```

Скрипт делает:

1. переход в каталог stack'а;
2. `docker compose pull`;
3. `docker compose up -d --remove-orphans`;
4. `docker compose ps`;
5. проверку контейнеров и URL через `healthcheck.sh`.

## Рекомендуемый практический процесс

- Для `stage` деплойте каждый новый тег первым.
- После smoke-test переносите тот же тег в `prod`.
- Не меняйте вручную образы через Portainer, чтобы состояние infra repo оставалось источником правды.

## Откат

Самый простой rollback:

1. вернуть предыдущий тег образа в `.env`;
2. повторно выполнить `./scripts/deploy.sh app1 prod`.

Это проще и надёжнее, чем сложная оркестрация для одной VDS.
