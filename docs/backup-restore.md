# Backup и restore

## Что бэкапить

Минимальный набор:

- `env/prod` и `env/stage`;
- Docker volumes приложений;
- volume `gateway-letsencrypt`;
- volume `postgres-data`;
- volume `registry-data`;
- volume `n8n-data` plus the dedicated n8n PostgreSQL database;
- volumes `clickhouse-data`, `clickhouse-logs` и `clickhouse-ui-data`;
- volume `kafka-data`;
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
./scripts/backup-volumes.sh --stack registry
./scripts/backup-volumes.sh --stack n8n
./scripts/backup-volumes.sh --stack clickhouse
./scripts/backup-volumes.sh --stack kafka
./scripts/backup-volumes.sh --stack app1 prod
```

Резервная копия базы n8n в shared PostgreSQL:

```bash
mkdir -p backups/postgres
docker compose --env-file postgres/.env -f postgres/docker-compose.yml exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d n8n_prod -Fc' > backups/postgres/n8n_prod.dump
```

Восстановление env:

```bash
./scripts/restore-env.sh backups/env/env-YYYYMMDD-HHMMSS.tar.gz
```

Восстановление базы n8n из dump:

```bash
docker compose --env-file postgres/.env -f postgres/docker-compose.yml exec -T postgres sh -c 'pg_restore -U "$POSTGRES_USER" -d n8n_prod --clean --if-exists' < backups/postgres/n8n_prod.dump
```

## Проверка, что backup не мусор

- архив должен открываться через `tar -tzf`;
- внутри должны быть ожидаемые env-файлы или данные volume;
- после тестового восстановления проверяйте права доступа;
- после restore запускайте `./scripts/healthcheck.sh`.

Для n8n backup volume не заменяет backup PostgreSQL: workflows, credentials и executions хранятся в выделенной базе shared PostgreSQL. Перед обновлениями n8n сохраняйте `n8n-data`, env и dump базы через `pg_dump`; один volume backup недостаточен для восстановления n8n.

## Практика восстановления

1. остановите затронутый stack;
2. восстановите env или volume;
3. задеплойте stack заново;
4. проверьте URL и контейнеры;
5. посмотрите логи в Dozzle или Grafana.
