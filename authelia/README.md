# Authelia

Forward-auth provider that gates admin UIs with **password + TOTP (2FA)** via its login
portal. Reusable across stacks through the `authelia@file` Traefik middleware. Introduced to
front the OpenClaw UI without the (conflict-prone) Traefik basic-auth layer.

## Prerequisites

- `redis` stack is up (Authelia reuses `infra-redis` for sessions, on DB index **2**).
- Traefik pinned to **≥ v3.6.14** (CVE-2026-35051 forwardAuth bypass — already set in
  `gateway/docker-compose.yml`).
- Portal host (`AUTHELIA_HOST`, e.g. `auth.<domain>`) shares a **root domain** with every
  protected app (e.g. `openclaw.<domain>`) so the session cookie spans both.

## Setup

```bash
cp authelia/.env.example authelia/.env && chmod 600 authelia/.env
# Generate each secret:
#   docker run --rm authelia/authelia:4.39.5 authelia crypto rand --length 64 --charset alphanumeric
# Fill AUTHELIA_SESSION_SECRET, AUTHELIA_STORAGE_ENCRYPTION_KEY, AUTHELIA_JWT_SECRET,
# and REDIS_PASSWORD (must equal redis/.env). Set AUTHELIA_HOST + pin AUTHELIA_IMAGE.

# Edit authelia/config/configuration.yml: set the session cookie domain/authelia_url/
# default_redirection_url and totp.issuer for your real domain.

# Create the (gitignored) users database with a real password hash:
cp authelia/config/users.yml.example authelia/config/users.yml
docker run --rm authelia/authelia:4.39.5 \
  authelia crypto hash generate argon2 --password 'your-strong-password'
# paste the resulting hash into authelia/config/users.yml
```

## Start

```bash
make up-authelia
```

The `authelia@file` + `openclaw-rate-limit` middlewares already live in
`gateway/dynamic/middlewares.yml`; Traefik hot-reloads the file provider (no restart).

## Enroll TOTP (one-time per user, REQUIRED)

`access_control.default_policy: two_factor` forces 2FA, so each user must enroll an
authenticator before they can pass. The enrollment confirmation link is delivered by the
**filesystem notifier**:

```bash
# Log in at https://<AUTHELIA_HOST> with the password, click "Register device", then:
docker run --rm -v authelia-data:/data alpine cat /data/notification.txt
# open the link from that file to finish enrolling the authenticator app
```

(Alternatively switch `notifier` to SMTP pointed at the existing `infra-mailpit` and read
the link in the Mailpit UI.)

## Backup

```bash
./scripts/backup-volumes.sh --stack authelia
```

`authelia-data` holds the SQLite DB and TOTP secrets — treat `backups/` as sensitive.
