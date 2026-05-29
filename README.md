# Auto-Agent / Arch Linux AI Orchestration Stack

> **Developer truth.** This file describes how the stack *actually* installs and
> runs as of **May 2026**. The full blueprint and rationale live in
> [PLAN.md](PLAN.md). If something here disagrees with older notes, this file wins.

## Overview

A self-hosted AI agent stack for **Arch Linux** (desktop, bare metal). Two pieces,
one job each:

- **Hermes Agent** (Nous Research, `v0.14.0` / `v2026.5.16`) — the **brain**.
  Autonomous agent with persistent memory (SQLite + FTS5), 40+ tools, MCP, a
  skills system, and Claude API for inference (built-in 1-hour prompt caching).
- **OpenClaw** — the **front door**. A self-hosted messaging gateway that bridges
  Telegram/Discord (and Signal, Matrix, Slack, …) to an agent backend. We point it
  at Hermes as an **external agent runtime** rather than using its bundled agent.
- **Claude Code** — developer-facing CLI on the host, for working on *this* repo.

```
 Telegram / Discord
        │
        ▼
 ┌──────────────┐  external agent runtime   ┌──────────────────────────┐
 │   OpenClaw   │ ────────────────────────▶ │       Hermes Agent       │
 │  (gateway)   │  (ACP / custom backend)   │  • Claude API (inference)│
 │ npm, Node 24 │ ◀──────────────────────── │  • SQLite/FTS5 memory    │
 └──────────────┘        replies            │  • 40+ tools, MCP, skills│
        ▲                                    └────────────┬─────────────┘
        │ Control UI 127.0.0.1:18789                      │ tool calls
        │                                                 ▼
        │                                   ┌──────────────────────────┐
        │                                   │  Linux host (sandboxed)  │
        │                                   │  bubblewrap + systemd     │
        │                                   └──────────────────────────┘
 Claude Code ── runs on host, edits this repo (separate from the runtime)
```

### Why this shape

Both Hermes and OpenClaw ship a *full* agent **and** a multi-channel gateway, so
running both "as agents" is redundant. We split roles: **OpenClaw owns the chat
channels, Hermes owns the thinking and memory.** See
[PLAN.md › Architecture](PLAN.md#architecture) for the decision record.

### What changed from the original draft (correcting May-2026 reality)

- Hermes is **not** a thin Claude client needing Postgres — it has its own
  **SQLite/FTS5** memory. Postgres/Redis are dropped from the core stack.
- Both tools install **natively** (pip / npm) and run as **systemd services**, not
  primarily as Docker containers.
- **WSL 2 / Windows path removed.** Windows 10 is EOL (2025-10-14; ESU only to
  2026-10-13). The stack targets Arch desktop only.

---

## Target Hardware

**Desktop (Arch Linux)** — 32 GB RAM, 8–10 GB VRAM GPU, modern multi-core CPU.

Native services are light; the headroom buys you an **optional local LLM** for
cheap/offline routing.

| Component             | RAM budget          | Notes                                   |
| --------------------- | ------------------- | --------------------------------------- |
| Hermes Agent          | ~2–4 GB             | Claude API client + local tooling       |
| OpenClaw gateway      | ~0.5–1 GB           | Node process + channel adapters         |
| Local LLM (optional)  | ~2 GB RAM + 6–9 GB VRAM | llama.cpp / Ollama, OpenAI-compatible |
| Host reserve          | the rest            | OS, browser, Claude Code, builds        |

### GPU (only if you enable local inference)

- **NVIDIA**: `nvidia`, `nvidia-utils`. For Ollama: `ollama-cuda`. Verify `nvidia-smi`.
- **AMD**: ROCm packages (`rocm-hip-runtime`); works with llama.cpp and Ollama.

---

## Prerequisites

```bash
sudo pacman -Syu
sudo pacman -S --needed git base-devel python python-pip nodejs npm \
                        bubblewrap ufw restic jq
# Python 3.11 specifically for Hermes — install via uv if your system python is newer:
sudo pacman -S --needed uv
```

Optional local inference:

```bash
sudo pacman -S --needed ollama        # or build llama.cpp
# NVIDIA: sudo pacman -S ollama-cuda
```

Install **Claude Code** on the host per the current installer:
<https://docs.claude.com/claude-code>.

---

## Install

### 0. Dedicated service user (recommended)

Run the runtime as an unprivileged user, separate from your login account:

```bash
sudo useradd -m -s /usr/bin/bash agent
sudo loginctl enable-linger agent      # lets user services run without an active login
```

Everything below runs **as `agent`** (`sudo -iu agent`) unless noted. Claude Code
runs as **you** (`casey`) in the repo.

### 1. Clone & configure

```bash
git clone <this-repo> ~/Apps/Auto-Agent
cd ~/Apps/Auto-Agent
cp .env.example .env       # fill in ANTHROPIC_API_KEY, TELEGRAM_TOKEN, DISCORD_TOKEN
chmod 600 .env             # secrets are 0600, never committed
```

### 2. Install Hermes (the brain)

```bash
# Pinned install — do not float to latest blindly.
uv venv ~/.hermes/venv --python 3.11
~/.hermes/venv/bin/pip install 'hermes-agent==0.14.0'
~/.hermes/venv/bin/hermes --version    # expect v2026.5.16
```

Configure Hermes for Claude API inference and local SQLite memory (see
[deploy/hermes/](deploy/hermes/) for the config template). Key points:

- Model provider → Anthropic, your `ANTHROPIC_API_KEY`.
- Memory → default SQLite store under `~/.hermes/` with WAL mode enabled.
- Expose Hermes as an agent endpoint on **127.0.0.1** only (no LAN binding).

### 3. Install OpenClaw (the front door)

```bash
# Node 24 (or 22.19+ LTS)
npm install -g openclaw@latest
openclaw onboard --install-daemon       # writes ~/.openclaw/openclaw.json + user service
```

Then edit `~/.openclaw/openclaw.json` to:

- Point the **agent runtime at Hermes** (external/ACP backend → Hermes's local
  endpoint), instead of OpenClaw's bundled agent.
- Enable **Telegram** and **Discord** channels with tokens from `.env`.
- **Allowlist** senders/chat IDs and set `requireMention` for group chats.
- Keep the Control UI on its default `http://127.0.0.1:18789/` (loopback only).

### 4. Run as systemd user services (hardened)

Hardened unit skeletons live in [deploy/systemd/](deploy/systemd/):

```bash
mkdir -p ~/.config/systemd/user
cp ~/Apps/Auto-Agent/deploy/systemd/*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now hermes.service openclaw.service
systemctl --user status hermes openclaw
journalctl --user -u hermes -f
```

The units apply `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=read-only`
(with explicit `ReadWritePaths`), `PrivateTmp`, a `SystemCallFilter`, an empty
`CapabilityBoundingSet`, and `MemoryMax`/`CPUQuota` caps. Shell-style tools run
inside a `bubblewrap` jail (see `deploy/bin/sandbox-shell`).

### 5. Lock down the network

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
# No inbound ports are opened. Control UI + Hermes endpoint stay on loopback.
```

If you need remote access, front it with an authenticated reverse proxy or a
Tailscale/WireGuard tunnel — **never** expose the Control UI or Hermes port to the
LAN/Internet directly.

### 6. Run Claude Code against the repo

```bash
cd ~/Apps/Auto-Agent
claude
```

Claude Code runs on the host as you, edits files directly, and shells out to
`systemctl --user` / git. It is *not* part of the agent runtime.

---

## Backups (the only stateful asset)

Hermes's SQLite memory is the thing worth protecting.

```bash
# Snapshot + offsite via restic (scheduled by deploy/systemd/hermes-backup.timer)
restic -r <repo> backup ~/.hermes/   # excludes WAL/-shm, see deploy/backup/
```

Use `litestream` for continuous replication if you want point-in-time recovery.
Verify restores periodically — an untested backup is not a backup.

---

## Components

### Hermes Agent (brain)
Autonomous agent. Claude API inference with built-in prompt caching, SQLite/FTS5
persistent memory, 40+ tools, MCP, agentskills.io-compatible skills. Pinned to
`v0.14.0`. Runs sandboxed as the `agent` user.

### OpenClaw (front door)
Messaging gateway. Telegram + Discord adapters (extensible to Signal/Matrix/Slack).
Routes inbound messages to Hermes as an external agent runtime and posts replies
back. Sender allowlists + group mention rules enforced in `openclaw.json`.

### Local LLM (optional)
Ollama or llama.cpp exposing an OpenAI-compatible endpoint. Hermes routes cheap
tasks here via config; hard tasks still go to Claude. Off by default.

### Capability surface
Hermes's own tools *are* the host surface — hardened via the sandboxed systemd
unit + bubblewrap shell jail + command allowlist. (No separate FastAPI capability
server in v1; see [PLAN.md](PLAN.md) for why and when one would be added.)

---

## Security model (summary)

- **Least privilege**: dedicated unprivileged `agent` user; empty capability set.
- **Sandboxing**: systemd hardening directives + bubblewrap for shell tools.
- **Network**: default-deny firewall; all UIs/endpoints loopback-only.
- **Secrets**: `.env` at `0600`, loaded via systemd `EnvironmentFile`; never committed.
- **Allowlists**: OpenClaw sender/chat allowlist + group mention requirement.
- **Pinned versions**: Hermes and OpenClaw pinned; upgrades are deliberate.
- **Audit**: journald logs per service; review `journalctl --user -u hermes`.

Full threat model and phased hardening checklist: [PLAN.md](PLAN.md).

## Getting Started (TL;DR)

```bash
git clone <repo> && cd Auto-Agent && cp .env.example .env && $EDITOR .env && chmod 600 .env
sudo -iu agent     # run the runtime as the service user
#   install Hermes (pinned) + OpenClaw, configure OpenClaw→Hermes, enable systemd units
claude             # as yourself, in the repo root
```

## License

MIT
