# PLAN.md — Auto-Agent Blueprint (Hardened)

The blueprint for Auto-Agent: architecture decisions, scope, security model, and
phased implementation. User-facing setup lives in [README.md](README.md) (the
developer truth). Workflow rules live in [AGENTS.md](AGENTS.md).

> **Revised May 2026** after verifying the actual shape of Hermes and OpenClaw.
> See [Reality check](#reality-check-may-2026) for what changed and why.

---

## Vision

A self-hosted AI agent stack on a personal **Arch Linux** desktop that is:

- a **persistent assistant** reachable from Telegram and Discord,
- a **developer copilot** for this repo (Claude Code on the host),
- a **learning substrate** — Hermes accumulates memory across sessions instead of
  starting cold.

It must be cheap to run idle, **hardened by default**, and depend on no cloud
service besides the Anthropic API (and Telegram/Discord, when bridges are on).

---

## Reality check (May 2026)

The original draft was built on assumptions that don't match the tools. Corrected:

| Original assumption                                  | Reality (May 2026)                                                                 |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Hermes is a thin Claude API client                   | Hermes (`v0.14.0`/`v2026.5.16`) is a full autonomous agent: memory, 40+ tools, MCP, skills, gateway |
| Hermes stores memory in Postgres                     | Hermes uses **SQLite + FTS5** (LLM-summarized cross-session recall) natively       |
| OpenClaw is just a TG/Discord bridge                 | OpenClaw is a full gateway **with its own bundled agent runtime** + 10 channels    |
| Stack is Docker-compose-first                        | Both tools install natively (pip / npm) and run as **daemons/systemd services**    |
| Laptop runs Windows 10 + WSL 2                       | Windows 10 is **EOL** (2025-10-14; ESU to 2026-10-13) → **WSL path dropped**       |
| Postgres + Redis are core                            | Dropped from core; SQLite is Hermes's store. Redis/Postgres only if a real need appears |

### Decisions locked

1. **Role split — OpenClaw front, Hermes brain.** OpenClaw owns chat channels;
   Hermes is its external agent backend. No redundant double-agent.
2. **Memory — native SQLite + backups.** Use Hermes's own store; harden with WAL +
   restic/litestream. No Postgres in v1.
3. **Deployment — native + systemd hardening.** Matches how both tools ship and
   gives stronger, simpler isolation than containers that must mount the host.
4. **Target — Arch desktop only.** WSL/Windows out of scope.

---

## Reference Hardware

| Machine | OS         | RAM   | GPU          |
| ------- | ---------- | ----- | ------------ |
| Desktop | Arch Linux | 32 GB | 8–10 GB VRAM |

---

## Core Features (in scope)

1. **Hermes Agent** — autonomous brain. Claude API inference (built-in prompt
   caching), SQLite/FTS5 memory, tools, MCP, skills. Pinned version.
2. **OpenClaw gateway** — Telegram + Discord front door, routing to Hermes as an
   external/ACP agent runtime. Sender allowlists + group mention rules.
3. **Persistent memory** — Hermes's SQLite store with WAL; scheduled backups.
4. **Hardened runtime** — dedicated unprivileged user, systemd sandboxing,
   bubblewrap shell jail, default-deny firewall, loopback-only endpoints.
5. **Claude Code workflow** — `CLAUDE.md`, slash commands, hooks for this repo.
6. **Local inference (optional)** — Ollama/llama.cpp OpenAI-compatible endpoint
   Hermes can route cheap tasks to. Off by default.

## Non-Goals

- Multi-user / multi-tenant operation.
- Cloud deployment (Kubernetes, managed DBs).
- WSL / Windows / macOS support.
- Voice/audio I/O (beyond whatever the channel adapters do natively).
- Replacing Claude with a fully local model — local inference is a complement.
- A separate FastAPI capability server in v1 (see [Open questions](#risks--open-questions)).

---

## Architecture

```
                ┌──────────────────────────────┐
                │        Anthropic API          │
                └──────────────▲────────────────┘
                               │ inference (cached)
┌──────────────┐   ext agent   ┌─────┴──────┐
│   Telegram   │◀────────────▶ │   Hermes   │  brain: memory + tools + skills
│   Discord    │   runtime     │   Agent    │
└──────▲───────┘               └─────▲──────┘
       │                             │
┌──────┴───────┐                     │ SQLite/FTS5 memory (WAL)
│   OpenClaw   │  front door         ▼
│   gateway    │              ~/.hermes/  ──▶ restic / litestream backup
└──────────────┘
       │
  Control UI 127.0.0.1:18789 (loopback)

         ┌─────────────────────────────────────────────┐
         │  Host isolation: agent user · systemd        │
         │  sandbox · bubblewrap shell jail · ufw deny  │
         └─────────────────────────────────────────────┘

  Local LLM (optional) ── OpenAI-compatible endpoint Hermes may route to
  Claude Code         ── runs on host as the human, edits this repo
```

### Service responsibilities

- **OpenClaw** — protocol adapters + routing only. Translates platform messages ↔
  Hermes. Enforces channel allowlists and group mention rules. Bundled agent
  **disabled**; backend = Hermes.
- **Hermes** — orchestrator/brain. Owns the loop, prompts, Claude-vs-local routing,
  tool execution, and all memory writes.
- **SQLite store** — durable memory (transcripts, distilled memories, session FTS).
  The only stateful asset that matters → backed up.
- **Local LLM (optional)** — swappable provider behind an OpenAI-compatible API.

### Cross-cutting decisions

- **Native install + systemd**, not compose. Optional local LLM may run in a
  container (`ollama`) since it's self-contained and benefits from GPU isolation.
- **All secrets via `.env`** (`0600`) loaded through systemd `EnvironmentFile`.
  `.env.example` is the schema source of truth; nothing secret is committed.
- **Loopback-only**: Hermes endpoint and OpenClaw Control UI bind `127.0.0.1`.
  No service listens on the LAN. Remote access only via authenticated proxy or
  WireGuard/Tailscale.
- **Hermes's own tools are the host surface.** Rather than a parallel capability
  server, the surface is hardened in place: sandboxed unit + bubblewrap + command
  allowlist + journald audit.

---

## Memory & Data

Hermes manages its own schema inside SQLite (`~/.hermes/`). We do **not** define
Postgres tables. The durability contract:

- **WAL mode** enabled for crash safety and concurrent reads.
- **Backups**: `restic` snapshot on a `systemd` timer (daily) to a local repo +
  offsite copy; optional `litestream` for continuous/PITR replication.
- **Restore drill**: documented and tested in Phase 4. Exclude `-wal`/`-shm` from
  cold snapshots or quiesce Hermes during backup.

If a future need arises for queryable/shared structured memory across tools, add
Postgres+pgvector as a **separate** store written via an explicit tool — it is not
Hermes's primary memory. Deferred to v2.

---

## Security Model

Threat: a compromised or jailbroken agent (prompt injection via an inbound chat
message) attempts to read secrets, exfiltrate data, or run destructive host
commands. Mitigations, defense-in-depth:

| Layer        | Control                                                                 |
| ------------ | ----------------------------------------------------------------------- |
| Identity     | Dedicated unprivileged `agent` user; no sudo; `loginctl enable-linger`. |
| Process      | systemd: `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=read-only` + explicit `ReadWritePaths`, `PrivateTmp`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `SystemCallFilter=@system-service`, empty `CapabilityBoundingSet`. |
| Resources    | `MemoryMax`, `CPUQuota`, `TasksMax` to bound runaway loops.             |
| Shell tools  | `bubblewrap` jail (read-only rootfs, scoped writable dir, no network unless required) + command allowlist; deny `sudo`, package managers, raw disk. |
| Network      | `ufw` default-deny inbound; endpoints loopback-only; egress allowed.    |
| Channels     | OpenClaw sender/chat-ID allowlist; `requireMention` in groups; scoped bot tokens. |
| Secrets      | `.env` `0600` via `EnvironmentFile`; never logged; never committed.     |
| Supply chain | Pin Hermes (`==0.14.0`) and OpenClaw versions; deliberate, reviewed upgrades. |
| Audit        | journald per service; periodic review; alert on anomalous tool volume. |

**Residual risk**: Hermes legitimately has powerful tools; sandboxing constrains
blast radius but a determined injection within the allowed surface is still
possible. Keep the shell allowlist tight and the writable paths minimal.

---

## Implementation Phases

1. **Base host** — packages, `agent` user + linger, `ufw` default-deny, `.env`
   scaffolding (`0600`), repo layout.
2. **Hermes** — pinned install (uv/py3.11), Anthropic provider config, SQLite WAL,
   loopback endpoint; verify a CLI round-trip to Claude.
3. **OpenClaw → Hermes** — install, configure external agent runtime = Hermes,
   enable Telegram + Discord with allowlists + mention rules, Control UI loopback.
4. **Hardening + backups** — systemd hardened units, bubblewrap shell jail,
   `restic` timer + restore drill, log review runbook.
5. **Claude Code workflow** — `CLAUDE.md`, slash commands, hooks for this repo.
6. **Optional local LLM** — Ollama (GPU) as OpenAI-compatible provider; profile
   memory/VRAM under load before relying on it.

---

## Risks & Open Questions

- **Upstream churn** — Hermes ships fast (multiple releases/month). Pin and review
  changelogs before bumping; the `v0.14.0` "Foundation Release" stabilized install.
- **OpenClaw↔Hermes integration** — confirm the exact external-agent/ACP wiring in
  `openclaw.json` against current OpenClaw docs; bundled-agent disable must be
  verified, not assumed.
- **Prompt-injection blast radius** — the core security concern; see model above.
  Revisit a dedicated, audited FastAPI capability server (the original idea) **if**
  Hermes's native tool sandboxing proves insufficient.
- **Local LLM memory pressure** — 6–9 GB VRAM is tight; keep optional until profiled.
- **"Self-improving" scope** — v1 = Hermes writes/recalls its own memory and skills;
  it does **not** mean autonomous edits to this repo.

---

## Success Criteria for v1

- Fresh Arch box: install Hermes + OpenClaw natively, enable systemd units, all green.
- A Telegram/Discord message reaches Hermes via OpenClaw, gets a Claude-generated
  reply, and is persisted in Hermes's SQLite memory.
- Memory survives a restart (`systemctl --user restart hermes`).
- A `restic` backup can be taken **and restored** into a working memory store.
- The agent runs as the unprivileged `agent` user under the hardened unit; shell
  tools execute inside the bubblewrap jail; no inbound ports are open.
- Claude Code runs in the repo root and edits a file on request.

Anything beyond this is v2.
