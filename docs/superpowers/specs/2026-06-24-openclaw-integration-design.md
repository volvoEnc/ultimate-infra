# Design Spec: OpenClaw Integration (v1 — "Chat in a Jail")

**Repo:** `/Users/danilka/Code/ultimate-home/infra`
**Status:** Design only. No code in this document is final; snippets are illustrative.
**Author context:** Single-operator homelab, single Linux VDS, docker-compose only. Traefik v3.6, Let's Encrypt, Loki/Promtail/Prometheus/Grafana/Uptime-Kuma already in place.

---

## 1. Goal & Non-Goals

### Goal (v1)
Run **OpenClaw** (github.com/openclaw/openclaw — Node.js autonomous personal AI agent) as a **personal chat assistant**, with **Telegram as the only active channel**. The OpenClaw control UI is reachable from the public internet (no VPN) but is hard-gated behind Traefik → Authelia forward-auth (TOTP 2FA) → Traefik basic-auth. The LLM backend reuses an existing **Claude subscription** via Claude CLI / Anthropic OAuth token (not a metered API key).

The design principle for v1 is **"chat in a jail" (Approach A)**: the container can talk to Anthropic and Telegram and nothing else of value. A prompt-injected or jailbroken agent must have a near-empty blast radius.

### In scope (v1)
- One `openclaw` docker-compose stack, container `infra-openclaw`, image from OpenClaw's official Dockerfile/compose.
- Net-new **Authelia** stack (forward-auth, file-based single user, TOTP, Redis session store, sqlite storage), deployed as its own stack and reusable by other admin UIs.
- A reusable Traefik forward-auth middleware in `gateway/dynamic/middlewares.yml`.
- Telegram channel (long-poll; **no public inbound webhook required**).
- Hard resource caps, capability drop, no host access, off the `data` network, Chromium/browser automation disabled.
- Observability hookup (Promtail labels, Uptime-Kuma monitor, Loki query).
- Backups for app state, with the credentials volume handled carefully.

### Non-goals / explicitly deferred to a later version
- **No host access** in v1: no `docker.sock`, no host bind-mounts of code/fs, no `privileged`, no `pid: host`, no `cap_add`.
- **Not on the `data` network**: OpenClaw cannot reach `infra-postgres`, `infra-redis`, ClickHouse, Kafka, etc.
- **Chromium / Playwright browser automation disabled** in v1 (heavy + large attack surface).
- **Channels other than Telegram** (Slack, email, web, etc.) — tested later, not wired in v1.
- **"Full host access" ceiling** (OpenClaw `main` session with bash/exec/fs against the host) — deferred, not foreclosed. A clean opt-in path is documented in §9, gated behind a separate privileged executor container with `profiles: [escalated]`, off by default.
- No CI/lint changes (repo has none); single-operator manual deploy via existing Makefile/scripts.

---

## 2. Architecture Overview

### Containers
| Container | Stack | Networks | Purpose |
|---|---|---|---|
| `infra-openclaw` | `openclaw/` | `openclaw-edge` only | OpenClaw gateway + control UI (port 18789), Telegram long-poll. Dedicated edge net shared only with Traefik — not on public `proxy`, not on `data`. |
| `infra-openclaw-init` | `openclaw/` | none | One-shot root chown of the state volume (uid 1000) before the main container starts |
| `infra-authelia` | `authelia/` | `proxy` + `data` | Forward-auth provider, TOTP 2FA, session store in Redis |
| `infra-traefik` (existing) | `gateway/` | `proxy` | Edge TLS, routing, middleware chains |
| `infra-redis` (existing) | `redis/` | `data` | Reused by Authelia for session storage |

Key asymmetry: **Authelia is infra and may touch `data`** (to reach `infra-redis`). **OpenClaw stays OFF `data`** — it is an untrusted-ish workload and must never reach prod DBs, even though its own auth gate (Authelia) does.

### Networks
- `proxy` (external, public-facing) — OpenClaw and Authelia both join this so Traefik can route to them.
- `data` (external, flat bridge with stable DNS aliases) — **Authelia only**; OpenClaw is deliberately excluded.
- OpenClaw does **not** create a `backend` network in v1 (it is a single container with no sidecars). When the deferred escalated executor is added (§9), it gets its own private `openclaw-escalated` network shared only between OpenClaw and the executor — never `data`.

### Volumes
| Volume name | Mount | Contents | Backup policy |
|---|---|---|---|
| `openclaw-data` | `~/.openclaw` (writable) | workspace, `openclaw.json`, skills, AGENTS.md/SOUL.md/TOOLS.md, **and `auth-profiles.json` (live Claude token — writable, auto-refreshed)** | Backed up via `backup-volumes.sh` — backup WILL contain the token; store backups securely |
| `authelia-data` | `/config` or `/data` | sqlite storage db, notifications | Backed up via `backup-volumes.sh` |

### Exposure path (ASCII)

```
                          Internet (no VPN)
                                 │  HTTPS :443
                                 ▼
                    ┌────────────────────────────┐
                    │   infra-traefik (gateway)   │   entrypoint: websecure
                    │   Let's Encrypt: letsencrypt│   TLS options: default
                    └──────────────┬──────────────┘
   router rule: Host(`OPENCLAW_HOST`)
   middlewares (in order):
     1. ui-chain@file            → security-headers + compression
     2. openclaw-rate-limit@file → tightened rate-limit (lower than ui-rate-limit)
     3. authelia@file            → forward-auth: password + TOTP ── ForwardAuth ─┐
                                 │   (portal/cookie flow; NO Traefik basic-auth   │
                                 │    layered — see §4 auth-model note)           ▼
                                 │                            ┌────────────────────────┐
                                 │                            │  infra-authelia        │
                                 │                            │  (proxy + data)        │
                                 │                            │   ├─ pwd + TOTP verify  │
                                 │                            │   └─ session → redis ──▶ infra-redis (data, DB 2)
                                 │   (only if Authelia password + TOTP pass)
                                 ▼
                    ┌────────────────────────────┐
                    │   infra-openclaw  :18789    │   networks: proxy ONLY
                    │   gateway.bind: lan         │   gateway.auth ON (3rd layer)
                    │   cap_drop: ALL             │   NOT on data → cannot reach prod DBs
                    │   no-new-privileges         │   Chromium OFF (not installed)
                    │   mem 2G / cpus / pids cap  │
                    │   ~/.openclaw (rw vol,      │   token auto-refreshes → MUST be rw
                    │     incl. auth-profiles)    │
                    └───────┬──────────────┬──────┘
                            │              │
            outbound HTTPS  │              │  outbound HTTPS (long-poll)
                            ▼              ▼
                     api.anthropic.com   api.telegram.org
                  (Claude subscription)  (Telegram Bot — NO public inbound)
```

The UI is protected by **Authelia (first factor = password, second factor = TOTP)** via its portal/cookie flow, plus **OpenClaw's own built-in gateway auth** as a third defense-in-depth layer. (The earlier plan to *also* layer a Traefik `basicauth` middleware is dropped — see the §4 auth-model note: stacking it with Authelia collides on the `Authorization`/`WWW-Authenticate` challenge. Authelia's password factor already replaces basic-auth.) Telegram uses **long-poll**, so there is **no public inbound** route for the bot — only the human UI is exposed.

---

## 3. File / Directory Layout to Add

Follow the existing one-dir-per-stack convention. Describe, do not finalize.

```
openclaw/
  docker-compose.yml        # service infra-openclaw; proxy network only; caps; env_file=env/prod/openclaw.env
  .env.example              # routing/image/port only (committed); real .env is gitignored

authelia/
  docker-compose.yml        # service infra-authelia; proxy + data; env_file=env/prod/authelia.env
  .env.example              # routing/image/host only
  config/
    configuration.yml       # Authelia main config (TOTP, session->redis, sqlite storage, access control)
    users_database.yml      # file-based single user (hashed password); chmod 600, gitignored or example-only

env/prod/
  openclaw.env              # chmod 600, gitignored — Telegram bot token, OpenClaw runtime secrets
  authelia.env              # chmod 600, gitignored — JWT secret, session secret, storage encryption key,
                            #                          Redis password, TOTP issuer, notifier config

gateway/dynamic/
  middlewares.yml           # ADD: authelia@file (forwardAuth), openclaw-rate-limit (tightened)
```

Notes on each:
- **Env convention (corrected to repo reality):** OpenClaw and Authelia are **infra stacks**, so — like `redis`/`centrifugo` — secrets live in the stack's **own gitignored `.env`** (committed `.env.example` with `change-me`), NOT in `env/prod/` (that split is for app deployments). `openclaw/.env` holds `COMPOSE_PROJECT_NAME=openclaw` (bare, matching siblings), `TZ`, `OPENCLAW_IMAGE`, `OPENCLAW_HOST`, `OPENCLAW_GATEWAY_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_OWNER_ID`. No Traefik basic-auth var (basic-auth dropped per §4).
- `env/prod/openclaw.env` holds the Telegram bot token and any OpenClaw runtime config that is sensitive. Wired into compose via `env_file: [ env/prod/openclaw.env ]` exactly like `app-template` (`${APP_ENV_FILE}`).
- `authelia/config/users_database.yml` and `configuration.yml` should be committed only as `.example` variants if they contain no secrets; the real `users_database.yml` (with the password hash) and all true secrets live in `env/prod/authelia.env` (referenced by `${...}` in `configuration.yml`) and are `chmod 600` + gitignored. `.gitignore` already covers `env/**/*.env` and `**/.env`.
- Do **not** publish any raw host port (no `ports:` for either service except Traefik's existing `80/443`). The UI is reached only through Traefik.

---

## 4. Networking & Exposure

### Why OpenClaw is NOT on `data`
The `data` network is a flat bridge with **no per-client DB auth** — any container on it can reach `infra-postgres`, `infra-redis`, ClickHouse, Kafka by DNS alias with no further credentials. OpenClaw runs untrusted, model-driven, prompt-injectable code. Placing it on `data` would hand a jailbroken agent direct, unauthenticated access to every production datastore. Therefore OpenClaw joins a **dedicated `openclaw-edge` bridge shared only with Traefik** — NOT the shared public `proxy` net (so no other public co-tenant can hit `:18789` directly and bypass Authelia) and NOT `data`. Traefik also joins `openclaw-edge` to route inbound UI traffic; all outbound (Anthropic, Telegram) goes out the default route, not via `data`.

### Why Authelia MAY be on `data`
Authelia is infra we control, not agent-driven. It needs Redis for session storage, and reusing the existing `infra-redis` (over `data`, authenticated with the Redis password) is the approved choice. So Authelia joins `proxy` + `data`.

### Traefik labels / middleware chain (OpenClaw router)
Mirror the `redis-ui` / `n8n` pattern (router on `websecure`, TLS via `letsencrypt`, per-service basic-auth `@docker`, file chains `@file`). Middleware order matters — auth must run before the request reaches the backend:

```
traefik.http.routers.openclaw.rule=Host(`${OPENCLAW_HOST}`)
traefik.http.routers.openclaw.entrypoints=websecure
traefik.http.routers.openclaw.tls=true
traefik.http.routers.openclaw.tls.certresolver=letsencrypt
traefik.http.routers.openclaw.middlewares=ui-chain@file,openclaw-rate-limit@file,authelia@file
traefik.http.services.openclaw.loadbalancer.server.port=${OPENCLAW_PORT}   # 18789
traefik.docker.network=${PROXY_NETWORK}
```

### Auth-model decision (revised after spike research)
- **Drop the separate Traefik `basicauth` middleware.** Stacking Traefik basic-auth AND Authelia forward-auth on the same router collides: both compete for the `Authorization` header / `WWW-Authenticate` 401 challenge → double browser prompts, and the second consumer never sees usable creds. (Source: Authelia proxy-authorization reference.) The operator's "**basic-auth + 2FA**" intent is realized cleanly by **Authelia's two factors**: first factor = username/password (replaces basic-auth, with brute-force protection + a real login form), second factor = TOTP. If a Traefik basic-auth layer is ever still wanted, the only conflict-free way is to move Authelia to its **Proxy-Authorization** strategy (407/`Proxy-Authenticate`) and scope `authRequestHeaders` — treat as custom, validate by testing.
- **Third layer (defense-in-depth):** keep **OpenClaw's own gateway auth ON** (`gateway.auth` mode `token` or `password`; it is fail-closed by default). Because Docker can't reach the default loopback bind, set `gateway.bind: "lan"` so Traefik reaches `:18789` over `proxy`; the non-loopback bind *requires* gateway auth anyway. Optionally use `gateway.auth` mode `trusted-proxy` with `gateway.trustedProxies` to delegate to Traefik+Authelia instead. (Source: docs.openclaw.ai/gateway/security.)
- **[BLOCKING SECURITY] Pin Traefik ≥ v3.6.14 before enabling forward-auth.** **CVE-2026-35051**: Traefik v3 **before v3.6.14** has a forwardAuth bypass — it fails to strip client-supplied identity headers (`Remote-User`, `X-Forwarded-User`) before calling the auth service, letting an attacker spoof an authenticated user. **The repo currently runs Traefik v3.6.6** → vulnerable. Upgrade `gateway` to ≥ v3.6.14 (and/or set `authRequestHeaders` to allowlist only needed headers) as a prerequisite of this whole integration.
- **Same-root-domain requirement.** Authelia's session cookie `domain` must be a parent of **both** the portal host and the protected app. So `OPENCLAW_HOST` and the Authelia portal host (e.g. `auth.<domain>`) must share a root domain (e.g. `openclaw.example.com` + `auth.example.com` under `example.com`). Configure `session.cookies[].authelia_url`. (Source: authelia.com/integration/proxies/traefik.)

### New entries in `gateway/dynamic/middlewares.yml`
Additive only (existing middlewares unchanged):

1. **`authelia` (forwardAuth)** — points at Authelia's auth endpoint, forwards the standard `Remote-User`/`Remote-Groups`/`Remote-Name`/`Remote-Email` auth-response headers. Built generically so any future admin UI (Traefik dashboard, Dozzle, Grafana, redis-ui) can add `authelia@file` to its chain. Sketch:
   ```yaml
   authelia:
     forwardAuth:
       address: "http://infra-authelia:9091/api/authz/forward-auth"
       trustForwardHeader: true
       authResponseHeaders:
         - Remote-User
         - Remote-Groups
         - Remote-Name
         - Remote-Email
   ```
   (Authelia must be reachable from Traefik — it is on `proxy`, so `infra-authelia` resolves on the proxy network. **Required:** the Authelia service must expose `infra-authelia` as a network **alias on `proxy`** — mirroring how `redis`/`n8n` set `aliases:` on `data` — or the `forwardAuth.address` DNS lookup from Traefik will fail. Alternatively rely on compose default service-name DNS and pin `traefik.docker.network=${PROXY_NETWORK}`.)

2. **`openclaw-rate-limit`** — tighter than the existing `ui-rate-limit` (600/300). A chat UI sees low request volume; cap it well below the default to blunt brute-force/credential-stuffing against the auth layers. Suggested starting point `average: 20, burst: 10, period: 1s` (operator-tunable). Existing `default-rate-limit` (100/50) and `ui-rate-limit` (600/300) remain untouched.

Authelia also needs its **own** Traefik router (on `proxy`) so the portal/redirect for the TOTP login flow is reachable on its own host (e.g. `auth.<domain>`), with `ui-chain@file` (no self-referential forward-auth on the portal). Standard Authelia + Traefik integration.

---

## 5. Secrets & LLM Auth

### LLM: Claude subscription, not metered API
v1 reuses a **Claude subscription** via Claude CLI / Anthropic OAuth token profile. OpenClaw documents "API key OR Claude CLI" and supports reusing existing Anthropic OAuth/token profiles, so a subscription session is used instead of a metered `ANTHROPIC_API_KEY`.

- **Where creds live (verified):** OpenClaw stores the OAuth/token profile in its own state dir at `~/.openclaw/agents/<agentId>/agent/auth-profiles.json` (profile selected via `auth.profiles.<id>.mode: "oauth"`), **not** in `~/.claude`. The credential is therefore **inside** the `openclaw-data` volume, not a naturally separate path. (Source: docs.openclaw.ai/concepts/oauth.)
- **Read-only mount is NOT viable (verified) — design corrected:** on expiry OpenClaw "refreshes under a file lock and overwrites the stored credentials" — refresh **requires write access**. A read-only creds mount breaks auth at the first refresh. So the token store stays in the **writable** `openclaw-data` volume. The earlier "separate read-only `openclaw-creds` volume" idea is **dropped**. (Source: docs.openclaw.ai/concepts/oauth, "Refresh + expiry".)
- **Seeding:** if the host already has a Claude CLI login, OpenClaw onboarding can reuse it; otherwise run the Claude/OpenClaw login flow once to populate `auth-profiles.json` in the volume. Model selection: `agents.defaults.model.primary: "anthropic/claude-…"`.
- **Security note:** because the token must be writable, a fully compromised container *could* overwrite/read it — this raises the value of the optional **egress allowlist** (§7), which prevents exfiltration even if the token is read. Subscription tokens are also revocable, limiting damage.
- **Operator-accepted caveat:** reusing a personal Claude subscription for an automated agent is a **ToS gray area**. This is explicitly accepted by the operator for this homelab; documented here so it is a conscious decision, not an accident. If it ever needs to flip to metered API, swap the creds volume contents / env for an `ANTHROPIC_API_KEY` in `env/prod/openclaw.env` with no topology change.

### Env split (matches repo convention)
- **Stack `.env`** (`openclaw/.env`, gitignored; committed only as `.env.example`): routing/image/port/host, basic-auth htpasswd hash. No secrets.
- **Real secrets** (`env/prod/openclaw.env`, `chmod 600`, gitignored): Telegram bot token, any sensitive OpenClaw runtime config. Wired via `env_file:` like `app-template`.
- **Authelia secrets** (`env/prod/authelia.env`, `chmod 600`; prefer the `AUTHELIA_*_FILE` form pointing at mounted secret files): JWT secret at the 4.38+ path `AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE` (the old top-level `jwt_secret` moved), `AUTHELIA_SESSION_SECRET_FILE`, `AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE`, `AUTHELIA_SESSION_REDIS_PASSWORD_FILE` (must match `redis/`'s `REDIS_PASSWORD`), notifier/SMTP if used. Storage = local SQLite at `/config/db.sqlite3`; session = external `infra-redis` with `database_index: 2`. Users = file `users.yml` (single user, **argon2id** hash via `authelia crypto hash generate argon2`); `totp:` block sets `issuer`; `access_control.default_policy: 'two_factor'` forces 2FA. (Source: authelia.com configuration refs.)
- **Redis DB index (DECISION, not open question):** redis-ui already uses DB `0` and the server has a single shared password with no ACL separation. Authelia **must** use a dedicated Redis DB index (e.g. `database: 2`) for its session store to avoid key-namespace coexistence with RedisInsight metadata. Reusing the password is fine; sharing DB 0 is not.

### Guard hook
The repo enforces a **read guard on `.env` files**. The spec respects this: all real-secret files stay out of git (`.gitignore` already has `**/.env`, `env/**/*.env`), only `*.env.example` is committed, and the design never instructs reading live env contents.

---

## 6. State, Volumes & Backups

### State model
OpenClaw is **file-based, no DB**. All state — workspace, `openclaw.json`, skills, prompt files (`AGENTS.md`, `SOUL.md`, `TOOLS.md`) — lives under `~/.openclaw`.

- **`openclaw-data`** → `~/.openclaw`, single **writable** named volume (unsuffixed, matching repo style like `redis-data`). Holds workspace, config state, skills, AND `auth-profiles.json` (the live Claude token — must be writable for refresh). A one-shot root `openclaw-init` service chowns it to uid 1000 on first boot. (The earlier idea of a separate read-only creds volume is dropped — refresh needs write, and OpenClaw does not use `~/.config/openclaw`.)
- Read-only rootfs where feasible (see §8); `~/.openclaw` stays a writable named volume so the agent can persist state.
- **`authelia-data`** → Authelia sqlite storage + TOTP secrets.

### Backups
- **Stack registration (REQUIRED first — verified gap):** `backup-volumes.sh --stack <name>` resolves the stack via `is_infra_stack()` in `scripts/lib.sh`, which is a **hardcoded allowlist** (`gateway|postgres|registry|observability|admin|uptime|centrifugo|n8n|clickhouse|kafka|redis|mailpit`). `openclaw` and `authelia` are **absent**, so the script currently treats them as app stacks and errors ("Environment is required for application stacks"). Implementation must add both names to `is_infra_stack()` in `scripts/lib.sh` **and** to the usage string in `backup-volumes.sh` before any `--stack openclaw|authelia` command works.
- App state and Authelia: once registered, backed up by `./scripts/backup-volumes.sh --stack openclaw` / `--stack authelia`. The script enumerates volumes via `docker compose config --volumes` — i.e. **every named volume declared in the stack's compose** (a named volume cannot be mounted without a top-level `volumes:` entry, so "just omit it" does **not** exclude it).
- **Claude token in backups (design corrected):** the token (`auth-profiles.json`) lives **inside** `~/.openclaw` and must be writable for refresh (§5), so it cannot be cleanly split onto a separate excluded volume. Therefore a `backup-volumes.sh --stack openclaw` archive **will contain a live token**. Handling decision: **accept it and treat `backups/` as sensitive** (consistent with `backup-env.sh` already archiving the Telegram token + Authelia secrets at mode 600). The token is also **re-creatable** — if a backup is ever compromised, revoke the subscription session and re-login; loss of the token is a re-login, not data loss. Optional: a post-backup scrub step that strips `auth-profiles.json` from the openclaw archive if the operator wants tokens out of backups entirely.
- `./scripts/backup-env.sh` already archives `env/prod` + `env/stage` with `chmod 600` on the tarball; `env/prod/openclaw.env` and `env/prod/authelia.env` are captured there automatically. Note that this env backup **does** contain the Telegram token and Authelia secrets — store those archives securely (the script already restricts to mode 600; treat the `backups/` dir as sensitive, consistent with existing posture).

---

## 7. Security Model & Threat Mitigation

### Threat model
The dominant threat is **prompt injection / model jailbreak**: a malicious Telegram message (or web content the agent fetches) coerces the agent into running attacker-chosen actions. With an autonomous agent that can be told to run bash/fs/network ops, the only durable defense is to **shrink the blast radius**, not to perfectly filter inputs.

### Why "jail" beats "edge-hardening"
Edge-hardening (better prompts, input filters, allowlist phrasing) is **probabilistic** — it fails on the first clever prompt. The jail is **structural** — even a fully jailbroken agent can only do what the container can do. So v1 invests in confinement:

- **No host access:** no `docker.sock`, no host bind-mounts of code, no `privileged`, no `pid: host`, no `cap_add`. The agent cannot pivot to the host or other containers.
- **Off `data`:** the agent cannot reach any prod datastore (no Postgres/Redis/ClickHouse/Kafka). Compromise of the agent does **not** expose customer/prod data.
- **`cap_drop: ALL`** + **`security_opt: no-new-privileges:true`** + **read-only rootfs** (writable only on `~/.openclaw`): minimal kernel-capability and filesystem surface.
- **Chromium/browser automation disabled:** removes the largest single attack surface (renderer exploits, SSRF via headless browser, data exfil through arbitrary navigation).
- **Token handling (corrected):** the Claude token must be **writable** (refresh writeback, §5), so it cannot be made read-only; a full compromise could read or rewrite it. The durable control is the optional **egress allowlist** below — it prevents exfiltration even if the token is read. Subscription tokens are also revocable.

### Optional egress allowlist (recommended, marked optional)
Constrain outbound traffic to **Anthropic + Telegram only**. With outbound locked to those two destinations, a jailbroken bot **cannot exfiltrate the Claude token or chat data** to an arbitrary host. Implementation options for a compose-only host: an egress firewall/proxy sidecar or host-level egress rules scoped to the container. Marked **optional** because it adds operational friction (Anthropic/Telegram IP ranges change), but **recommended** as the highest-value incremental hardening after the jail itself.

### Subscription protection (abuse / runaway loops) — corrected after spike
**Verified:** OpenClaw has **no per-task max-iterations / turn / spend cap** (the plausible `agents.defaults.maxIterations` does **not** exist in the config reference — earlier assumption removed). Because we use a **subscription, not a metered API**, a runaway loop hits Anthropic **rate limits**, not unbounded spend — the cost blast-radius is inherently bounded. Use the knobs that *do* exist:
- cron `maxConcurrentRuns`, `cron.retry.maxAttempts`, and **`cron.failureAlert`** (enable → alert after N consecutive failures; can route to Telegram),
- `acp.maxConcurrentSessions`, `sessionIdleTtlMs` (default 600000 ms),
- auth-rotation caps `overloadedProfileRotations` / `rateLimitedProfileRotations`,
- combined with the tightened Traefik `openclaw-rate-limit` on the UI side.
**Residual risk (accepted):** no hard per-task agentic step cap; mitigated by the subscription's own rate-limit ceiling. (Source: docs.openclaw.ai/gateway/configuration-reference.)

### Residual risks (accepted/known)
- The Telegram bot token and chat content are still reachable from inside the container if it is compromised (mitigated, not eliminated, by the egress allowlist).
- ToS gray area on subscription reuse (operator-accepted, §5).
- The UI is publicly exposed; security rests on Authelia TOTP + basic-auth + rate-limit holding. No VPN fallback in v1 — this is the chosen tradeoff.
- Authelia is on `data` and could, if itself compromised, reach Redis. It is infra we trust more than the agent; this asymmetry is deliberate.

---

## 8. Resource Limits & Performance

- **`mem_limit: 2g`** (~2G ceiling).
- **`cpus:`** — explicit CPU cap (operator sets, e.g. `cpus: "1.5"`) so the agent can't starve other stacks on the single VDS.
- **`pids_limit:`** — cap process count to blunt fork bombs / runaway subprocess spawning.
- **`cap_drop: ALL`**, **`security_opt: [no-new-privileges:true]`**.
- **Read-only rootfs where feasible** (`read_only: true`) with a writable named volume mount for `~/.openclaw` and any required tmp (`tmpfs` for `/tmp` if the app needs scratch space).
- **Chromium / Playwright disabled** in v1 — and this is the **default** (verified): the official image (base `node:24-bookworm-slim`, `tini` as PID 1) ships **without** browser binaries; they install only if you pass `OPENCLAW_INSTALL_BROWSER=1` at build or run the Playwright install into a volume. So we simply never install them, and belt-and-suspenders set **`browser.enabled: false`** plus **`gateway.tools.deny: ["browser"]`** in config. (Source: docs.openclaw.ai/install/docker, /gateway/configuration-reference.)
- Standard `restart: unless-stopped` and the repo-standard `json-file` logging (`max-size: 10m`, `max-file: 5`) via the `x-logging` anchor.
- Healthcheck against the UI port (`127.0.0.1:18789`) following the `redis-ui`/`n8n` healthcheck pattern, so deploy and Uptime-Kuma can observe liveness.

---

## 9. Deferred Escalation Path to "Full Access"

The "full host access" ceiling (OpenClaw `main` with bash/exec/fs) is **deferred, not foreclosed**. Clean opt-in path:

### Profile-gated executor container
- Add a **separate privileged executor container** to the `openclaw` compose under `profiles: [escalated]`, **off by default** (`docker compose up` without `--profile escalated` never starts it). The base `infra-openclaw` stays in the jail.
- OpenClaw's `main` session would target this executor as an **external sandbox backend** (Docker/SSH/OpenShell backend), so privileged actions run **inside the executor**, never in the gateway container and never directly on the host unless the executor is explicitly granted that.
- The executor gets its **own private network** (e.g. `openclaw-escalated`) shared only with OpenClaw — **never** `data`.

### Required spike (before trusting the backend)
- **Sandbox-backend confinement spike:** confirm OpenClaw's sandbox backend **truly confines `main`** to the external executor and does not silently fall back to in-process host/exec when the backend is unavailable or errors. Until this is proven, escalation stays off.

### Three preconditions before host/`data` go live
Escalation (host access and/or `data` reachability) must **not** be enabled until **all three** hold:
1. **Authelia + TOTP confirmed** working and enforced on the UI (verified, not assumed).
2. **CrowdSec on Traefik logs** deployed — active intrusion detection / IP banning on the edge, so brute-force and scanning against the now-higher-value target are detected and blocked.
3. **Per-channel allowlist of who can drive `main`** — only specific, named Telegram user IDs (and later, named identities on other channels) may invoke `main`/privileged sessions. Anonymous or unknown senders can never drive the escalated path.

Each precondition is a gate; the executor profile and any `data` attachment stay disabled until they are all met and the spike passes.

---

## 10. Rollout & Verification

Use existing Makefile/scripts conventions (one `up-<stack>` target per stack, `create-network.sh`, `backup-*.sh`, `healthcheck`-style checks). New Makefile targets `up-authelia` and `up-openclaw` should be added mirroring the existing `up-redis`/`up-n8n` targets (`cd <stack> && docker compose --env-file .env up -d`). Existing infra targets call `create-network.sh proxy` **and** `data` unconditionally and idempotently; keep that house style (ensuring `data` exists is harmless even though the OpenClaw *container* does not join it — joining is controlled by the compose `networks:` block, not by which networks exist). Also extend the Makefile `.PHONY` line and the `help` block with both new targets, or they won't show in `make help`.

### Deploy steps
1. **Prereqs:** `infra-redis` and `gateway` (Traefik) already up. `proxy` and `data` external networks exist (`./scripts/create-network.sh proxy` / `data`).
2. **Authelia first** (OpenClaw depends on its forward-auth):
   - Create `env/prod/authelia.env` (`chmod 600`) with JWT/session/storage-encryption secrets and the Redis password (matching `redis/`).
   - Fill `authelia/config/configuration.yml` (TOTP, session→`infra-redis`, sqlite storage, access control) and `users_database.yml` (single user, hashed password).
   - Create `authelia/.env` from `.env.example` (host = `auth.<domain>`, image, `PROXY_NETWORK`).
   - `make up-authelia` (or `cd authelia && docker compose --env-file .env up -d`).
   - Add `authelia@file` (and `openclaw-rate-limit`) to `gateway/dynamic/middlewares.yml`; Traefik file provider hot-reloads (no Traefik restart needed; `--providers.file.watch=true` is enabled).
3. **OpenClaw:**
   - Create `env/prod/openclaw.env` (`chmod 600`) with the Telegram bot token + runtime secrets.
   - Create `openclaw/.env` from `.env.example` (host = `<operator-chosen host>`, `OPENCLAW_PORT=18789`, basic-auth hash, `PROXY_NETWORK`).
   - **Seed the Claude subscription token ONCE** into `openclaw-data` via `make onboard-openclaw` (interactive setup-token/paste-token flow). Without this the bot starts but every Claude call fails. See openclaw/README.md.
   - In `openclaw.json`: disable browser automation, set loop/turn caps + max-iterations + alerting, scope channel to Telegram, restrict `main` per the allowlist principle.
   - `make up-openclaw` (or `cd openclaw && docker compose --env-file .env up -d`).
4. **Observability:** add an Uptime-Kuma monitor for the OpenClaw UI host; confirm Promtail is shipping logs (labels `compose_project=openclaw`, `compose_service`).
5. **Backups:** dry-run `./scripts/backup-volumes.sh --stack openclaw` and `--stack authelia`; the `openclaw-data` archive contains the live Claude token, so treat `backups/` as sensitive (per §6).

### Acceptance criteria (see §11 for the testable checklist)
UI reachable only after Authelia TOTP **and** basic-auth; one Telegram message round-trips; container has no host/`data` access (verified); Uptime-Kuma green; resource caps enforced.

---

## 11. Acceptance Criteria (Checklist)

Auth & exposure
- [ ] Traefik is pinned to **≥ v3.6.14** (CVE-2026-35051 forwardAuth bypass fixed) **before** forward-auth is enabled.
- [ ] Hitting `https://<OPENCLAW_HOST>/` with no session **redirects to the Authelia portal** (not the OpenClaw UI).
- [ ] Authelia requires **password (factor 1) AND TOTP (factor 2)**; skipping TOTP → blocked.
- [ ] Spoofing an identity header (`Remote-User`/`X-Forwarded-User`) from the client does **not** bypass auth (CVE regression check).
- [ ] OpenClaw's **own gateway auth is ON** (3rd layer): reaching `:18789` without the gateway token / trusted-proxy is refused.
- [ ] OpenClaw UI port **18789 is not published** on the host (`docker ps` shows no host port mapping for `infra-openclaw`; only `infra-traefik` maps 80/443).
- [ ] The tightened `openclaw-rate-limit` is in the router's middleware chain and rejects rapid repeated requests.

Telegram round-trip
- [ ] Sending one message to the Telegram bot produces a Claude-generated reply (end-to-end LLM via subscription works).
- [ ] No public inbound webhook exists for Telegram (long-poll only); no Traefik router exposes a Telegram callback.

Jail verification (no host / no data)
- [ ] `docker inspect infra-openclaw` shows networks = **`openclaw-edge` only** (not `proxy`, not `data`).
- [ ] From inside `infra-openclaw`, `infra-postgres` / `infra-redis` (and other `data` aliases) are **not resolvable/reachable** (e.g. DNS lookup / TCP connect fails).
- [ ] `docker inspect` confirms: no `/var/run/docker.sock` mount, no host bind-mounts of host fs, `Privileged=false`, no `pid: host`, `CapDrop=ALL`, no `CapAdd`, `no-new-privileges` set.
- [ ] (Optional, deploy-verified) Read-only rootfs: the compose ships `read_only`+`tmpfs` commented out; if enabled, smoke-test for EROFS and confirm only `~/.openclaw` + declared tmpfs are writable.
- [ ] Browser automation is **disabled** (image built WITHOUT `OPENCLAW_INSTALL_BROWSER`; `browser.enabled: false`; `gateway.tools.deny` includes `browser`; no Chromium process exists).

Resource caps
- [ ] `docker inspect` shows `mem_limit ≈ 2g`, an explicit `cpus`/CPU quota, and a `pids_limit`.
- [ ] Caps are actually enforced (e.g. a memory-heavy action is OOM-capped rather than taking down the host).

State, secrets, backups
- [ ] `~/.openclaw` persists across `docker compose restart` (named volume `openclaw-data`).
- [ ] The Claude token (`auth-profiles.json`) is in `openclaw-data` on a **writable** mount and **survives a token refresh** (a forced refresh rewrites it without breaking auth).
- [ ] `openclaw`/`authelia` are registered in `is_infra_stack()`; `./scripts/backup-volumes.sh --stack openclaw` and `--stack authelia` run successfully; `backups/` is treated as sensitive (it contains the live token + Authelia secrets).
- [ ] Real secrets exist only in `env/prod/openclaw.env` / `env/prod/authelia.env` (`chmod 600`), gitignored; only `*.env.example` is committed; the `.env` read guard is respected.

Observability
- [ ] Uptime-Kuma monitor for the OpenClaw UI is **green**.
- [ ] Loki query `{compose_project="openclaw"}` returns OpenClaw logs.

Subscription protection
- [ ] No reliance on a non-existent `maxIterations` key; instead `cron.failureAlert` is enabled, cron/`acp` concurrency limits + `sessionIdleTtlMs` are set, and the subscription rate-limit is the accepted ceiling.

Reusability
- [ ] The `authelia@file` forward-auth middleware is generic and can be added to another admin UI's middleware chain without Authelia config changes specific to OpenClaw.

---

## 12. Open Questions / Spike Items

1. ~~**Official image & browser deps**~~ — **RESOLVED (§8):** official image (`node:24-bookworm-slim`) ships **without** browser binaries; they install only via `OPENCLAW_INSTALL_BROWSER=1`. We never install them + set `browser.enabled: false` + `gateway.tools.deny: ["browser"]`. (docs.openclaw.ai/install/docker, /gateway/configuration-reference)
2. ~~**Claude CLI in-container login**~~ — **RESOLVED (§5):** token lives at `~/.openclaw/agents/<id>/agent/auth-profiles.json` (mode `oauth`), **inside** the main volume. Refresh **overwrites under a file lock → REQUIRES WRITE access**, so the read-only-mount plan is dropped; token stays in the writable `openclaw-data`. (docs.openclaw.ai/concepts/oauth)
3. **Sandbox-backend confinement spike (§9) — PARTIALLY RESOLVED, still gates escalation:** mechanism confirmed (`agents.defaults.sandbox.mode: "all"` forces `main` into a Docker/SSH/OpenShell backend; default `main` runs in-process on host). Evidence **leans fail-closed** (fail-fast on missing image, `network: host`/`container:` blocked), but **no authoritative doc** covers a *runtime backend-down* under `mode: "all"` (refuse vs. host fallback). **Verify in source before trusting confinement for escalation.** (docs.openclaw.ai/gateway/sandboxing)
4. ~~**Egress allowlist feasibility**~~ — **RESOLVED (§7, optional):** recommended approach = isolated `internal: true` network whose only egress is a **domain-allowlisting forward proxy** (tinyproxy/squid via `HTTPS_PROXY`), since Anthropic/Telegram sit behind CDNs with rotating IPs (pure iptables IP-allowlists are high-maintenance). Caveat: the app must honor `HTTPS_PROXY`/`NO_PROXY`; the internal network guarantees no bypass. Remains optional hardening.
5. ~~**Authelia forward-auth endpoint & headers**~~ — **RESOLVED + new blocking item (§4):** endpoint `/api/authz/forward-auth` (4.38+); `forwardAuth` needs `trustForwardHeader: true`, `maxResponseBodySize: 8192`, `authResponseHeaders: Remote-User,Remote-Groups,Remote-Email,Remote-Name`. Portal needs its own host + `session.cookies[].authelia_url`, same-root-domain with the UI. **CVE-2026-35051: pin Traefik ≥ v3.6.14 (repo is v3.6.6).** Layering Traefik basic-auth with Authelia conflicts → use Authelia portal (password+TOTP) instead. (authelia.com/integration/proxies/traefik; reference/guides/proxy-authorization)
6. ~~**Redis multi-tenant use**~~ — **RESOLVED to a decision (§5):** Authelia reuses `infra-redis` (shared password OK) but on a **dedicated DB index** (e.g. `database: 2`), since redis-ui occupies DB 0. No longer open.
7. ~~**Loop/turn cap semantics**~~ — **RESOLVED (§7):** there is **no** per-task max-iterations/turn/spend key (the assumed one doesn't exist). Real knobs: `cron.maxConcurrentRuns`, `cron.retry.maxAttempts`, `cron.failureAlert` (routable to Telegram), `acp.maxConcurrentSessions`, `sessionIdleTtlMs`, profile-rotation caps. Subscription rate-limit is the accepted ceiling. (docs.openclaw.ai/gateway/configuration-reference)
8. ~~**`compose_project` label value**~~ — **RESOLVED to a decision (§3):** pin `COMPOSE_PROJECT_NAME=openclaw` in `openclaw/.env.example`; infra stacks do not auto-suffix `-prod`, so this makes the §11 Loki acceptance query testable. No longer open.
9. **CrowdSec prerequisite (for §9):** Scope the CrowdSec-on-Traefik-logs deployment as its own follow-up so precondition 2 for escalation is actionable.
