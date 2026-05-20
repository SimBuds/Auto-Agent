# Arch Linux Autonomous Agent Stack — May 2026

## Context

```markdown
This deployment plan configures a 24/7 autonomous agent stack optimized for a high-performance Arch Linux workstation (Ryzen 9 5900X, RTX 3080 10 GB, 32 GB RAM, Btrfs, KDE Plasma/Wayland, Zen kernel). 

**Core Architectural Decisions:**
- **Inference Engine:** External cloud routing via the Claude API. Local Ollama setups are partitioned away from this configuration stack; the 10 GB RTX 3080 and local LLM runtime parameters remain uninhibited and available for standalone experiments.
- **Communication Channels:** Two-way integration with Telegram and Discord via the OpenClaw gateway.
- **Host Integration Layer:** A native Python FastAPI loopback bridge running on the host OS. This bridge translates incoming agent instructions into local Linux actions using native D-Bus protocols and Wayland workspace utilities.
- **Lifecycle Management:** Managed entirely via **systemd --user** units paired with `loginctl enable-linger` to ensure the agent stack initializes at boot time and runs continuously without needing an open graphical desktop session.

The 32 GB RAM footprint provides a highly comfortable runtime ceiling. Container memory limits are set generously to utilize available system headroom without risking swap thrashing.
```

## Architecture

```
            Claude API (Cloud Inference)
                      │
                      ▼
          Hermes Agent (Planning + Skills)
                      │
      ┌───────────────┼───────────────┐
      ▼                               ▼

```

---

Docker Terminal Backend        OpenClaw Gateway
(Sandboxed Tool Exec)          (Telegram + Discord)
│
▼
FastAPI Capability Server (Host, 127.0.0.1:9000)
│
▼
D-Bus / KDE Plasma (Notifications, KMail, Kalendar, Clipboard)

```

---

## Deployment Steps

### 1. Pacman & AUR Prerequisites

Verify the system package baseline. The following underlying applications and drivers must be present on the host system: `docker`, `docker-compose`, `git`, `wget`, `python-pip`, `uv`, `fnm-bin`, `yay`, `ufw`, `snapper`, `cuda`, and `nvidia-open-dkms`. 

Install the missing operational utilities and specific communication libraries:

```bash
sudo pacman -S --needed jq tmux btop libnotify wl-clipboard
# libnotify provides notify-send for system notifications.
# wl-clipboard enables command-line interaction with the Wayland clipboard.

# Node.js runtime management via the fnm-managed environment
fnm install 24 && fnm default 24
npm install -g pnpm

```

Configure the local Docker engine and add your user account to the container group to bypass explicit root evaluation:

```bash
sudo systemctl enable --now docker.service
sudo usermod -aG docker casey      # Log out and back in for group membership to apply

```

Generate an explicit fallback system recovery snapshot via Snapper prior to modifying workspace directories:
`sudo snapper -c root create -d "pre ai-stack install"`

### 2. Configure Systemd User Persistence

Set up systemd user session lingering. This forces the system manager to spawn and retain a dedicated systemd user instance for your account right at boot time:

```bash
sudo loginctl enable-linger casey
mkdir -p ~/.config/systemd/user

```

### 3. File System Layout

Establish the structured workspace directory tree under your home directory:

```
~/ai-stack/
├── capability-server/      # FastAPI host gateway (Native Python environment)
├── shared/
│   ├── postgres/           # Database volume mount
│   ├── redis/              # Cache volume mount
│   └── workspace/          # Sandboxed agent runtime sandbox
├── logs/                   # Service log targets
├── secrets/                # Environment configuration files (chmod 600)
└── docker-compose.yml
~/.hermes/                  # Agent state parameters and skill databases
~/.openclaw/                # OpenClaw configuration and workspace profiles

```

### 4. Secret Storage Management

Create a private environment variable storage block at `~/ai-stack/secrets/anthropic.env`. Use standard system tools (`wl-copy` or a manual layout) to write the parameters securely:

```env
ANTHROPIC_API_KEY=your_actual_claude_api_key_here
POSTGRES_USER=hermes
POSTGRES_DB=hermes
POSTGRES_PASSWORD=generate_a_secure_password_via_openssl

```

Secure the file access matrix immediately: `chmod 600 ~/ai-stack/secrets/anthropic.env`.

### 5. Docker Compose Infrastructure

Construct the primary multi-container container network configuration. Save this file as `~/ai-stack/docker-compose.yml`:

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:18-alpine
    container_name: ai-postgres
    restart: always
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - ~/ai-stack/shared/postgres:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:5432:5432"

  redis:
    image: redis:7-alpine
    container_name: ai-redis
    restart: always
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - ~/ai-stack/shared/redis:/data

  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: ai-hermes
    restart: always
    mem_limit: 4g
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      - REDIS_URL=redis://redis:6379/0
    volumes:
      - ~/ai-stack/shared/workspace:/workspace
      - ~/.hermes:/root/.hermes
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "127.0.0.1:8000:8000"

```

*Note: The `extra_hosts` declaration mapping to `host-gateway` is explicitly required on native Linux Docker engines so that internal container workloads can dynamically reach back out to services listening on the host's loopback network interface.*

### 6. Core Agent Configuration

Write the primary routing configuration file to `~/.hermes/config.yaml`:

```yaml
inference:
  provider: anthropic
  model:
    default: claude-opus-4-7

```

### 7. Native Host Capability Server

The Capability Server bridges isolated agent operations to the physical Linux desktop landscape using explicit system subprocess executions and standardized **D-Bus** inter-process calls.

Create the main implementation script at `~/ai-stack/capability-server/capability_server.py`:

```python
import subprocess
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="Arch Linux Host Capability Bridge")

class NotificationPayload(BaseModel):
    title: str
    body: str

class MailPayload(BaseModel):
    to: str
    subject: str
    body: str

@app.post("/notify")
async def send_notification(payload: NotificationPayload):
    try:
        # Calls the system notification server over the user D-Bus interface
        subprocess.run(["notify-send", payload.title, payload.body], check=True)
        return {"status": "success"}
    except subprocess.CalledProcessError as e:
        return {"status": "logged_offline_or_failed", "detail": str(e)}

@app.post("/clipboard/set")
async def set_clipboard(text: str):
    try:
        # Native Wayland clipboard pipe sequence
        process = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE, text=True)
        process.communicate(input=text)
        return {"status": "success"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/file/open")
async def open_file(path: str):
    try:
        # Secure execution utilizing list array definitions to bypass shell injection risk
        subprocess.run(["xdg-open", path], check=True)
        return {"status": "success"}
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=str(e))

# Placeholder D-Bus hooks for native KDE application access
@app.post("/mail/send")
async def send_kmail(payload: MailPayload):
    # Route into org.kde.kmail2 via dbus-next or fallback mail utilities
    return {"status": "stubbed", "message": "D-Bus mail channel active"}

```

> [!WARNING]
> **Headless Session Resilience Strategy:** Because systemd linger starts this Python process ahead of the graphical KDE Plasma display initialization, desktop-interactive functions (`/notify`, `/clipboard/set`) must run defensively. The endpoints must handle missing graphical displays gracefully without crashing the parent process loop.

Initialize the local Python dependencies:

```bash
cd ~/ai-stack/capability-server
uv venv .venv
source .venv/bin/activate
uv pip install fastapi uvicorn pydantic dbus-next

```

### 8. OpenClaw Setup

Install the messaging gateway and configure the system user units:

```bash
pnpm add -g openclaw@latest
openclaw onboard --install-daemon

```

Verify or manually generate the service configuration block if the internal helper fails to export a valid file to `~/.config/systemd/user/openclaw.service`. Ensure your target `~/.openclaw/openclaw.json` configuration configures your channels precisely:

* Pin `maxConcurrentBrowsers: 1`.
* Activate only `["telegram", "discord"]` within your communications matrix.
* Set internal system model parsing defaults directly to `anthropic/claude-opus-4-7`.

### 9. Systemd User Service Layer

Write the two companion initialization files to target `~/.config/systemd/user/`:

**`capability-server.service`**

```ini
[Unit]
Description=Arch Linux Host Capability Bridge Service
After=network.target

[Service]
Type=simple
WorkingDirectory=%h/ai-stack/capability-server
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStart=%h/ai-stack/capability-server/.venv/bin/uvicorn capability_server:app --host 127.0.0.1 --port 9000
Restart=on-failure

[Install]
WantedBy=default.target

```

*(Verify your actual system UID by running `id -u` and adjust the `1000` runtime assignment if necessary.)*

**`ai-stack.service`**

```ini
[Unit]
Description=Docker Compose Container Agent Stack Container Lifecycle
After=network.target capability-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=%h/ai-stack
EnvironmentFile=%h/ai-stack/secrets/anthropic.env
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=default.target

```

Reload and activate the unit matrix:

```bash
systemctl --user daemon-reload
systemctl --user enable --now capability-server.service ai-stack.service

```

### 10. Automated Maintenance Infrastructure

* **Automated Restarts:** Implement a clean systemd timer loop instead of old cron systems. Create `~/.config/systemd/user/ai-stack-restart.timer`:
```ini
[Unit]
Description=Daily 3AM Automated Restart Cycle for Agent Containers

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target

```


Pair it with a trivial companion service unit (`ai-stack-restart.service`) executing `ExecStart=/usr/bin/docker compose restart` inside your target working directory.
* **Storage Housekeeping:** Prune stale Docker cache layers monthly via system units: `docker builder prune -af && docker image prune -af`.
* **Btrfs Monitoring:** Track file system space utilization regularly using `btrfs filesystem usage /`. Ensure `/var/lib/docker` does not bloat your system recovery configurations by verifying it is excluded from root Snapper configuration profiles.

---

## Post-Deployment Validation

Execute the formal verification verification sequence to confirm operational status:

1. **Service Verification Matrix:**
Verify user management layer execution: `systemctl --user status capability-server ai-stack openclaw`.
Verify active operational container loops: `docker compose -f ~/ai-stack/docker-compose.yml ps`.
2. **Local Loopback Communication Pipe:**
```bash
curl -X POST 127.0.0.1:9000/notify -d '{"title":"System Status","body":"Bridge Initialization Complete"}' -H 'content-type: application/json'

```


*Note: If testing while logged into a terminal session directly (TTY mode), verify the call returns a valid JSON exit signature without a hard application fault. The actual system visual desktop notification will surface when you initialize your standard KDE graphical workspace.*
3. **External Model Inference Path:**
`docker compose exec hermes hermes chat "say hi"`.
4. **Internal Container Network Bridge Test:**
Instruct the Hermes service over its CLI interaction window to emit a localized desktop notification. Confirm the message traverses the container network perimeter via `host.docker.internal:9000` and displays correctly on your host workspace.
5. **Channel Access Confirmations:**
Validate external message processing by issuing direct verification messages over your Telegram and Discord channels.
6. **Headless Clean Boot Test:**
Issue a hardware `reboot` command. Log directly into an un-accelerated alternative shell terminal profile (TTY mode) without executing any display configuration setups or loading Plasma. Run `systemctl --user status` and confirm the entire background processing environment is fully active automatically without an open graphical session context.
7. **Resource Utilization:**
Launch `btop`. Confirm the total un-cached system operational memory footprint sits comfortably under 10 GB when idling.
