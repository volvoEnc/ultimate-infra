# Шаблон deployment stack

Этот шаблон показывает минимально практичную структуру одного приложения в одном окружении.

## Что входит

- `app` — основной HTTP/WebSocket сервис за Traefik.
- `worker` — фоновый обработчик очередей или jobs.
- `cron` — отдельный контейнер для расписаний.
- `env_file` — путь к реальному env-файлу вне git.
- именованный volume для данных приложения.
- healthcheck для основного сервиса.

## Как использовать

1. Скопируйте каталог:

   ```bash
   cp -R deployments/app-template deployments/app1-prod
   cp deployments/app-template/.env.example deployments/app1-prod/.env
   ```

2. Заполните `deployments/app1-prod/.env`.
3. Создайте реальный env-файл, например `env/prod/app1.env`.
4. Проверьте образ, порт и health endpoint.
5. Выполните:

   ```bash
   ./scripts/deploy.sh app1 prod
   ```

## Важные заметки

- `APP_IMAGE`, `WORKER_IMAGE` и `CRON_IMAGE` должны быть зафиксированы на конкретных тегах, не `latest`.
- Значение `APP_ENV_FILE` указывает на реальный env-файл и должно существовать на сервере.
- Healthcheck использует `wget`, поэтому базовый образ приложения должен содержать `wget` или проверку нужно заменить на подходящую для сервиса.
- Если приложению нужен общий PostgreSQL stack, используйте host `infra-postgres:5432` и оставьте `DATA_NETWORK=data`.
- Для сервисов только внутреннего доступа достаточно убрать Traefik labels и сеть `proxy`.
