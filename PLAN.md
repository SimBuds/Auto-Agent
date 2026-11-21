# PLAN.md: Hermes, a research assistant in Telegram

**Status: finished (2026-11-21).** This was a test of Hermes Agent, kept as
a record. See [How it ended](#how-it-ended).

[Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous Research)
ran in a QEMU VM on this workstation, on the Local-LLM router's models, and
Casey talked to it in a private Telegram chat. This file holds the purpose,
the principles, what the work taught, and how it ended. The setup steps
are in [`README.md`](README.md). The sections below are written in the
present tense, as they stood while the test ran.

---

## Purpose

A specialized search assistant that organizes what it finds:

- **Search:** tech and AI news, products and prices, and deep research on
  any question, always with links to its sources.
- **Organize:** results come back as Telegram summaries in a fixed shape
  (a short answer, then grouped findings, then sources).
- **Schedule:** Casey asks in chat for a recurring task ("every weekday at
  8am, ...") and its results post back in the same chat.

What it never does: publish, submit, post or push anywhere, touch Jobhunt or
SEO-LLM data, or send anything outside Casey's private chat.

## Principles

- **Hermes's own features first.** Chat, web tools, memory, skills and cron
  already cover search, organizing and scheduling. Custom code is written
  only for a gap seen in real use, and kept as small as the gap.
- **Try it by hand before scheduling it.** A prompt runs once in chat and
  gives a good answer before it becomes a job.
- **The toolset list is the security surface.** Telegram and cron get tools
  that read the web and keep notes. Nothing that runs commands or writes
  files is reachable from chat.

## Shape

```text
Host (this machine)                      QEMU VM (Debian, quickemu)              Phone
  llama-server router 127.0.0.1:8080 <--  Hermes Agent                       -->  Telegram, one private chat
    freedom pinned, one at a time          base_url http://10.0.2.2:8080/v1       one plain chat, no topics
    GPU: RTX 3080 10 GB                    gateway service, cron scheduler
                                           terminal backend local (the VM is the sandbox)
```

QEMU's user-mode networking gives the guest `10.0.2.2` for the host's
`127.0.0.1`, so the router needs no change and stays off the network. The VM
has no access to the host's files or repos.

## How Casey uses it

- **Ask in the chat.** `/new` starts a fresh session. Memory and skills are
  shared. Send `/new` when a chat starts repeating itself.
- **Schedule by asking.** A job's results post back in the chat.
- **Write prompts the way Hermes's docs advise** for scheduled work: fully
  self-contained (a job starts fresh and does not see the chat), who the
  reader is and what to skip, a time window ("past 24 hours"), the output
  shape, and `continuity` on recurring jobs so each run sees its last output
  and skips repeats.

---

## What we learned

**Model and router**
- Use `freedom` (an uncensored Qwen 3.6 35B A3B, Casey's choice
  2026-11-17). Its tool calling is not measured here yet. `qwen`, the same
  base model, made 39 of 39 tool calls in Local-LLM's
  tool test, `lite` 36, `gemma` 27. Pin one model so Hermes never makes the
  router swap.
- llama.cpp builds from 2026-11-16 on (commit `a1a68eb79`) reject any
  request whose `Host` header is not loopback when `--cors-origins` is
  `localhost`, with "Cross-origin request not allowed". The VM reaches the
  router as `10.0.2.2`, so every call failed with HTTP 403, which Hermes
  reports as a rejected API key. Hermes sends `Host: localhost:8080`
  through `model.default_headers` instead. The check guards against
  browsers, and the VM was already allowed in, so nothing new is opened.
- `aa_guard` can answer for a router that is not there (2026-11-19, built
  for a move to an always-on mini PC, the ZBOX, where the router would be
  gone whenever the PC was off. The move was dropped, so this is unit
  tested only). With
  `AA_ROUTER_URL` set in `~/.hermes/.env`, a `pre_llm_call` hook asks the
  router's `/health` with a 2 second limit before every model call. If the
  connection fails, the turn ends with "Not online right now. The PC is
  off. Try again later." and no model call. Any HTTP answer counts as up,
  including a 503 during a model swap. Unset, there is no check. The value
  needs its `http://`: urllib treats `127.0.0.1:8080` as a failed
  connection, which would read as offline for good, so the hook checks the
  scheme first and skips the check with a warning. If the hook itself
  raises, Hermes logs it and the turn goes ahead (v0.23.2
  `agent/turn_context.py`).
- The router has one slot. Sub-agents and parallel tool calls wait their
  turn, and so do Jobhunt and SEO-LLM while Hermes works.
- An idle model sleeps after 10 minutes and frees its VRAM. Hermes makes no
  model calls while idle. A cold `qwen` load takes about 12 seconds.
- Every session starts by reading about 15.6K tokens of system prompt and
  tool definitions (about 14.5 seconds). Later turns reuse the cache.
  Generation runs at about 64 tokens per second.
- Thinking is on by default (`agent.reasoning_effort` medium).

**Host budget**
- Give the VM 6 GB of RAM and 4 cores. With `qwen` loaded, the host has
  about 3 GB free, and `qwen`'s MoE layers run on the host CPU. Nothing
  heavy runs alongside a long Hermes task.
- The context is 131,072 tokens, set by the router. Hermes compacts at 75%
  of it. Fewer toolsets leave more room. An oversized request gets HTTP 400
  from the router rather than being truncated.
- `llama-server` has crashed on NVIDIA Xid 31 faults. A crash kills the
  request in flight, and the router reloads on the next one.

**Safety**
- Hermes's command scanner (Tirith) neither reliably allows nor reliably
  stops a command: it ran flagged commands "auto-approved" and refused
  harmless ones. The VM and its snapshots are the only real boundary.
- Skills Hermes writes wait for approval (`skills.write_approval true`),
  because one was written unasked and truncated. The post-run background
  review is off, because it drafted near-duplicate skills run after run.
- The VM can reach every service on the host's loopback, not only the
  router. The README's router-only network variant closes that, at the cost
  of internet access.
- quickemu forwards SSH on all host interfaces, so SSH is key-only in the VM.

**Telegram**
- An empty toolset list leaves qwen printing tool calls as JSON text. A
  session holding those replies made it repeat one search until Hermes's
  loop guard stopped it. `/new` cleared it.
- Only the allowlisted user ID gets answers, and the bot cannot join
  groups. Messages sent while the gateway is down are dropped, not queued.
- The gateway unit restarts itself after a crash (`Restart=always`), and a
  manual `systemctl --user stop` stays stopped. Starting at boot with no
  login needs `sudo loginctl enable-linger hermes`.
- Topics (`platforms.telegram.extra.dm_topics` with BotFather's Threaded
  Mode) were tried and dropped for one plain chat (2026-11-17). With
  Threaded Mode on there is no plain chat, and deleted topics leave Hermes
  holding dead thread IDs (`dm_topics`, `TELEGRAM_CRON_THREAD_ID`).

**Cron**
- Hermes's own scheduler runs inside the gateway, so jobs only fire while
  the VM is up. A job missed while it was off runs once on return if the
  job has `catch_up` on. `grace_minutes` cannot be cleared once set. Avoid
  02:00, which does not exist on the March daylight-saving night.
- A job's own `enabled_toolsets` beats `platform_toolsets.cron` (set to
  `[web]`), and Hermes has no setting that caps what a job created from
  chat may ask for. The model could schedule a job with `terminal`, read
  `~/.hermes/.env`, and leak the bot token through a fetched URL. The
  `aa_guard` plugin (`hermes-plugin/aa_guard/`) closes that: it refuses any
  job asking for more than web tools and the chat it came from, or setting
  an argument not on its reviewed list.
- Tested in Telegram on v0.23.2 (2026-11-17): a job asked with
  `enabled_toolsets ["terminal"]` was refused (`agent.log`: "Scheduling
  blocked by aa_guard"), and the model then retried without toolsets, so
  the job fell back to cron's `[web]`. The model told Casey the job had
  "full tool access", which was wrong: do not trust its own account of
  its tools. Without the cron toolset in Telegram at all, `freedom` loops
  on `clarify` questions instead of saying it cannot schedule.
- A scheduled job that fires while the router is unreachable posts
  "Not online. The PC was off, so this run was skipped." and waits for its
  next scheduled time (Casey, 2026-11-19). The `aa_guard` offline hook
  does this: Hermes runs a job with `platform` set to `cron`, the hook
  blocks the turn, and Hermes delivers the block message as the job's
  result under its own "Cronjob Response" header, which names the job.
  Read in the v0.23.2 source (`cron/scheduler.py`,
  `agent/conversation_loop.py`), never run in a live Hermes. Three things
  follow.
  Hermes records the run as a success, so a job with `continuity` sees
  that line as its last output. A job created with `wrap_response` false
  gets the line with no job name. And the block pre-empts Hermes's own
  handling (`cron/unreachable_retry.py`): without it, a recurring job that
  cannot reach the model is re-run silently after 5, 15 and 30 minutes,
  and only then posts a failure notice. Set `AA_ROUTER_URL` aside and
  that behaviour returns.
- `aa_guard` matches both tool names. A plugin `pre_tool_call` hook blocks by returning `{"action": "block",
  "message": ...}`. A block with no message is ignored and the tool runs.
- `/cron` is CLI-only. Cron runs load `MEMORY.md`. A job's `script` runs
  only from `~/.hermes/scripts/`, and a script that fails still runs the
  model unless the prompt says to stop.

**Getting good results from the model**
- Where exactness matters (links, numbers), a script fetches and records,
  and the model only judges a bounded list. Every link then comes from a
  source.
- The lever on the model's judgement is the wording it can quote, not
  stricter checks.
- A check the model cannot argue with (a field or URL check in code) held
  where prompt rules did not.

**Sources**
- Reddit's `robots.txt` disallows its anonymous feeds, so Reddit needs a
  registered OAuth app before any scheduled use. Amazon's terms forbid
  scraping product pages.

**VM sessions**
- A VM started with `--status-quo` runs qemu with `-snapshot`, and every
  change in that session is silently discarded at shutdown. A cron job
  removed in such a session came back after the next boot (2026-11-17).
  Check for `-snapshot` in the qemu command line before any change meant
  to last.
- A recurring job with `catch_up` on runs once at every boot after a
  missed fire, however late.

**Updates**
- `hermes update` follows its channel and has kept every config key set
  here so far. It also tries to install the computer-use driver, which
  fails in a VM with no desktop and can be ignored. Snapshot first.
- v0.23.2 (2026-11-17) renamed the cron tool from `cronjob` to
  `cronjob_manage` (toolset still `cronjob`) and added `wrap_response`.
  A guard keyed on the old name would have let every job through, so
  after each update, re-read the cron tool's name and arguments
  (`tools/cronjob_tools.py`) against `aa_guard` before relying on it.

---

## Persistence split

The VM is disposable, so anything made by hand inside it needs a durable home.
This repo is that home.

| Location | Survives | Lost when |
|---|---|---|
| This repo (tracked in git) | Everything below, and the VM's removal | Never by a VM action |
| VM disk (`~/VMs`, Hermes's config, memory and skills) | Shutdown and reboot | `--snapshot apply` rolls it back, a `--status-quo` session discards changes, removing the VM deletes it |
| VM snapshots | Normal sessions and `--snapshot apply` | Deleted by name, or with the disk image. Not in git |

| Path in the VM | Holds | `--snapshot apply` | Rebuild |
|---|---|---|---|
| `~/.hermes/.env` | Bot token, allowed user ID | Rolled back | Lost. Casey runs `hermes gateway setup` again |
| `~/.hermes/config.yaml` | Model, toolsets, headers | Rolled back | Lost. The README blocks re-apply them |
| `~/.config/systemd/user/`, `/var/lib/systemd/linger/hermes` | The gateway service and start at boot | Rolled back | Lost. README Telegram step 4 |
| `~/.hermes/plugins/aa_guard/` | The cron guard | Rolled back, and so is `cronjob` in Telegram's toolsets | Lost. README *Scheduling from Telegram*, guard before tool |
| `~/.hermes/cron/jobs.json` | Scheduled jobs | Rolled back | Lost. Recreate by asking in chat |
| `~/.hermes/memories/MEMORY.md` | Hermes's memory | Rolled back | Lost, by design |

The token and the user ID never go in this repo. A change made by hand inside
the VM (config, a reviewed skill, a job worth keeping) is copied into this
repo in the same phase that makes it.

---

## How it ended

The test ran from 2026-09-25 to 2026-11-21.

**Done**
1. Hermes was updated to v0.23.2 and its cron tool re-read against
   `aa_guard` (2026-11-17).
2. One prompt pattern per specialty was tried by hand in Telegram and
   written into the README (2026-11-17).
3. Scheduling from chat worked behind `aa_guard`: a test job delivered its
   result, and a job asking for `terminal` was refused (2026-11-17).
4. `aa_guard` gained the offline reply for chat and for scheduled jobs
   (2026-11-19). It passes its unit tests and was never run in a live
   Hermes.

**Dropped**
- The review after two weeks of real use (2026-11-19).
- The move onto the ZBOX, a fanless mini PC with a 2-core Celeron and 2 GB
  of RAM (2026-11-21). It has no GPU, so every model call would still have
  gone to the PC through an SSH forward that the PC opens. Friends-Hermes
  ran that way from 2026-11-15 to 2026-11-19 and then went back to its VM.

**Where it led.** [Friends-Hermes](https://github.com/SimBuds/Friends-Hermes)
started on 2026-11-07 from this repo's setup guide, persistence split and
memory budget. It is the same pattern (Hermes in a VM on the Local-LLM
router, a plugin that holds the model to what was reviewed) for a Discord
bot that answers a few friends.

**Left running outside this repo.** The VM, its snapshots and the Telegram
bot are not part of the repo. Removing them is in the README, *Removing
it*, and the bot's token is revoked in BotFather.

## Open questions

These were never answered.

- How much does thinking cost on a long research run, against thinking off?
- How does Hermes's compaction behave against the router's HTTP 400 on an
  oversized request?
- Does sleeping free `qwen`'s host RAM as well as its VRAM? Very likely
  (1.65 GiB resident asleep against 19.1 GiB loaded, measured on different
  days).

## Sources

- [hermes-agent repository](https://github.com/NousResearch/hermes-agent)
- [Hermes docs: Scheduled tasks (cron)](https://hermes-agent.nousresearch.com/docs/user-guide/features/cron)
- [Hermes docs: Build a daily briefing bot](https://hermes-agent.nousresearch.com/docs/guides/daily-briefing-bot)
- [Hermes docs: Automation templates](https://hermes-agent.nousresearch.com/docs/guides/automation-templates)
- [Hermes docs: Local models](https://hermes-agent.nousresearch.com/docs/user-guide/local-models)
- [Fast.io: Hermes scheduled automations](https://fast.io/resources/hermes-agent-scheduled-automations-cron/)
- [Local AI automation with Hermes](https://njannasch-dev-astro.pages.dev/blog/hermes-agent-local-ai-automation/)
