# PLAN.md: Hermes Agent in a VM

A plan for running [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(Nous Research) on this workstation, against the Local-LLM router, inside a
QEMU virtual machine. Written 2026-09-25. **Status: installed and verified
2026-09-25, updated and re-verified 2026-10-09 to 2026-10-20** (Hermes Agent
`v0.21.6+337.g26610b0`, on `qwen`, v0.22.7 since 2026-11-04). Since 2026-11-04 Casey talks to Hermes
through Telegram (chosen over Discord the same day, as the simpler setup
with the same privacy), as a research and data-organizing assistant. The host
job runners and the planned hub were removed 2026-11-17 (see *Scheduling*).

Hermes is an agent that runs on a schedule or on demand, keeps memory between
sessions, writes reusable "skills" from work that succeeded, and can report
through messaging apps. Here it would be one more client of the router, like
Jobhunt and SEO-LLM, and it would get the models the router already serves.

---

## The shape of it

```text
Host (this machine)                              QEMU VM (Debian, quickemu)
  llama-server router 127.0.0.1:8080  <------     Hermes Agent
    gemma / qwen / lite, one loaded at a time     base_url http://10.0.2.2:8080/v1
    GPU: RTX 3080 10 GB                           terminal backend: local (the VM is the sandbox)
                                                  no access to the host's files or repos
```

The VM is the sandbox. Anything Hermes runs happens inside it, and a snapshot
undoes it. QEMU's user-mode networking gives the guest the address `10.0.2.2`
for the host's own `127.0.0.1`, so the router needs no change and stays off the
network.

---

## Good fits

The useful jobs need only two things the VM can reach: the router and the
public web. Each one ends in a file Casey reviews, not an action Hermes takes.
That matches the rules the other projects already keep: Jobhunt never submits
an application, no agent touches the everything4cats server, and SEO-LLM
approves every stage by hand.

1. **Weekly topic scout for everything4cats, feeding SEO-LLM.** Built and
   accepted 2026-09-26 after 18 hand runs, and removed 2026-11-17 (Casey)
   with the other host runners. The runner, prompts, idea scripts and
   their findings are in git history before that date. What carried
   over: a script, not the model, should be the only way a result is
   recorded, and a check the model cannot argue with (the field and URL
   checks) held where prompt rules did not.
2. **Public health report for everything4cats.ca.** A daily HTTP check from the
   VM: key pages up, broken internal links, the affiliate disclosure present,
   the Article schema intact. It never goes near the Lightsail server or the
   AWS account, which stay Casey's alone.
3. **llama.cpp changelog digest for Local-LLM.** Weekly, Hermes reads the new
   llama.cpp commits on GitHub and flags CUDA, router, memory, and model changes
   (the week of 2026-09-25 had an argsort corruption fix and a router eviction
   race fix). This is the reading step of the update flow.
   Local-LLM's `scripts/llama-update build` and `swap` stay Casey's, and its
   `scripts/verify-build` runs on the host.
4. **Router uptime watch.** Dropped 2026-11-02. The number stays so references to #5 to #7 hold.
5. **Company research for Jobhunt.** Given a company name from `jobhunt list`,
   a one-page brief from public sources: what they do, recent news, stack, red
   flags. Casey passes the names by hand, because the VM cannot see Jobhunt's
   database. That is deliberate, and it stays hand-fed.
6. **Daily news digest from public APIs.** Built 2026-09-27 to 2026-10-20
   and removed 2026-11-17 (Casey), when Hermes became a Telegram search
   assistant. The runner, collector, rating script and their findings are
   in git history before that date. Two lessons carry over. A script, not
   the model, should fetch and render, so every link comes from a source.
   And the lever on the model's judgement was the wording it could quote,
   not stricter checks. Reddit, rechecked 2026-11-05: its `robots.txt` is
   `User-agent: *` `Disallow: /`, so its anonymous feeds suit only a single
   fetch Casey asks for. Hermes's reviewed `reddit-reading` skill runs
   through `terminal`, so it works from the CLI in the VM, not from
   Telegram or a cron job, until Casey registers an OAuth app.
7. **Weekly routine that ends in a review queue.** Dropped 2026-11-17 with
   the hub that was to run it. Submitting an application, approving
   SEO-LLM stages, and anything needing Casey's logins stay never
   automated, by rule.

---

## Scheduling

A hub service (an API, Postgres and n8n) was decided 2026-11-02, put on
hold 2026-11-04, and dropped 2026-11-17 (Casey) with the host job runners
it was to schedule. Scheduling now lives in Hermes's own cron, in the VM.

- **A Telegram gateway and Hermes's own scheduler run in the VM** (reversed
  2026-11-04, was "No Hermes gateway and no cron in the VM. The caller lives
  on the host."). Reason: Casey queues research from Telegram, mostly
  overnight, and the result posts back there, which needs both inside the
  VM.
- **Night tasks were removed on 2026-11-17 (Casey).** They queued
  `NIGHT:` memory entries for one fixed 03:00 job (Phases 34 to 39). Casey
  now wants to schedule tasks from Telegram directly (Phases 45 and 46).
- **Telegram does not have the `cronjob` tool yet.** A job's own
  `enabled_toolsets` beats `platform_toolsets.cron`, and the model-facing
  tool forwards it, so qwen (or a web page it read) could create a job
  with `terminal`, read `~/.hermes/.env`, and leak the bot token through a
  fetched URL. Telegram gets the tool only behind a plugin guard that
  rejects anything beyond web (Phase 45). `/cron` is CLI-only.
- **Hermes never sees Jobhunt or SEO-LLM data.**
- **Casey's SSH key for `hermes@localhost`** (README, *Connecting guide*,
  installed 2026-11-03) is how files are copied into the VM.

---

## Where to hold back

- **Jobhunt data and the messaging gateway do not mix.** Jobhunt's rule is that
  no resume or job data leaves this hardware. A Telegram, Discord, or Slack
  gateway sends Hermes's output through that platform's servers. Keep anything
  Jobhunt-related as local files, or limit the gateway to the public-data jobs
  (1 to 3). Setting up a gateway (bot tokens, accounts) is Casey's to do.
  Restated 2026-11-04 with the Telegram gateway: no Jobhunt data goes through
  Telegram, and Hermes never touches Jobhunt or SEO-LLM.
- **No publishing, submitting, or pushing.** Hermes does not post to WordPress,
  submit applications, or push to git. Every project reserves outward-facing
  actions for Casey, and an agent with self-written skills is not the exception.
- **Read the skills it writes.** A skill is a set of instructions it will reuse
  without asking. Review a new one as you would code before trusting it.
- **No scraping of sites that forbid it.** Amazon's terms prohibit scraping
  product pages, so the everything4cats health report does not check affiliate
  links by fetching Amazon. The AGENTS.md rules on fetching apply to what
  Hermes is set up to do.
- **Sharing repo folders into the VM** would allow more (running `jobhunt list`
  itself, say) and weakens the isolation that is the point of the VM. If it is
  ever done, share one folder, read-only.
- **The VM can reach every service on the host's loopback,** not only the
  router. On 2026-09-25 that was the router (8080), CUPS (631), and several
  ports held by VS Code. The router-only network variant at the end of the setup
  guide closes that, at the cost of internet access.
- **Hermes runs commands without asking.** With the terminal backend on
  `local`, a terminal tool call runs in the VM with no approval prompt
  (observed 2026-09-25 on `uname -r`). Hermes does scan commands (its
  scanner is called Tirith), but on 2026-09-26 it flagged two harmless
  commands as HIGH risk and they ran anyway, "auto-approved by smart
  approval", in a run nobody was watching. Other flagged commands are
  refused in a one-shot run: a heredoc piped into `bash` was "BLOCKED ...
  single-query mode (-q) runs without a user present to approve it" in every
  topic scout run from 16 to 19 (the switch is
  `approvals.single_query_mode`, left unset), and a brace group or `if`
  that appends to a file was refused as "Nested executable body could not be
  resolved" in every sweep since the summary step took that shape. So the scanner neither reliably
  allows nor reliably stops a command, and the VM and its snapshots are the
  only boundary. Before any scheduled job is set up, decide what that job may run
  unattended, and keep a fresh snapshot to roll back to.

---

## Load on the models and the GPU

### Which model

| Model | Tool calling here (Local-LLM `run-tools.py`, 13 tasks x 3, 2026-09-17) | Use it for |
|---|---|---|
| `qwen` (Qwen 3.6 35B A3B, 35 MoE layers on CPU) | 39/39 | The default. The same model is the most common local choice for Hermes elsewhere. |
| `lite` (Qwen 3.5 9B, all on GPU) | 36/39 | Quick, simple jobs. About 2x `qwen`'s generation speed. |
| `gemma` (Gemma 4 26B A4B) | 27/39 | Avoid for Hermes. It skipped the offered tool on 9 of 39 attempts. |

An independent comparison of seven local models on 84 agent scenarios ranked
Qwen 3.6 35B A3B first (91.0) and Gemma 4 26B mid-tier (81.4), on 96 to 128 GB
machines at higher-precision quantizations than this box runs. Same ranking,
lower absolute scores expected here.

### How the router serves Hermes

- **One slot, one model.** The router runs `parallel = 1` and
  `--models-max 1`. Hermes's parallel tool calls or sub-agents wait their turn,
  and so do Jobhunt and SEO-LLM while a Hermes job runs. A request for a
  different model unloads the current one, so pin Hermes to one model (`qwen`,
  which the other apps also use) and schedule its jobs for quiet hours.
- **The model is only in VRAM while it works, plus 10 minutes.**
  `sleep-idle-seconds = 600` puts an idle model to sleep and frees its VRAM
  (measured 6,226 to 242 MiB). The Hermes program can run all day in the VM
  without holding the GPU. A daily job holds `qwen` for the job's length plus
  10 minutes.
- **What would keep a model loaded all day:** any job that calls the model more
  often than every 10 minutes, or background work Hermes does on its own
  (memory upkeep, summaries, skill-writing). Measured 2026-09-25: with Hermes
  open and idle, the router log held no requests and `qwen` slept exactly 10
  minutes after the last one (VRAM 6,240 to 264 MiB). Hermes's auxiliary calls
  (such as the session title) fire right after a turn, not while idle. A
  scheduled job or gateway may behave differently, so re-check when one is
  added.
- **Wake-up cost:** `lite` answers in about 1 to 2 seconds after sleeping
  (measured). A cold `qwen` load took 12 seconds on 2026-09-25 (measured).
  `gemma` took about 7 seconds cold on build 11022.
- **Session start cost:** the first request of every Hermes session carries
  its whole system prompt and tool definitions, about 15.6K tokens, which
  `qwen` reads in about 14.5 seconds (1,075 tokens per second, measured twice).
  Later turns reuse the router's cached prefix: the tool-result turn sent 82
  new tokens and took 0.47 seconds. Generation ran at 64 to 66 tokens per
  second.
- **Thinking is on.** Hermes's `agent.reasoning_effort` defaults to `medium`,
  and `qwen` showed a Reasoning block before every answer on 2026-09-25. That
  makes replies slower than Local-LLM's thinking-off leaderboard numbers. On
  one-line answers it cost only a few dozen tokens. Its cost on long jobs is not
  measured yet.

### Memory and CPU budget (31 GiB RAM, 24 threads)

- `qwen` runs its expert layers on the CPU with `load-mode = none`, so most of
  its 20.2 GiB GGUF sits in host RAM while it is loaded. While sleeping, its
  process held 1.65 GiB RSS (2026-09-25), so sleep very likely frees most of
  that RAM too. The loaded RSS was not measured in the same session, so this is
  not yet a before-and-after figure.
- **Loaded, during a job** (topic scout run 14, 2026-09-26): `llama-server`
  held 19.1 GiB RSS, the host had 2.9 GiB available and 8 GB of swap in use.
  That is pressure, not thrashing: generation held 47 to 66 tokens per
  second. Nothing else heavy should run on the host during a Hermes job.
- Give the VM **6 GB of RAM and 4 cores**. More RAM pushes the host into swap
  while `qwen` is loaded. The MoE layers use the host's CPU, so every busy VM
  core slows generation.
- **Context is fixed at 131,072 tokens** (65,536 until Local-LLM raised it on
  2026-10-30, and Hermes's `model.context_length` followed on 2026-11-04).
  Hermes's own system prompt and its 34 tool definitions take 15.6K of it
  (12%, measured 2026-09-25 as 24% of 65,536). Hermes compacts at 75% of the
  context for models under 512K (its `compression.threshold` 0.50 is
  floored there), so at about 98K tokens, against about 49K before. At
  65,536 every full scout research session compacted 2 or 3 times
  (2026-11-03). Trimming unused toolsets is the way to get more room
  without touching the router, and `--toolsets` does it per job: the topic
  scout's two sessions start at 6.9K and 6.0K tokens. An oversized request gets HTTP 400 from
  the router rather than being truncated, and Hermes's docs say it compacts the
  conversation and retries when a request is rejected as too large. Untested
  here.
- **No Local-LLM prompt stack.** Hermes sends its own system prompt, as Cline
  does, so the rules in Local-LLM's `prompts/` and `memory/` do not apply to it.
- **GPU faults.** `llama-server` has hit NVIDIA Xid 31 crashes 18 times since
  2026-07-28 (see Local-LLM TESTING, *GPU faults*). A crash kills whatever request was in
  flight, Hermes's included. The router loads the model again on the next
  request.

---

## Persistence split

The VM is disposable by design, so anything made by hand inside it needs a
durable home before it can be trusted to last. This repo is that home.

| Location | Survives | Lost when |
|---|---|---|
| This repo (tracked in git) | Everything below, and the VM's removal | Never by a VM action. It is the source for config copied into the VM. |
| VM disk (`~/VMs`, including Hermes's own config, memory, and skills in the guest) | A normal shutdown and reboot | `--snapshot apply` rolls it back, a `--status-quo` session discards its changes at shutdown, and removing the VM deletes it |
| VM snapshots (`clean`, `pre-update-2026-10-09`, `hermes-configured`, the last retaken on v0.22.7 on 2026-11-04 after a passing scout run) | Normal sessions and `--snapshot apply` | Deleted by name, or with the disk image when the VM is removed. Not tracked in git. |

**The Telegram gateway's paths in the VM** (recorded 2026-11-04, before the
first change, Phase 33):

| Path in the VM | Holds | VM reboot | `--snapshot apply` | Rebuild |
|---|---|---|---|---|
| `~/.hermes/.env` | The bot token and the allowed user ID | Kept | Rolled back to the snapshot | Lost. Casey runs `hermes gateway setup` again |
| `~/.hermes/config.yaml` | The Telegram toolsets and `telegram:` keys | Kept | Rolled back | Lost. The README's Telegram block re-applies them |
| `~/.hermes/config.yaml` `platforms.telegram.extra.dm_topics`, and `TELEGRAM_CRON_THREAD_ID` in `~/.hermes/.env` | The three topics with their thread IDs, and the topic cron results post to (Phase 38) | Kept | Rolled back | Lost. The README's *Topics* block re-adds them, and Telegram makes new topics |
| `~/.config/systemd/user/` | The gateway's service unit | Kept | Rolled back | Lost. `hermes gateway install` again |
| `/var/lib/systemd/linger/hermes` | Starting the user service at boot with no login | Kept | Rolled back | Lost. `sudo loginctl enable-linger hermes` again |
| `~/.hermes/cron/jobs.json` | Cron jobs | Kept | Rolled back | Lost. Jobs are recreated by hand |
| `~/.hermes/memories/MEMORY.md` | Hermes's memory | Kept | Rolled back | Lost, by design: no copy in the repo |

The token and the user ID have no copy in this repo by design (a secret,
and an account identifier). Everything else has its durable copy in the
README.

**Rule:** a change made by hand inside the VM (Hermes `config.yaml`, a job or
schedule definition, a reviewed skill) is copied into this repo in the same
phase that makes it. Anything still only in the VM when a snapshot is applied
is presumed lost. The folders for these files are created by the first phase
that codifies one.

---

## Setup

The step-by-step setup (check the host, build the VM, install Hermes, point it
at the router, snapshots, removal) is in
[`README.md`](README.md#setup-guide). The
findings behind its settings are here, so the README can stay short. The job
findings are under Good fits #1, and the router's under *How the
router serves Hermes*.

**The VM and the install**
- The Debian install leaves the root password blank, so Debian installs
  `sudo` and grants it to the first user, which the router check relies on.
  quickemu forwarded SSH to host port 22220 on 2026-09-25, recorded in the
  VM's `.ports` file.
- `install.sh --non-interactive` skips `hermes setup` (API keys) and
  `hermes gateway install` (the messaging gateway service). The endpoint is
  set by `hermes config set` instead, and the gateway stays off.
- Versions: v0.21.5 (`v0.21.5+2367.g5dcfd72`, Python 3.14.7) on 2026-09-25.
  `hermes update`, which follows `main`, moved it to `v0.21.6+337.g26610b0`
  on 2026-10-09. The config migration from schema 46 to 50 asked nothing
  and kept every key set here, and the first check and a news digest run
  passed on it (2026-10-20). The update also tries to install cua-driver,
  the computer-use tool, which fails on a missing `libXi.so.6` and cannot
  run in a VM with no desktop anyway.
- 2026-11-04: `hermes update` moved it to `v0.22.7+144.gcad0aaa` (stable
  channel), with an `apt-get upgrade` of 22 guest packages (no new
  kernel). Every key set here survived, and `--oneshot`, `--toolsets` and
  `--query-file` are still in `hermes chat --help`. A scout run on it
  passed every check (10 ideas, 0 DEAD, 1 compaction). Its output format
  changed: tool calls print as `💻 $ cmd` (no `┊` prefix), reasoning as
  `∴ Thought for Ns`, and the reply without a box. The runner's scans
  match text anywhere in a line, so they are unaffected.

**Hermes config keys**
- `auxiliary.background_review.enabled false`: on 2026-09-26 the post-run
  review drafted a new `topic-scout` skill after four runs in a row, each a
  partial copy of `jobs/topic-scout.md`. `/refine` still runs a review by
  hand. Hermes's example config names `skills.creation_nudge_interval` for
  this, but v0.21.5 did not recognize that key. v0.22.7 does, and its
  config has it at 0 (disabled, 2026-11-04).
- `skills.write_approval true`: on 2026-09-25 Hermes wrote a skill unasked,
  and it was truncated mid-command. Skills now wait in
  `~/.hermes/pending/skills/` until approved.

**The Telegram gateway** (Phase 33, 2026-11-04)
- Chosen over Discord: the same privacy (neither encrypts bot chats end to
  end), a simpler setup. Signal was the private option, at the cost of a
  phone number for the bot.
- `platform_toolsets.telegram: []` gave no tools (`tool_turns=0`), and qwen
  then printed the tool call it wanted as JSON text. Casey chose `[web]`:
  real searches, and still no terminal or file. `hermes config set` writes
  it as a block list (`- web`). Later the same day Casey added `todo`,
  `clarify`, `session_search` and `memory`, none of which runs a command.
  The model's text-only input rules out `vision` and `stt`.
- In a session whose history held those JSON replies, qwen repeated one
  search until Hermes's guardrail stopped it (`identical_call_streak_halt`).
  `/new` cleared it.
- A sender not on the allowlist gets no reply and no log line at INFO.
  `/setjoingroups` Disable leaves the bot out of any group it is added to.
  `/skills pending` works in Telegram.
- v0.22.7 runs `hermes chat --oneshot` inside a gateway (`platform=local`),
  the running service when there is one. A runner's SIGTERM still stops
  it: the gateway ended the turn one second later
  (`reason=interrupted_by_user`).
- The service starts at boot with no login (3 seconds after boot, with
  linger). Hermes's own linger step fails without polkit, so `sudo
  loginctl enable-linger hermes` does it. Telegram messages sent while the
  gateway is down are dropped on its cold boot
  (`drop_pending_on_cold_boot`), not queued.
- The service restarts itself after a crash (Phase 37, 2026-11-06). The
  unit `hermes gateway install` writes has `Restart=always`,
  `RestartSec=5` and `StartLimitIntervalSec=0`, so systemd retries without
  limit. Exit 78 (a config error) is not retried, and a
  `systemctl --user stop` stays stopped. A `kill -9` of the main PID was
  replaced by a new one within 15 seconds (`NRestarts=1`, `active`). So no
  watchdog and no drop-in are needed.
- Topics (Phase 38, 2026-11-06, v0.22.7). Declared topics in
  `platforms.telegram.extra.dm_topics` are created at gateway start (BotFather
  Threaded Mode on), and their thread IDs are written back to `config.yaml`
  (`Persisted thread_id=N`). A top-level `platforms.telegram` block is merged
  with the `.env` setup, its `extra` deep-merged (`gateway/config_loader.py`),
  so it adds to that setup and replaces nothing. `TELEGRAM_CRON_THREAD_ID`
  sends cron deliveries to one topic (`cron/scheduler_delivery.py`): a test
  run with a task queued from Research posted in Night (`thread=263` in
  `agent.log`). With Threaded Mode on, a message in Telegram's All Messages
  view opens a new topic, and so a new Hermes session (Casey, 2026-11-06),
  so there is no plain chat left. The `/topic` command would also make the
  main chat a commands-only lobby, so it is left off.
- Hermes's security audit found SSH password login on, and quickemu
  forwards 22220 on all host interfaces (`0.0.0.0`). Password login is off
  since 2026-11-04 (`/etc/ssh/sshd_config.d/10-no-password.conf`).

**Cron** (read from v0.22.7's source and help, Phases 34 and 35. The
night-task job these were found on was removed 2026-11-17.)
- A cron `--script` runs only from `~/.hermes/scripts/`. Its stdout goes
  into the prompt, and an empty stdout skips the model call
  (`cron/scheduler.py`). A script that exits non-zero does not stop the
  run: Hermes injects a `## Script Error` section and runs the model
  anyway, so a prompt must turn that into `[CRON_FAILURE]` to fail loudly.
- `hermes cron create` and `edit` have no toolset flag. Unset,
  `platform_toolsets.cron` gives cron jobs Hermes's default tools,
  terminal included. It is `[web]`.
- Cron runs always load `MEMORY.md` (`skip_memory=False`).
- The VM is `America/New_York`, like the host. A missed run follows, in
  order: the job's own `catch_up`, then skip past an explicit
  `grace_minutes`, then `cron.catch_up_missed` (`cron/missed_runs.py`).
  `cron edit` cannot clear `grace_minutes`. Avoid 02:00 schedules, which
  do not exist on the March daylight-saving night.
- `HERMES_CRON_TIMEOUT` is unset: 600 s of inactivity, not total time.

---

## Open questions

- Does sleeping free `qwen`'s host RAM as well as its VRAM? Very likely:
  1.65 GiB RSS while sleeping (2026-09-25) against 19.1 GiB loaded
  (2026-09-26). The two were measured on different days, so a same-session
  pair would close it.
- How does Hermes's context compaction behave against the router's HTTP 400 on
  an oversized request?
- How much does thinking cost on a long job, compared with thinking off?
- Answered 2026-09-25: Hermes makes no model calls while idle (see *How the
  router serves Hermes*), and Hermes sends thinking on by default.

## Sources

- [hermes-agent repository](https://github.com/NousResearch/hermes-agent) and its
  [CONTRIBUTING.md](https://raw.githubusercontent.com/NousResearch/hermes-agent/main/CONTRIBUTING.md)
- [Hermes Agent: Local Models](https://hermes-agent.nousresearch.com/docs/user-guide/local-models)
  and [Providers](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/integrations/providers.md)
- [Hermes Agent: User Stories](https://hermes-agent.nousresearch.com/docs/user-stories)
  and [Telegram](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram)
- [MiaAI-Lab: best local model for agentic workflows 2026](https://github.com/MiaAI-Lab/Best-Local-Model_Agentic-Workflows_2026)
- Local-LLM repo: README (*Serving other apps*, *Updating llama.cpp*), TESTING
  (*Tool calling*, *GPU faults*, *Build check and margin findings*), `server.ini`
