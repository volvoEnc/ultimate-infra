# OpenClaw

Personal AI chat assistant ([OpenClaw](https://openclaw.ai)) on Telegram, deployed as a
hardened "chat in a jail" infra stack. The control UI is reachable from the public internet
but is gated behind Authelia (password + TOTP).

## Security posture (v1)

- Container is on a **dedicated `openclaw-edge`** bridge shared only with Traefik — **not**
  on the public `proxy` net and **not** on `data` (cannot reach any prod DB).
- No host access: no docker.sock, no host binds, not privileged, `cap_drop: ALL`,
  `no-new-privileges`, `mem/cpu/pids` limits.
- Browser automation disabled; `agents.defaults.sandbox.mode: off` (the container itself
  is the jail). Full-host-access escalation is deferred — see the design spec §9.

## Prerequisites

- `gateway` (Traefik ≥ v3.6.14) and `authelia` stacks are up.
- A DNS record for `OPENCLAW_HOST` pointing at the server, sharing a root domain with the
  Authelia portal host (so the session cookie spans both).

## Setup

```bash
cp openclaw/.env.example openclaw/.env && chmod 600 openclaw/.env
# Edit openclaw/.env: OPENCLAW_HOST, OPENCLAW_GATEWAY_TOKEN (openssl rand -hex 32),
# TELEGRAM_BOT_TOKEN (@BotFather), TELEGRAM_OWNER_ID (numeric id from @userinfobot),
# and pin OPENCLAW_IMAGE to a current release.
```

## Seed the Claude subscription (one-time, REQUIRED)

The model uses a reused Claude **subscription** (not a metered API key). The OAuth token is
**not** injectable via env — it must be seeded once into the `openclaw-data` volume. Until
then the bot starts but every Claude call fails with an auth error.

```bash
make onboard-openclaw     # interactive: choose the Anthropic setup-token / paste-token flow
```

Claude-CLI reuse will not work here (no host `~/.claude` is mounted) — use the
setup-token / paste-token flow. The credential lands in
`~/.openclaw/agents/<id>/agent/auth-profiles.json` inside `openclaw-data`.

## Start

```bash
make up-openclaw
```

## Verify (acceptance smoke tests)

- `https://<OPENCLAW_HOST>/` with no session → redirects to the Authelia portal.
- Login requires password **and** TOTP; skipping TOTP is blocked.
- Sending the bot one Telegram message (from `TELEGRAM_OWNER_ID`) returns a Claude reply.
- `docker ps` shows **no** host port mapping for `infra-openclaw` (only Traefik maps 80/443).
- `docker inspect infra-openclaw` → networks = `openclaw-edge` only (not `proxy`/`data`),
  `Privileged=false`, `CapDrop=ALL`, no docker.sock mount.
- Add an Uptime-Kuma HTTP monitor (GUI) for the UI host and confirm it is green.

## Backup

```bash
./scripts/backup-volumes.sh --stack openclaw
```

The `openclaw-data` archive contains the live Claude token — treat `backups/` as sensitive.
The token is also re-creatable: if a backup is compromised, revoke the session and re-run
`make onboard-openclaw`.
