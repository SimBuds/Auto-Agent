# IMPLEMENT.md — Execution Engine

Granular, phase-by-phase execution for Auto-Agent. Blueprint: [PLAN.md](PLAN.md).
Developer truth: [README.md](README.md). Workflow contract: [AGENTS.md](AGENTS.md).

> **Status:** Awaiting approval of this plan (Phase 2 of the contract). No code
> written yet.

---

## Scope split: repo artifacts vs. host actions

This repo produces **scaffolding** (config templates, systemd units, scripts).
The **host mutations** that actually stand the stack up are run by the operator on
the Arch box and are **Risky-tier** — each is gated on explicit approval, never run
as a side effect of authoring scaffolding.

| Repo artifacts (authored here)                          | Host actions (operator runs, gated)                     |
| ------------------------------------------------------- | ------------------------------------------------------- |
| `.env.example`, `.gitignore`                            | `pacman -S …` package installs                          |
| `deploy/hermes/` config template                        | `useradd agent` + `loginctl enable-linger`              |
| `deploy/openclaw/` config template                      | `pip install hermes-agent==…`, `npm i -g openclaw`      |
| `deploy/systemd/*.service`, `*.timer`                   | `ufw enable`, `systemctl --user enable --now …`         |
| `deploy/bin/sandbox-shell` (bubblewrap)                 | providing real bot tokens / API key                     |
| `deploy/backup/` restic script + restore drill          | running the end-to-end message round-trip               |
| `deploy/host-setup.sh` (documents host steps, not auto) |                                                         |

**Walking-skeleton note:** A true end-to-end round-trip (Telegram → Hermes →
Claude → reply) needs the host installs + live tokens, which are operator actions.
So the repo skeleton delivers the *config schema and contracts* end-to-end first
(Phase 1), and later phases thicken each component. Full E2E validation is its own
gated phase (Phase 8) once the operator has installed and provided secrets.

---

## Reuse audit (global)

- Search: `ls -R deploy` → directory absent. `git ls-files` → `AGENTS.md`,
  `PLAN.md`, `README.md` only. No existing scripts, configs, or units.
- Conclusion: greenfield. Nothing to reuse. Each phase re-runs a targeted search
  before introducing a new artifact and records it inline.

---

## Phases

### Phase 1 — Repo scaffolding & config schema  ⬜
- **Goal:** Establish the directory layout and the secret/config schema every later
  phase references.
- **Files to add:** `.env.example`, `.gitignore`, `deploy/README.md` (layout map),
  `deploy/.gitkeep` placeholders for `hermes/ openclaw/ systemd/ bin/ backup/`.
- **Reuse check:** no `.env*` or `.gitignore` present (`ls -la .env* .gitignore`).
- **Verify (≤3):**
  1. `.env` is git-ignored (`git check-ignore .env` returns `.env`).
  2. `.env.example` lists exactly `ANTHROPIC_API_KEY`, `TELEGRAM_TOKEN`,
     `DISCORD_TOKEN` (+ documented optionals) and is committable (no secrets).
  3. `tree deploy` (or `ls -R deploy`) shows the five subdirs.

### Phase 2 — Hermes config template  ⬜
- **Goal:** Provide a verified Hermes config template wiring Anthropic inference +
  SQLite/WAL memory + loopback endpoint.
- **Pre-step:** Verify Hermes config file format/keys against current Hermes docs
  (do not invent keys). Record the doc URL + confirmed keys in `deploy/hermes/README.md`.
- **Files to add:** `deploy/hermes/config.<verified-ext>`, `deploy/hermes/README.md`.
- **Reuse check:** `ls deploy/hermes`.
- **Verify (≤3):**
  1. Config references `${ANTHROPIC_API_KEY}` (no inline secret).
  2. Memory/store path under `~/.hermes/` with WAL noted; endpoint bound `127.0.0.1`.
  3. If Hermes ships a config validator/dry-run, it parses clean; else schema keys
     cited from docs in the README.

### Phase 3 — OpenClaw config template (→ Hermes backend)  ⬜
- **Goal:** Provide an `openclaw.json` template routing to Hermes as the external
  agent runtime with Telegram+Discord, allowlists, and loopback Control UI.
- **Pre-step:** Verify against current OpenClaw docs: the external/ACP agent-runtime
  keys, how to disable the bundled agent, channel + allowlist + `requireMention`
  keys. Record doc URLs + confirmed keys in `deploy/openclaw/README.md`.
- **Files to add:** `deploy/openclaw/openclaw.json`, `deploy/openclaw/README.md`.
- **Reuse check:** `ls deploy/openclaw`.
- **Verify (≤3):**
  1. Agent runtime points at Hermes's loopback endpoint; bundled agent disabled.
  2. Telegram+Discord enabled via `${TELEGRAM_TOKEN}`/`${DISCORD_TOKEN}`; sender
     allowlist + group `requireMention` present.
  3. Control UI host = `127.0.0.1`.

### Phase 4 — Hardened systemd user units  ⬜
- **Goal:** Provide hardened `hermes.service` and `openclaw.service` user units.
- **Files to add:** `deploy/systemd/hermes.service`, `deploy/systemd/openclaw.service`.
- **Reuse check:** `ls deploy/systemd`.
- **Verify (≤3):**
  1. `systemd-analyze --user verify deploy/systemd/hermes.service` parses with no
     errors (and openclaw).
  2. Both units carry the PLAN security directives (NoNewPrivileges, ProtectSystem=
     strict, ProtectHome, PrivateTmp, SystemCallFilter, empty CapabilityBoundingSet,
     MemoryMax/CPUQuota/TasksMax) + `EnvironmentFile=` for `.env`.
  3. `systemd-analyze --user security` (if runnable) shows an improved exposure
     score vs. defaults (report number, not prediction).

### Phase 5 — Bubblewrap shell jail  ⬜
- **Goal:** Provide `sandbox-shell` wrapping shell-style tool execution in a
  `bwrap` jail with a command allowlist.
- **Files to add:** `deploy/bin/sandbox-shell`.
- **Reuse check:** `ls deploy/bin`.
- **Verify (≤3):**
  1. An allowlisted command (e.g. `echo`) runs inside the jail and succeeds.
  2. A denied command (e.g. `sudo`) is refused by the allowlist.
  3. Write outside the scoped writable dir fails (read-only rootfs proven).

### Phase 6 — Backups (restic) + restore drill  ⬜
- **Goal:** Provide a restic backup script + excludes + a `systemd` timer + a tested
  restore-drill doc for Hermes's SQLite store.
- **Files to add:** `deploy/backup/backup.sh`, `deploy/backup/excludes.txt`,
  `deploy/backup/RESTORE.md`, `deploy/systemd/hermes-backup.service`,
  `deploy/systemd/hermes-backup.timer`.
- **Reuse check:** `ls deploy/backup`.
- **Verify (≤3):**
  1. `backup.sh` against a throwaway sample dir creates a restic snapshot.
  2. Restore of that snapshot into a temp dir reproduces the sample file (drill
     output reported).
  3. `systemd-analyze --user verify` passes for the timer+service.

### Phase 7 — Host-setup script (documented, not auto-run)  ⬜
- **Goal:** Provide `host-setup.sh` capturing the gated host actions (packages,
  `agent` user, linger, ufw) as a reviewable script the operator runs deliberately.
- **Files to add:** `deploy/host-setup.sh`.
- **Reuse check:** `ls deploy/host-setup.sh`.
- **Verify (≤3):**
  1. `bash -n deploy/host-setup.sh` (syntax) passes.
  2. `shellcheck` clean (or documented exceptions).
  3. Script is non-destructive by default (idempotent guards; `--apply` flag gates
     real mutations) — confirmed by dry-run output.

### Phase 8 — Operator bring-up + E2E validation (gated)  ⬜
- **Goal:** With operator-provided secrets, install + enable the stack and prove the
  Telegram/Discord → Hermes → Claude → reply round-trip and memory persistence.
- **Files to touch:** none (or fixups logged as new phases). This phase is host
  execution + verification, run with the operator.
- **Verify (≤3):**
  1. A chat message gets a Claude-generated reply via OpenClaw→Hermes.
  2. The exchange persists in Hermes's SQLite memory across `systemctl --user
     restart hermes`.
  3. No inbound ports open (`ss -tlnp` shows loopback-only); a restic backup
     restores clean.

### Phase 9 — Claude Code workflow for this repo  ⬜
- **Goal:** Add `CLAUDE.md` + any slash commands/hooks tuned for working on this repo.
- **Files to add:** `CLAUDE.md` (+ `.claude/` as needed).
- **Verify (≤3):** Claude Code reads `CLAUDE.md`; one documented command/hook works.

### Phase 10 — Optional local LLM provider  ⬜ (deferred / opt-in)
- **Goal:** Document + template an Ollama OpenAI-compatible provider Hermes can route
  cheap tasks to. Off by default.
- **Files to add:** `deploy/local-llm/README.md` (+ provider config snippet).
- **Verify (≤3):** Hermes config snippet validates; profiling note recorded.

---

## Deferred / follow-ups
- (none yet — log here as new phases when discovered, never as code TODOs)

## Change log
- _pending Phase 1_
