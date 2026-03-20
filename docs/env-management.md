# Управление env и секретами

## Базовый принцип

В git — только `*.env.example`. На сервере — реальные `.env` с ограниченными правами доступа.

## Что где хранить

- stack-level `.env` в каталогах вроде `gateway/.env`, `deployments/app1-prod/.env`;
- application secrets в `env/prod/*.env` и `env/stage/*.env`.

Такой разделённый подход удобен:

- stack `.env` хранит routing, image tags, пути и технические настройки;
- real app env хранит секреты, DSN, API keys и runtime config.

## Права доступа

Рекомендация по умолчанию:

```bash
chmod 600 env/prod/*.env
chmod 600 env/stage/*.env
```

Если на сервере несколько пользователей:

- создайте группу `deploy`;
- выставьте `chgrp deploy env/prod/*.env`;
- используйте `chmod 640`.

## Ротация секретов

1. обновите секрет в env-файле;
2. сделайте backup через `./scripts/backup-env.sh`;
3. перезапустите или задеплойте нужный stack;
4. проверьте `./scripts/healthcheck.sh`.

## Путь развития

Если появится потребность хранить секреты в git безопасно, самый прагматичный следующий шаг — `sops`. Если понадобится централизованная доставка на несколько серверов — `ansible-vault`.
