# PLAN.md: Hermes Agent in a VM

A plan for running [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(Nous Research) on this workstation, against the Local-LLM router, inside a
QEMU virtual machine. Written 2026-09-25. **Status: installed and verified
2026-09-25, updated and re-verified 2026-10-09 to 2026-10-20** (Hermes Agent
`v0.21.6+337.g26610b0`, on `qwen`, v0.22.7 since 2026-11-04). The jobs run
by hand through their host runners. Since 2026-11-04 Casey talks to Hermes
through Telegram (chosen over Discord the same day, as the simpler setup
with the same privacy), as a research and data-organizing assistant, mostly
overnight. The hub is on hold (see *Scheduling*).

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

1. **Weekly topic scout for everything4cats, feeding SEO-LLM. The first pilot.**
   Each week Hermes researches cat products, launches, and seasonal topics,
   ranks about ten ideas, and writes short briefs to a file. Casey picks the
   ones worth doing and they become SEO-LLM's inputs (the page slug and
   `competitors.txt`). SEO-LLM keeps its staged pipeline and its approvals.
   Decided 2026-09-25: the prompt lives in `jobs/topic-scout.md` and runs by
   hand first (README, *How to use*). Search uses Hermes's keyless
   default, which rotates across free vendor tiers, so no key is stored and
   only public cat-product queries leave the VM. Each idea carries SEO-LLM's
   own fields (slug, type, suggested keywords, competitor URLs) plus why now,
   a YMYL flag, and sources. It runs weekly as `jobs/run-topic-scout.sh`
   (see *Scheduling*).

   Accepted 2026-09-26 after 18 hand runs (Phase 4). What held, and why:
   - **Two sessions, chained with `--oneshot`.** A research session (`web`
     and `terminal` tools) appends ideas, then a sweep session (`terminal`
     only) checks and finishes the file. One session doing both skipped the
     sweep after long research. Limiting each session's tools with
     `--toolsets` cut its first prompt from 15,578 tokens to 6,913 and 5,993.
   - **The prompt is the user message** (`--query-file`). Hermes's
     compression drops tool results but restates the user message, so rules
     sent that way survive it, and rules Hermes read from a file did not.
   - **Search results fill the context, not page reads.** 13 to 17 searches
     returned 168,000 to 259,000 characters. So each idea is written to disk
     the moment it is researched. A run that wrote everything at the end
     cited 13 of 24 URLs that did not exist. Run 18 had no dead URL among 41.
   - **Keyless search returns no dates** (URL, title and description only),
     so "timely" means tied to a named event or season in the next 3 months,
     not a recent source.
   - **qwen bends every rule that only the prompt states.** It relabelled 8
     of 10 product comparisons as guides to dodge the roundup cap, resubmitted
     a taken topic under a new slug, and guessed a holiday's date. Checks
     after the run caught these, but only after the research time was spent.
     What held was `jobs/add-idea.sh`, the only way to add an idea, which
     refuses repeats, relabels and out-of-window timely claims at write time.
     For later jobs: a rule that matters goes in a script the model has to
     call.
   - **The seen list takes only reviewed runs.** Tuning runs made on one day
     for one window used up that window's topics (run 17 found 4 ideas in 40
     minutes).
   - **A run has 50 web searches, total.** Hermes blocks `web_search` after
     50 calls in one turn (`loop_web_search_cap`), and a `--oneshot` job is
     one turn. Run 19, under the same conditions as run 18's 10 ideas, spent
     its 50 re-running searches that compression had dropped (one query 6
     times) and stopped at 3. The prompt now budgets 4 searches per idea, one
     idea at a time. That rule is prompt-only, but it held: runs 20 and 21,
     back to back under run 18's conditions, each reached 10 ideas in 18 to
     20 minutes with no query repeated, no search cap and 0 dead URLs. Runs
     22 and 23 (2026-09-27, after the sweep's summary step was made plain and
     step 1 began printing Black Friday) did the same with no command blocked
     in any session: four passing runs in a row.
   - **Casey's review stays the last gate.** Run 18 passed every check (10
     ideas, 7 timely, 0 dead URLs, 17 minutes of research and 2 of sweep),
     yet no check can tell a real event link from a pretext, or a retailer
     listing from an article.
   - **Scheduled through the runner, accepted 2026-11-04** (Phase 22). Batch
     1 (2026-11-03, 6 runs 15 minutes apart) passed 2 of 6: research reused
     an earlier run's file the same day (fixed: the runner starts the file),
     and the URL check read three passing 500s as DEAD (fixed: 5xx is
     UNVERIFIED). Batch 2, after both fixes and with Hermes at 131,072
     context, exited 0 in 6 of 6: 10 ideas in five runs, 0 DEAD URLs, no
     refusal, no new skill, research 4 to 15 minutes, `qwen` asleep after.
     Compactions per research session fell from 2 or 3 to 0 or 1. Run 5
     stopped at 5 ideas: after 7 searches and no compaction, qwen took its
     prompt for a fresh system prompt, replied "I'm ready", and ended the
     session. The field check allows fewer than 10 (never pad), so the run
     passed. Over SSH without a terminal, `--oneshot` still logs reasoning,
     tool lines and replies, so refusals would show in `run.log`. A guest
     reboot mid-session hung a run until QEMU exited (fixed in Phase 25: an
     SSH keepalive, and a dropped session exits 13 `vm`).
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
4. **Router uptime watch.** Dropped 2026-11-02: the hub checks the router
   from the host. The number stays so references to #5 to #7 hold.
5. **Company research for Jobhunt.** Given a company name from `jobhunt list`,
   a one-page brief from public sources: what they do, recent news, stack, red
   flags. Casey passes the names by hand, because the VM cannot see Jobhunt's
   database. That is deliberate, and it stays hand-fed. Whether the hub may
   pass company names into the VM is open (see *Open questions*).
6. **Daily news digest from public APIs.** Added 2026-09-26, to build after
   the topic scout (#1) closes. Each day, one Markdown file of the day's
   posts, each rated on two scales:
   - **How big the news is**, computed from the API data (points, comments,
     how fast they grew, and whether the story appears in more than one
     place). A calculation, not a model's opinion.
   - **Interest to Casey**, rated 1 to 5 by Hermes against Casey's interest
     profile, `~/Apps/Portfolio/CASEY-INTERESTS.md` (tiers of topics plus an
     "affects my machine" list), with a one-line reason, and related stories
     grouped.

   Sources: public, keyless APIs only, each checked before building
   (2026-09-27): Hacker News through Algolia's search API, Hugging Face's
   trending models, and arXiv (its API terms allow personal use at one
   request every three seconds, and its metadata is CC0). Out: Reddit (its
   Data API needs a registered app) and Lobsters (its robots.txt disallows
   all clients and declares `ai-input=no`, which rating by a model is). A
   further source is added only after the same check. Reddit, rechecked
   2026-11-05: its `robots.txt` is `User-agent: *` `Disallow: /`, so its
   anonymous feeds suit only a single fetch Casey asks for, never a
   scheduled job. Hermes's official `reddit-reading` skill is installed in
   the VM and was reviewed: read-only, Reddit hosts only, no file writes,
   and it switches to the OAuth API when `REDDIT_CLIENT_ID` and
   `REDDIT_CLIENT_SECRET` are set. It runs through `terminal`, so it works
   from the CLI in the VM, not from Telegram or the night job. Reddit
   becomes a night-task source only after Casey registers an OAuth app. The collector,
   `jobs/news-collect.py`, runs on the host and writes a dated candidates
   file per run, which is also the history trends will be counted from.

   Design, from the topic scout's lessons: a script collects the candidates
   through the APIs, so every link comes from the API and none is invented,
   and Hermes only rates a bounded list, so its context stays small. Every
   rating goes through `jobs/add-rating.sh`, which holds the profile's
   scoring section as a rule: each rating names what matched (machine,
   tier1, tier2, tier3, none, not-interested) and its score must fit that
   (5, 5 or 4, 4, 3, 2, 1). A script, not the model, renders the digest.
   Items that are not tech news and match no tier count as not-interested,
   because the profile's scale only defines 2 for tech news. "How big" is
   the source's own numbers for now. A computed size rating and grouping
   related stories come later. First run (2026-09-27): all 62 rated in 2
   minutes with no line refused, but the MATCH was often wrong, because the
   script checks that a score fits its MATCH and not that the MATCH fits the
   item. `machine` went to agent news that touches nothing on the machine,
   `tier1` was always scored 4 ("in passing") and never 5, and `tier3` was
   used as a "casual AI" catch-all though the profile's Tier 3 is cats,
   e-commerce, hosting and content pipelines. WordPress and Core Web Vitals
   items (Tier 1) landed in tier3. So the script now checks the MATCH too: a
   machine or tier rating quotes a term from that MATCH's own section of the
   profile, and tier1 at 4 must say "in passing". A loose quote from inside
   the right section (Drawgent quoting "agents", from the machine section's
   "Agents and VMs" label) still passes. Round 2 (Casey's profile edit, 2026-09-27)
   narrowed two broad Tier 1 phrases and added a Tier 2 bullet for agent
   research and other models: items at 5 fell from 25 to 10 to 12 of 62,
   run-to-run agreement from 92% to 82% as more items sat on the Tier 1 and
   Tier 2 line. The lever that worked was the profile's wording, not the
   script: the model follows the words it can quote. Round 3 narrowed the
   wording again (no bare "coding agents", GGUF tied to LLMs) and capped
   arXiv papers at 4 unless machine, after research papers took top slots
   through broad terms. It over-corrected: items at 5 fell to 8 and 2,
   agreement to 79%, and LLMs that fit this machine drifted to Tier 2
   through its "other new open-weight models" line. Round 4 (2026-09-30)
   narrowed that line to non-LLM models and LLMs over 35B, and the script
   now refuses a quote that is only a bold section heading ("AI
   automation"), the split behind most of the run-to-run disagreement.
   Round 5 found the model reading the profile's Tuning notes as rules
   (run 13 cited them to drop two LLMs to `none`), so the profile now goes
   into the VM without that section. Runs 14 and 15 then agreed on 85%,
   the best since round 1, with every LLM that fits this machine at 5.
   What still splits is 4 against `none`, for papers and models with no
   size in their name: the next lever is rating those in a script.
   Phases 9 and 10 (2026-09-30) did that for Hugging Face: the collector
   records each model's total parameters, and `add-rating.sh --hf` rates
   every HF item from its kind and size before Hermes starts, so Hermes
   rates only HN and arXiv. Phase 11 (2026-10-01) removed the arXiv cap's
   machine exemption after run 16 put a scaling-laws paper at machine 5 by
   quoting "MoE layers": a paper now rates at most 4.

   The profile is personal, so it lives in Portfolio next to MASTER-CASEY.md,
   gitignored there like it, as its single source (Casey moved it there
   2026-09-27 after a morning in this repo's root, gitignored). It is never
   copied into this repo, and it is copied into the VM only for a digest
   run. That
   run has no web tools (the script already fetched everything), so nothing
   from the profile can leave the machine in a search query. It was drafted
   2026-09-26 from MASTER-CASEY.md, the interests Casey named (local and
   frontier AI, US stocks and trading, Bitcoin and Ethereum, PC gaming and
   self-hosting hardware, Arch Linux), and what is installed on the
   workstation. Topics start broad and Casey tunes them.

   Stocks and crypto items are information, not advice. Hermes never connects
   to a brokerage or exchange account and never trades. It runs daily as
   `jobs/run-news-digest.sh` (see *Scheduling*).
7. **Weekly routine that ends in a review queue.** Added 2026-09-26. One
   weekly run, at a quiet hour, that leaves everything waiting for Casey and
   takes no outward action. Each part runs where it belongs:
   - **Jobhunt scan:** the hub calls the `jobhunt` CLI on the host, which
     runs Jobhunt's own deterministic stages and reports new matches to
     Casey's review queue. Hermes is not involved, and Jobhunt's data stays
     out of the VM. Jobhunt's planned SSH gate (2026-10-24) is superseded
     (Jobhunt PLAN, *Automated caller*, 2026-11-01).
   - **Tailoring and autofill:** Casey triggers them for the matches he
     picks, as now.
   - **SEO-LLM ideas:** the topic scout (#1).
   - **SEO-LLM briefs:** at most, pre-running the research-collection stage
     for ideas Casey picked, stopping at the first approval gate. An SEO-LLM
     phase, planned in that repo.
   - **News:** the daily digest (#6).

   Never automated, by rule rather than by limit: submitting an application
   (the final outward-facing action is Casey's, and Jobhunt never clicks
   Submit), approving SEO-LLM brief stages (they are its quality control),
   and anything needing Casey's Ahrefs or Search Console logins. The router
   holds one model at a time, so the parts run one after another, not in
   parallel. The hub runs them (see *Scheduling*).

Suggested order: start with #1, which needs no repo access, touches nothing
outward, and feeds a pipeline already in use. Add #3 once Hermes has been
seen behaving on `qwen`. #6 came after #1 closed, and #7 comes with the hub.

---

## Scheduling

Decided 2026-11-02. A hub service in its own repository (an API, Postgres
and n8n, bound to 127.0.0.1) will schedule the jobs. It does not exist yet.

**On hold since 2026-11-04 (Casey).** Casey talks to Hermes through Telegram
and uses it as a research and data-organizing assistant, mostly overnight,
and keeps running Jobhunt and SEO-LLM by hand. So the hub and n8n are on
hold, and the notes below stay for when they return. The runners
(`jobs/run-topic-scout.sh`, `jobs/run-news-digest.sh`) stay as they are, for
hand runs.

- **Each job is one non-interactive host command with a stable contract:**
  `jobs/run-topic-scout.sh` (weekly) and `jobs/run-news-digest.sh` (daily).
  They share one exit contract with Jobhunt and SEO-LLM: 0 ok, 2 usage, 10
  input or config, 11 needs a person, 12 a stage failed, 13 a service the run
  needs is down, 14 busy. Each writes `out/<job>/status.json`. The README's
  *How to use* section has the details.
- **Until the hub exists, Casey runs them by hand,** the scout weekly and the
  news daily. After that, the hub's host runner calls them from the repo
  root, starts each under `setsid`, stops one by its process group, and
  retries only on 13 and 14.
- **A Telegram gateway and Hermes's own scheduler run in the VM** (reversed
  2026-11-04, was "No Hermes gateway and no cron in the VM. The caller lives
  on the host."). Reason: Casey queues research from Telegram, mostly
  overnight, and the result posts back there, which needs both inside the
  VM. The runners still drive Hermes the way a hand-run does (copy in, run
  over SSH on port 22220, copy out), and never start or stop the VM, take
  snapshots, or change Hermes's config.
- **Night tasks are queued through memory, and one fixed job runs them**
  (Casey, 2026-11-05, option A of three). Casey asks in Telegram, Hermes
  saves an entry starting `NIGHT:` with its `memory` tool, and the
  `night-tasks` cron job (03:00 VM time) gets up to 3 unrun entries from
  `jobs/night-queue.py`. Reason: Telegram must not get the `cronjob` tool,
  because a job's own `enabled_toolsets` beats `platform_toolsets.cron`
  and the model-facing tool forwards it, so qwen (or a web page it read)
  could create a job with `terminal`. Rejected: `/cron add` from Telegram
  (`/cron` is CLI-only) and queueing over SSH (not from the phone). Casey
  creates the one job over SSH, and `platform_toolsets.cron: [web]` holds
  every cron job to the web tools, because `hermes cron create` has no
  toolset flag. The job has no file tool, so a page cannot get it to read
  `~/.hermes/.env` and leak the token through a fetched URL. A page read
  in a Telegram chat could still plant a `NIGHT:` entry. Its worst case is
  a web-only run whose result goes to Casey, so that risk is accepted.
- **Hermes never calls the hub,** holds no hub token, and never sees Jobhunt
  or SEO-LLM data. Every output still ends in a file Casey reviews.
- **The runners need an SSH key for `hermes@localhost`,** because they never
  prompt. Installing it is Casey's (README, *Connecting guide*). Installed
  2026-11-03.

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
  guide closes that, at the cost of internet access. The hub will listen there
  too, so it must require auth on every route, even though Hermes never calls
  it. Setup step 11 is unaffected.
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
| `~/.hermes/config.yaml` `platforms.telegram.extra.dm_topics`, and `TELEGRAM_CRON_THREAD_ID` in `~/.hermes/.env` | The three topics with their thread IDs, and the topic night results post to (Phase 38) | Kept | Rolled back | Lost. The README's *Topics* block re-adds them, and Telegram makes new topics |
| `~/.config/systemd/user/` | The gateway's service unit | Kept | Rolled back | Lost. `hermes gateway install` again |
| `/var/lib/systemd/linger/hermes` | Starting the user service at boot with no login | Kept | Rolled back | Lost. `sudo loginctl enable-linger hermes` again |
| `~/.hermes/scripts/night-queue.py`, `~/jobs/night-tasks.md` | The night-task feeder and prompt (Phase 34) | Kept | Rolled back | Lost. The README's *Night tasks* block copies them from `jobs/` |
| `~/.hermes/cron/jobs.json` | The `night-tasks` job | Kept | Rolled back | Lost. The README's *Night tasks* block creates it again |
| `~/.hermes/memories/MEMORY.md`, `~/jobs/night-queue-done.txt` | The queue, and the hashes of tasks already run | Kept | Rolled back, so tasks run since the snapshot could run again | Lost, by design: no copy in the repo |

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
findings are under Good fits #1 and #6, and the router's under *How the
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

**How a job session runs**
- One session doing research and the sweep ran out of room: run 11
  (2026-09-26) skipped most finishing steps after 39 minutes of research,
  and used `execute_code` five times against the prompt. Hence two
  sessions, each limited by `--toolsets`.
- Without `--oneshot`, `--query-file` on a real terminal leaves the session
  open for a follow-up, so a chained second session only starts after
  Ctrl+C.
- When the prompt arrived through `read_file`, two of three runs lost its
  rules after compression and wrote an improvised file to the wrong path.
- A command run over SSH gets the VM's system `PATH`, which lacks
  `~/.local/bin`, where the installer put `hermes` (2026-11-03). The runner
  puts that directory first.
- sshd does not signal a command with no terminal when its client goes
  away, so killing the ssh client leaves Hermes running in the VM, holding
  the GPU. Each session therefore runs in its own process group, with the
  group's id in `~/scout/.hermes.pgid`, and a stopped run stops that group.
  A background job in a script ignores SIGINT, so the runner also kills its
  own ssh, or the lock would stay held until the session ended.

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

**Night tasks** (Phase 34, 2026-11-05, read from v0.22.7's source and help)
- Memory entries are split by `"\n§\n"` (`ENTRY_DELIMITER`,
  `tools/memory_tool_store.py`), and `MEMORY.md` holds
  `memory_char_limit` characters, 2200 by default. Hermes rewords what it
  saves ("today's" was saved as "todays"), so the feeder matches only a
  leading `NIGHT:`, in any case, and never the wording.
- A cron `--script` runs only from `~/.hermes/scripts/`, `.sh` under bash
  and anything else under Hermes's Python. Its stdout goes into the
  prompt, and an empty stdout skips the model call
  (`cron/scheduler.py`: "script produced no output, skipping AI call").
- `hermes cron create` and `edit` have no toolset flag, and
  `platform_toolsets.cron` was unset, so cron jobs had Hermes's default
  tools until Casey set `[web]`.
- The feeder records a task as done before printing it, so a task runs at
  most once, even when the run fails.
- Time (Phase 35): the VM is `America/New_York`, the same zone as the
  host, and no profile `timezone:` is set. The job runs at 03:00, moved
  from 02:00 on 2026-11-05 (Casey), because 02:00 does not exist on the
  March daylight-saving night. A missed run follows, in order: the job's
  own `catch_up`, then skip past an explicit `grace_minutes`, then
  `cron.catch_up_missed` (`cron/missed_runs.py`). A test set
  `grace_minutes`, which `cron edit` cannot clear, and a run missed past
  it was skipped despite `catch_up_missed: true`. So the job carries
  `--catch-up on`: a run missed while the VM was off runs once when it
  starts again.
  `HERMES_CRON_TIMEOUT` is unset: 600 s of inactivity, not total time.
  Untested: whether that limit trips, and fails loudly, when the router's
  one slot is busy with a long hand run (deferred 2026-11-05, Casey).
- Failure (Phase 35): a feeder that exits 1 does not stop the run.
  Hermes injects a `## Script Error` section ("Report this to the user")
  and runs the model anyway. Before the fix the model ignored it, the run
  was booked `completed`, and nothing failed loudly. `cron edit --script`
  does refuse a missing file. The prompt now opens with a "First" section:
  on a Script Error, reply `[CRON_FAILURE]` and do no tasks. Retested:
  the run was booked `failed` and Telegram got "Cron 'night-tasks'
  failed" with the error.
- Memory (Phase 35): cron runs always load `MEMORY.md`
  (`cron/scheduler.py`, `skip_memory=False`), and `memory.memory_enabled`
  is global, so the queue cannot be hidden from the night model. With no
  task list, the model did all 5 `NIGHT:` entries again, done ones
  included. So "each task runs once" rests on the feeder's list plus the
  prompt rule never to do memory `NIGHT:` entries. Retested with 5 old
  entries and 1 new: only the new one ran. Pruning done entries from
  memory is deferred.
- First real night (2026-11-06): the host was off at 03:00 and booted at
  05:03, the VM started at 05:08:27, and the job caught up at 05:08:55
  with the queued task's result in Telegram. A run firing on time at
  03:00 with the VM already up has not been seen yet.

**Topic scout checks**
- The field check catches "Best ..." titles typed anything but `roundup`:
  run 16 relabelled 8 of 10, and run 21 retitled one "How to Choose the
  Best ...".
- `UNVERIFIED` covers 401, 402, 403 and 429 because on 2026-09-26
  catster.com, nytimes.com (Wirecutter), consumerreports.org, purina.com and
  dailypaws.com answered 403 or 402 even for a made-up path. It covers 5xx
  because on 2026-11-03 three pages that answered 500 answered 200 half an
  hour later.
- The runner starts today's file and LEFT itself before research, because
  on 2026-11-03 Hermes skipped the prompt's step 1 on a second run the same
  day and added to the earlier run's ideas.

---

## Open questions

- Does sleeping free `qwen`'s host RAM as well as its VRAM? Very likely:
  1.65 GiB RSS while sleeping (2026-09-25) against 19.1 GiB loaded
  (2026-09-26). The two were measured on different days, so a same-session
  pair would close it.
- How does Hermes's context compaction behave against the router's HTTP 400 on
  an oversized request?
- How much does thinking cost on a long job, compared with thinking off?
- May the hub pass company names into the VM for Good fits #5? Until Casey
  decides, the company research stays hand-fed. Open since 2026-11-02.
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
