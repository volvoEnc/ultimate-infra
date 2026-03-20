# Bootstrap новой VDS

## 1. Базовая подготовка

- Обновите систему и установите Docker Engine.
- Установите Docker Compose Plugin.
- Добавьте пользователя деплоя в группу `docker`, если не хотите работать под `root`.
- Откройте во firewall минимум `22`, `80`, `443`.

## 2. Клонирование репозитория

```bash
mkdir -p /opt/apps
cd /opt/apps
git clone <your-infra-repo> infra
cd infra
```

## 3. Инициализация структуры

```bash
./scripts/init-server.sh
```

Скрипт:

- проверяет `docker` и `docker compose`;
- создаёт каталоги для `env` и `backups`;
- выставляет базовые права;
- создаёт external network `proxy`.

## 4. Настройка env-файлов

```bash
cp gateway/.env.example gateway/.env
cp observability/.env.example observability/.env
cp admin/.env.example admin/.env
cp uptime/.env.example uptime/.env
```

Заполните домены, логины и пароли, после чего положите реальные app env-файлы в `env/prod` и `env/stage`.

## 5. Docker log rotation

В compose-файлах уже задан `json-file` rotation (`10m` x `5`) для контейнеров infra stack'ов. Дополнительно полезно включить глобальную политику Docker на хосте:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
```

Файл: `/etc/docker/daemon.json`

После изменения:

```bash
sudo systemctl restart docker
```

## 6. Первый запуск

```bash
make up-gateway
make up-observability
make up-admin
make up-uptime
```

После запуска проверьте:

- HTTPS на gateway;
- доступность Grafana и Portainer;
- что Traefik получил сертификаты Let's Encrypt;
- что Prometheus видит `node-exporter`, `cadvisor` и Traefik.
