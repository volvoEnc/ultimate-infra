# Логи, мониторинг и диагностика

## Стек

- `Dozzle` — быстрый просмотр live docker logs.
- `Loki + Promtail` — долговременные логи и поиск.
- `Prometheus` — метрики и alert rules.
- `Grafana` — готовые dashboards и Explore.
- Любой `*.json` в `observability/grafana/dashboards/` подхватывается Grafana автоматически через provisioning.
- `node_exporter` — CPU, RAM, disk, network хоста.
- `cAdvisor` — метрики контейнеров.
- `Uptime Kuma` — внешняя доступность URL.

## Как смотреть логи

### Быстро

Откройте Dozzle и фильтруйте по имени контейнера или stack'а.

### Поиск по истории

В Grafana Explore используйте Loki:

```logql
{compose_project="app1-prod"}
{compose_project="app1-prod", compose_service="worker"}
{container="infra-traefik"}
```

## Какие панели смотреть

### При общей деградации сервера

Откройте `Server Overview`:

- CPU usage
- Memory usage
- Disk usage /
- Network throughput

### При проблемах контейнеров

Откройте `Docker Containers`:

- Restarts in 24h
- Container CPU
- Container memory
- Container network

### При проблемах маршрутизации

Откройте `Traefik Overview`:

- Traefik scrape status
- Requests per second
- Error responses
- Open connections

### При проблемах PostgreSQL

Откройте `PostgreSQL Overview`:

- exporter scrape status
- database size
- active sessions
- connected backends
- transactions rate
- cache hit ratio

## Alert-ready метрики

В Prometheus уже добавлены базовые правила:

- высокий CPU хоста;
- высокая загрузка RAM;
- мало места на корневом диске;
- недавний restart контейнера;
- недоступность Traefik по metrics endpoint;
- высокий CPU конкретного контейнера.

## Что мониторить в Uptime Kuma

- все `prod` URL приложений;
- все `stage` URL приложений;
- Grafana и Dozzle;
- Portainer;
- критичные публичные API или callback endpoints.
