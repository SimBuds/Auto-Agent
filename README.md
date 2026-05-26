# Auto-Agent / Arch Linux AI Orchestration Stack

## Overview

A self-improving AI agent orchestration stack targeting **Arch Linux** as the primary host, with an **optional WSL 2** pathway for Windows users. The stack runs:

- **Hermes Agent** (Nous Research) — core agent, Claude API for inference
- **OpenClaw** — Telegram/Discord bridge
- **Claude Code** — developer-facing CLI/agent for working on the repo itself

Capabilities are Linux-native: systemd, D-Bus, `notify-send`, and Signal/Matrix bridges (Telegram/Discord via OpenClaw).

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                Docker / Podman Compose                  │
├─────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │ Hermes Agent│  │  Postgres   │  │    Redis        │  │
│  │ (Claude API)│  │  (Memory)   │  │   (Cache)       │  │
│  └─────────────┘  └─────────────┘  └─────────────────┘  │
│  ┌─────────────┐  ┌─────────────────────────────────┐   │
│  │  OpenClaw   │  │  Capability Server (FastAPI)    │   │
│  │ (TG/Discord)│  │  (Linux automation surface)     │   │
│  └─────────────┘  └─────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
            ▲
            │ host CLI
   ┌────────┴────────┐
   │   Claude Code   │  (runs on the host, edits this repo)
   └─────────────────┘
```

## Target Hardware

Two reference machines:

- **Desktop (Arch Linux)** — 32 GB RAM, 8–10 GB VRAM GPU, modern multi-core CPU
- **Laptop (Windows 10 + WSL 2)** — same class: 32 GB RAM, 8–10 GB VRAM, modern CPU

With 32 GB and a real GPU, you have headroom to either (a) keep Claude API as the only inference path and use the spare RAM as cache/buffer, or (b) run a **local model alongside** Hermes (e.g. a quantized 7–13B in ~6–9 GB VRAM) for cheap/offline tasks and route hard tasks to Claude.

Suggested allocation (Path A or B, host or WSL VM):

| Component          | RAM budget | Notes                                  |
| ------------------ | ---------- | -------------------------------------- |
| Hermes Agent       | ~4 GB      | thin client to Claude API              |
| Local LLM runtime  | ~2 GB RAM + 6–9 GB VRAM | optional; llama.cpp / Ollama / vLLM |
| Postgres           | ~6 GB      | bumped — you have the RAM              |
| Redis              | ~3 GB      |                                        |
| Capability Server  | ~1 GB      |                                        |
| OpenClaw           | ~0.5 GB    |                                        |
| Host / VM reserve  | ~8 GB      | OS, browser, Claude Code, build tools  |

On WSL 2 this budget applies **inside the VM** — cap it explicitly in `.wslconfig` (below) so Windows keeps enough for itself.

### GPU notes

- **Arch (desktop)**: NVIDIA → `nvidia`, `nvidia-utils`, `nvidia-container-toolkit`, then `--gpus all` in compose. AMD → ROCm packages, works with llama.cpp and Ollama.
- **WSL 2 (laptop)**: NVIDIA GPU passthrough works on Windows 10 21H2+ with a recent NVIDIA driver (the Windows driver provides `/usr/lib/wsl/lib/libcuda.so.1` inside the distro — do **not** install a Linux NVIDIA driver in WSL). AMD GPU passthrough in WSL is effectively unsupported; if the laptop is AMD, plan to use Claude API only on that box.

---

## Path A: Arch Linux (primary)

### 1. Prerequisites

```bash
sudo pacman -Syu
sudo pacman -S --needed docker docker-compose git base-devel python uv
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # log out / back in
```

Optional (rootless): use `podman` + `podman-compose` instead; the compose file is compatible.

Install Claude Code on the host:

```bash
# follow https://docs.claude.com/claude-code for the current installer
```

### 2. Clone & configure

```bash
git clone <this-repo> ~/Apps/Auto-Agent
cd ~/Apps/Auto-Agent
cp .env.example .env   # fill in ANTHROPIC_API_KEY, TELEGRAM_TOKEN, DISCORD_TOKEN
```

### 3. Bring up the stack

```bash
docker compose up -d
docker compose ps
docker compose logs -f hermes
```

Capability server: `http://localhost:8000/docs`
Postgres: `localhost:5432`  Redis: `localhost:6379`

### 4. Run Claude Code against the repo

```bash
cd ~/Apps/Auto-Agent
claude
```

Claude Code runs on the host (not in a container) so it can edit files directly and shell out to `docker compose`.

### 5. Optional: run components as systemd user units

If you don't want Docker managing lifecycle, the agent and capability server can run as `systemctl --user` units. Skeleton units live in `deploy/systemd/` (to be added).

---

## Path B: WSL 2 (optional)

Everything above works inside a WSL 2 Arch (or Ubuntu) distro **with these deltas**:

### B.1 Install WSL + Arch (Windows 10)

Windows 10 needs version **21H2 or later** for modern WSL 2 (and for NVIDIA GPU passthrough). Check with `winver`.

```powershell
# PowerShell, admin
wsl --install                 # installs WSL 2 + default distro
wsl --update                  # pull the latest kernel
wsl --set-default-version 2
# Arch isn't in the Store; use ArchWSL: https://github.com/yuk7/ArchWSL
```

If `wsl --install` is unavailable on your build, enable the features manually:
```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```
then install the WSL 2 kernel update MSI from Microsoft and reboot.

### B.2 Tune the VM — required

Create `C:\Users\<you>\.wslconfig`:

```ini
[wsl2]
memory=20GB          # leave ~12 GB for Windows on a 32 GB laptop
processors=6
swap=8GB
localhostForwarding=true
# nestedVirtualization=true   # only if you need it
```

Then `wsl --shutdown` and reopen. Without this, the VM grabs ~50% of host RAM and Windows fights Postgres/Redis for pages.

### B.3 Enable systemd

In the distro, edit `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

`wsl --shutdown`, reopen. Needed if you use the systemd user-unit path.

### B.4 Docker

Two options:

- **Docker Desktop for Windows** with WSL integration enabled — easiest. On Windows 10 it needs a recent build; check Docker Desktop's release notes for the current minimum.
- **Native `docker` inside the distro** — `sudo pacman -S docker && sudo systemctl enable --now docker`. Requires the systemd step above. Lighter; preferred if you don't already use Docker Desktop.

### B.4a GPU passthrough (NVIDIA only)

If the laptop has an NVIDIA GPU and you want local inference inside WSL:

1. Install the latest **Windows** NVIDIA driver (it ships the WSL CUDA shim).
2. Inside the distro, install CUDA *userspace* libs only — never the Linux kernel driver:
   ```bash
   sudo pacman -S cuda
   ```
3. For containerized GPU use: `sudo pacman -S nvidia-container-toolkit` and add `--gpus all` (or the compose equivalent) to the inference service.
4. Verify: `nvidia-smi` inside the distro should list the GPU.

AMD GPUs: skip — ROCm in WSL is not viable today. Use Claude API on that machine.

### B.5 Filesystem location — required

Keep the repo under the Linux home (`~/Apps/Auto-Agent`), **not** `/mnt/c/...`. Postgres on `/mnt/c` is 10–50× slower and breaks file locking.

### B.6 Networking

`localhost:8000` from Windows reaches the WSL VM on current builds. Inside compose, bind services to `0.0.0.0`, not `127.0.0.1`, so Windows-side tools (browser, Claude Code on Windows if you use it that way) can reach them.

### B.7 Claude Code

Run Claude Code **inside the WSL distro**, not on Windows, so paths and shell commands match what the containers see.

### Summary of WSL-only steps

| Step                 | Arch bare-metal | WSL 2                          |
| -------------------- | --------------- | ------------------------------ |
| Install OS           | normal install  | `wsl --install` + ArchWSL      |
| RAM/CPU limits       | N/A             | `.wslconfig` required          |
| Enable systemd       | default         | `/etc/wsl.conf` `systemd=true` |
| Docker               | `pacman -S`     | Desktop *or* in-distro         |
| Repo location        | anywhere        | must be on ext4, not `/mnt/c`  |
| Claude Code location | host            | inside the distro              |

Everything else (compose, env, Hermes, OpenClaw, capability server) is identical.

---

## Components

### Hermes Agent
Core agent, Claude API for inference, Postgres for long-term memory, Redis for cache.

### OpenClaw
Telegram + Discord bridge. Reads bot tokens from `.env`. Forwards messages to Hermes and posts replies back.

### Capability Server (FastAPI)
Linux automation surface. Initial endpoints:
- `POST /shell` — sandboxed command execution
- `POST /notify` — desktop notification via `notify-send` (Arch) / Windows toast bridge (WSL, optional)
- `POST /systemd` — start/stop/status of user units

### Postgres / Redis
Standard images, volumes persisted under `./data/`.

## Implementation Phases

1. **Infra** — compose file, `.env.example`, volumes, healthchecks
2. **Hermes** — container + Claude API wiring + memory schema
3. **Capability server** — FastAPI scaffold + Linux endpoints
4. **OpenClaw** — Telegram + Discord adapters
5. **Claude Code workflow** — `CLAUDE.md`, slash commands, hooks for the repo
6. **Hardening** — resource limits, restart policies, log rotation, backup of Postgres volume

## Getting Started (TL;DR)

```bash
git clone <repo> && cd Auto-Agent
cp .env.example .env && $EDITOR .env
docker compose up -d
claude                       # in the repo root
```

WSL 2 users: do the `.wslconfig` + `wsl.conf` + ext4 steps first.

## License

MIT
