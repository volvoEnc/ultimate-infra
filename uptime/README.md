# Что мониторить в Uptime Kuma

Рекомендуемый минимум для одной VDS:

- `prod` маршруты всех приложений:
  - `https://app1.example.com/health`
  - `https://app2.example.com/health`
- `stage` маршруты:
  - `https://stage-app1.example.com/health`
- инфраструктурные сервисы:
  - `https://grafana.example.com/login`
  - `https://logs.example.com`
  - `https://portainer.example.com`

## Типы monitor'ов

- `HTTP(s)` — основной вариант для приложений и панелей.
- `TCP Port` — полезно для 443, если нужно отделить сетевую проблему от проблемы приложения.
- `Keyword` — если важно проверить содержимое страницы.

## Практический совет

Сначала добавьте `prod`, потом `stage`, и только затем административные панели. Для приложений удобно разделять мониторы по группам: `prod`, `stage`, `infra`.
