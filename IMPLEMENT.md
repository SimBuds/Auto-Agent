# IMPLEMENT.md — Phased Execution

Granular, phase-by-phase execution log for Auto-Agent. Authoritative source for "where are we right now." Workflow rules in [AGENTS.md](AGENTS.md); blueprint in [PLAN.md](PLAN.md); user setup in [README.md](README.md).

**Current state:** Pre-Phase 0 — only `AGENTS.md`, `README.md`, `PLAN.md`, and this file exist. No code, no compose file, no `.env.example`.

**Legend:** `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked / deferred

---

## Phase 0 — Repo skeleton

**Goal:** Create the directory layout and placeholder config so subsequent phases have a place to land.

**Files to touch / create:**
- `.gitignore` (Python, Node, Docker, `.env`, `data/`)
- `.env.example` (keys only, no values: `ANTHROPIC_API_KEY`, `POSTGRES_PASSWORD`, `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`)
- `docker-compose.yml` (empty `services:` stub)
- `services/hermes/`, `services/capability/`, `services/openclaw/` (empty dirs with `.gitkeep`)
- `data/` (gitignored)

**Verification:**
- `git status` shows the new files staged-able.
- `docker compose config` parses without error.

**Tasks:**
- [ ] Create directories and `.gitkeep` files
- [ ] Write `.gitignore`
- [ ] Write `.env.example`
- [ ] Write empty `docker-compose.yml` skeleton
- [ ] Verify `docker compose config` parses

---

## Phase 1 — Postgres + Redis up

**Goal:** Stand up the two stateful services and confirm volumes persist across a restart.

**Files to touch:**
- `docker-compose.yml` (add `postgres` and `redis` services with named volumes, healthchecks, `.env` wiring)

**Verification:**
- `docker compose up -d postgres redis` → both healthy in `docker compose ps`.
- `psql` from a one-shot container can `CREATE TABLE t(x int); INSERT; SELECT;`.
- `docker compose down && docker compose up -d` → row still present.

**Tasks:**
- [ ] Add `postgres` service (pinned tag, volume `pgdata`, healthcheck)
- [ ] Add `redis` service (pinned tag, volume `redisdata`, healthcheck)
- [ ] Verify persistence across restart

---

## Phase 2 — Capability Server walking skeleton

**Goal:** FastAPI service with one working endpoint and an audit-log write to Postgres.

**Files to touch:**
- `services/capability/Dockerfile`
- `services/capability/pyproject.toml` (or `requirements.txt`)
- `services/capability/app/main.py` (FastAPI app, `/healthz`, `/shell` with allowlist of exactly one command, e.g. `uname -a`)
- `services/capability/app/db.py` (asyncpg connection + audit insert)
- `docker-compose.yml` (add `capability` service)

**Verification:**
- `curl localhost:8000/healthz` → `{"ok": true}`
- `curl -XPOST localhost:8000/shell -d '{"cmd":"uname -a"}'` → returns stdout
- `SELECT * FROM capability_audit;` shows one row.

**Reuse audit:** none — this is the first service.

**Tasks:**
- [ ] Dockerfile + deps file
- [ ] FastAPI app with `/healthz` and `/shell` (allowlist length 1)
- [ ] Audit table migration (`capability_audit`)
- [ ] Compose service wired to Postgres
- [ ] End-to-end curl + SQL check

---

## Phase 3 — Hermes container, Claude API loop

**Goal:** Hermes container that takes a single CLI message, calls Claude, writes the exchange to Postgres, returns the reply.

**Files to touch:**
- `services/hermes/Dockerfile`
- `services/hermes/pyproject.toml`
- `services/hermes/hermes/main.py` (one-shot CLI: `hermes "hello"` → reply)
- `services/hermes/hermes/memory.py` (Postgres reads/writes for `conversations`, `messages`)
- Migration adding `conversations`, `messages` tables.
- `docker-compose.yml` (add `hermes` service, no exposed port yet)

**Verification:**
- `docker compose run --rm hermes hermes "say hi"` → Claude reply printed.
- `SELECT count(*) FROM messages;` returns 2 (user + assistant).

**Tasks:**
- [ ] Schema migration (`conversations`, `messages`)
- [ ] Anthropic SDK client wired via `ANTHROPIC_API_KEY`
- [ ] One-shot CLI entrypoint
- [ ] Persistence verified

---

## Phase 4 — OpenClaw Telegram adapter (one channel)

**Goal:** A Telegram message reaches Hermes and the reply posts back. Discord deferred to its own phase.

**Files to touch:**
- `services/openclaw/Dockerfile`
- `services/openclaw/app/main.py` (Telegram long-poll, forward to Hermes HTTP endpoint)
- `services/hermes/hermes/main.py` (add minimal HTTP endpoint `POST /message`)
- `docker-compose.yml` (add `openclaw` service under `bridges` profile)

**Verification:**
- Send a DM to the bot → reply received within 10s.
- `messages` table shows both rows with `channel='telegram'`.

**Tasks:**
- [ ] Hermes HTTP endpoint
- [ ] OpenClaw Telegram adapter
- [ ] Compose profile `bridges`
- [ ] Live Telegram round-trip verified

---

## Phase 5 — Discord adapter

**Goal:** Same contract as Phase 4, second platform.

**Tasks:**
- [ ] Discord adapter in OpenClaw
- [ ] Live Discord round-trip verified

---

## Phase 6 — Claude Code on-host workflow

**Goal:** Claude Code is productive in this repo: `CLAUDE.md`, slash commands for common ops, hook for "after edit, run `docker compose config`".

**Files to touch:**
- `CLAUDE.md` (project rules for Claude Code)
- `.claude/commands/` (slash commands: `restart-stack`, `tail-hermes`, `psql`)
- `.claude/settings.json` (hooks, allowed Bash patterns)

**Verification:**
- Open Claude Code in repo root, run each slash command, confirm expected output.

**Tasks:**
- [ ] `CLAUDE.md`
- [ ] Slash commands
- [ ] Settings + hooks
- [ ] Walkthrough verified

---

## Phase 7 — Hardening pass

**Goal:** Make the stack survive being left running for a week.

**Tasks:**
- [ ] Resource limits (`deploy.resources` or `mem_limit`) per service
- [ ] `restart: unless-stopped` on all services
- [ ] Log rotation (compose `logging` driver opts)
- [ ] `pg_dump` cron in a sidecar or systemd timer
- [ ] Document recovery procedure in README

---

## Phase 8 (optional) — Local LLM service

**Goal:** Add an OpenAI-compatible local inference service (Ollama or llama.cpp server) behind a compose profile, and a router knob in Hermes to send cheap requests there.

Skipped unless explicitly approved — gated on Phase 7 being green.

---

## Deferred / Parking Lot

- pgvector + embedding-based memory recall (currently text-only)
- Capability Server: notify, systemd, file-ops endpoints (only `/shell` exists in Phase 2)
- Multi-conversation routing in Hermes (v1 is single-thread)
- Backup *offsite* (Phase 7 covers local backup only)
- Windows 11 migration note for the laptop before Windows 10 EOL (2025-10-14)
