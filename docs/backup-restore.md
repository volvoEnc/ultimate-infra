# Backup и restore

## Что бэкапить

Минимальный набор:

- `env/prod` и `env/stage`;
- Docker volumes приложений;
- volume `gateway-letsencrypt`;
- volume `postgres-data`;
- volumes Grafana, Prometheus, Loki и Portainer.

## Как часто

- env-файлы — перед каждым изменением и минимум раз в сутки;
- volumes с данными — ежедневно или чаще, если данные меняются активно;
- перед крупными обновлениями — внеплановый backup.

## Команды

Резервная копия env:

```bash
./scripts/backup-env.sh
```

Резервная копия volumes по stack:

```bash
./scripts/backup-volumes.sh --stack gateway
./scripts/backup-volumes.sh --stack postgres
./scripts/backup-volumes.sh --stack app1 prod
```

Восстановление env:

```bash
./scripts/restore-env.sh backups/env/env-YYYYMMDD-HHMMSS.tar.gz
```

## Проверка, что backup не мусор

- архив должен открываться через `tar -tzf`;
- внутри должны быть ожидаемые env-файлы или данные volume;
- после тестового восстановления проверяйте права доступа;
- после restore запускайте `./scripts/healthcheck.sh`.

## Практика восстановления

1. остановите затронутый stack;
2. восстановите env или volume;
3. задеплойте stack заново;
4. проверьте URL и контейнеры;
5. посмотрите логи в Dozzle или Grafana.
