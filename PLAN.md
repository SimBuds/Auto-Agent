# PLAN.md — Auto-Agent Blueprint

The high-level blueprint for Auto-Agent. Architecture decisions and scope live here; granular execution lives in [IMPLEMENT.md](IMPLEMENT.md); workflow rules live in [AGENTS.md](AGENTS.md); user-facing setup lives in [README.md](README.md).

---

## Vision

A self-hosted, self-improving AI agent stack that runs on a personal Linux box (Arch primary, WSL 2 secondary) and serves as:

- a **persistent assistant** reachable from Telegram and Discord (via OpenClaw),
- a **developer copilot** for this repo (via Claude Code on the host),
- a **learning substrate** — Hermes accumulates memory in Postgres across sessions instead of starting cold every time.

The stack must be cheap to run idle, portable between the two reference machines, and not depend on any cloud service besides the Anthropic API (and Telegram/Discord, if those bridges are enabled).

---

## Reference Hardware

| Machine | OS              | RAM   | GPU             |
| ------- | --------------- | ----- | --------------- |
| Desktop | Arch Linux      | 32 GB | 8–10 GB VRAM    |
| Laptop  | Windows 10 + WSL 2 (Arch) | 32 GB | 8–10 GB VRAM (NVIDIA assumed) |

Both machines must run the same compose stack with the same `.env` schema. Differences are confined to host setup (documented in README).

---

## Core Features (in scope)

1. **Hermes Agent container** — Nous Research Hermes, thin Claude API client, talks to Postgres + Redis.
2. **Persistent memory** — Postgres schema for conversation history, facts, and agent-authored notes; Redis for hot-path cache.
3. **Capability Server** — FastAPI service exposing Linux automation endpoints (shell, notify, systemd, file ops). Single contract, single port.
4. **OpenClaw bridge** — Telegram + Discord adapters, forwarding messages to Hermes and posting replies.
5. **Claude Code workflow** — `CLAUDE.md`, slash commands, and hooks tuned for working on *this* repo from the host.
6. **Local inference (optional)** — llama.cpp / Ollama service that Hermes can route cheap tasks to, using the GPU. Off by default; on when the user opts in.

## Non-Goals (out of scope, for now)

- Multi-user / multi-tenant operation.
- Cloud deployment (Kubernetes, managed Postgres, etc.).
- Mobile clients beyond the existing Telegram/Discord surfaces.
- Voice / audio I/O.
- macOS support (dropped from the original Mac mini plan).
- Replacing Claude API with a fully local model. Local inference is a *complement*, not a substitute.

---

## Architecture

```
                ┌──────────────────────────────┐
                │      Anthropic API           │
                └──────────────▲───────────────┘
                               │
┌──────────────┐         ┌─────┴──────┐         ┌──────────────┐
│   Telegram   │◀───────▶│  OpenClaw  │◀───────▶│    Hermes    │
│   Discord    │         └────────────┘         │    Agent     │
└──────────────┘                                 └──────┬───────┘
                                                        │
                          ┌──────────────┬──────────────┼──────────────┐
                          ▼              ▼              ▼              ▼
                   ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐
                   │  Postgres  │ │   Redis    │ │ Capability │ │ Local LLM  │
                   │  (memory)  │ │  (cache)   │ │  Server    │ │ (optional) │
                   └────────────┘ └────────────┘ └─────┬──────┘ └────────────┘
                                                       │
                                                       ▼
                                              Linux host (systemd,
                                              D-Bus, shell, files)

   Claude Code  ──── runs on host, edits this repo, shells out to `docker compose`
```

### Service responsibilities

- **Hermes Agent** — orchestrator. Owns the loop, the prompts, the routing decision (Claude API vs local LLM), and the memory writes.
- **Postgres** — durable store: conversation transcripts, distilled memories, capability audit log.
- **Redis** — ephemeral: in-flight context windows, rate-limit counters, dedup keys.
- **Capability Server** — the *only* path from the agent to the host OS. Every privileged action is an HTTP call here so it can be logged, rate-limited, and authz'd. No direct shelling from Hermes.
- **OpenClaw** — protocol adapters; no business logic. Translates platform messages ↔ Hermes's internal message shape.
- **Local LLM (optional)** — exposed as an OpenAI-compatible endpoint so Hermes can swap providers via config alone.

### Cross-cutting decisions

- **Single compose file** drives the whole stack. Profiles (`--profile local-llm`, `--profile bridges`) toggle optional services.
- **All secrets via `.env`**, never committed. `.env.example` is the schema source of truth.
- **Postgres volume is the only stateful asset** that matters. Backup story = `pg_dump` cron + offsite copy.
- **No service binds to `127.0.0.1` inside compose** — bind `0.0.0.0` so WSL host-Windows access works without per-service overrides.
- **Capability Server is the security boundary.** It validates inputs, enforces a command allowlist, and writes an audit row to Postgres for every call.

---

## Data Model (sketch)

Postgres tables (concrete schema lives in a later phase):

- `conversations(id, channel, started_at, ended_at)`
- `messages(id, conversation_id, role, content, tokens, created_at)`
- `memories(id, kind, content, embedding, source_message_id, created_at)` — agent-authored long-term notes.
- `capability_audit(id, endpoint, payload, result, caller, created_at)`

Embedding column uses `pgvector` if present; otherwise text-only memory in v1.

---

## Risks & Open Questions

- **Hermes upstream churn** — Nous Research's Hermes releases move fast. Pin a specific tag in compose.
- **OpenClaw maturity** — confirm it supports both Telegram and Discord in one process, or run two instances.
- **WSL 2 GPU on Windows 10** — works for NVIDIA in current driver lines, but Windows 10 is EOL on 2025-10-14; plan a Windows 11 migration note before then.
- **Local LLM memory pressure** — 6–9 GB VRAM + Postgres + Hermes is tight under load. Profile before promoting local inference from "optional" to "default".
- **Self-improvement loop scope** — "self-improving" is vague. v1 means: Hermes writes its own memory rows and can recall them; it does not mean autonomous code changes to itself.

---

## Success Criteria for v1

- `docker compose up -d` on a fresh Arch (or WSL Arch) box brings the stack up green.
- A message sent on Telegram reaches Hermes, gets a Claude-generated reply, and is persisted in Postgres.
- The Capability Server can execute one allowlisted shell command end-to-end with an audit row written.
- Claude Code can be run in the repo root and successfully edit a file based on a request.
- Memory survives `docker compose down && docker compose up -d`.

Anything beyond this is v2.
