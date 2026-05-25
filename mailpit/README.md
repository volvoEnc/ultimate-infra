# Mailpit

`mailpit/` runs Mailpit for SMTP capture with its web UI behind the shared Traefik gateway.

Mailpit SMTP is internal only. It joins the external `data` network and exposes no host ports. The web UI joins `proxy`; Traefik exposes only the UI at `https://<MAILPIT_HOST>/` with Basic Auth.

## Setup

Copy the env example:

```bash
cp mailpit/.env.example mailpit/.env
chmod 600 mailpit/.env
```

Set production values in `mailpit/.env`:

- `MAILPIT_HOST`
- `MAILPIT_MAX_MESSAGES`
- `MAILPIT_UI_BASIC_AUTH_USERS`
- `TZ`

Generate Basic Auth with:

```bash
docker run --rm --entrypoint htpasswd httpd:2 -Bbn admin 'strong-password' | sed 's/\$/$$/g'
```

Use `$$` instead of `$` in `.env` values because Docker Compose interpolates dollar signs.

## Start

```bash
make up-gateway
make up-mailpit
```

Open `https://<MAILPIT_HOST>/`.

## Internal SMTP

Containers on the `data` network can send test email to:

```text
infra-mailpit:1025
```

Typical application settings:

- SMTP host: `infra-mailpit`
- SMTP port: `1025`
- SMTP auth: disabled
- SMTP TLS: disabled

Mailpit stores messages in `mailpit-data` through `MP_DATABASE=/data/mailpit.db` and keeps up to `MAILPIT_MAX_MESSAGES` messages.

## Operations

```bash
./scripts/healthcheck.sh mailpit
./scripts/logs.sh mailpit
./scripts/restart.sh mailpit
```

## Smoke Test

From another container attached to the `data` network, send SMTP to:

```text
infra-mailpit:1025
```

Then open `https://<MAILPIT_HOST>/` and confirm the message appears.

## Backup

```bash
./scripts/backup-volumes.sh --stack mailpit
```

The backup includes `mailpit-data`.
