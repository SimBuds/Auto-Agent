# PLAN.md: Hermes Agent in a VM

A plan for running [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(Nous Research) on this workstation, against the Local-LLM router, inside a
QEMU virtual machine. Written 2026-09-25. **Status: installed and verified
2026-09-25, updated and re-verified 2026-10-09 to 2026-10-20** (Hermes Agent
`v0.21.6+337.g26610b0`, on `qwen`). No jobs are scheduled yet: each job is
one host command that Casey runs by hand until the hub exists, and the hub
calls after that (see *Scheduling*).

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
   hand first (README, *Job: topic scout*). Search uses Hermes's keyless
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
   further source is added only after the same check. The collector,
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

- **Each job is one non-interactive host command with a stable contract:**
  `jobs/run-topic-scout.sh` (weekly) and `jobs/run-news-digest.sh` (daily).
  They share one exit contract with Jobhunt and SEO-LLM: 0 ok, 2 usage, 10
  input or config, 11 needs a person, 12 a stage failed, 13 a service the run
  needs is down, 14 busy. Each writes `out/<job>/status.json`. The README's
  *Run it unattended* sections have the details.
- **Until the hub exists, Casey runs them by hand,** the scout weekly and the
  news daily. After that, the hub's host runner calls them from the repo
  root, starts each under `setsid`, stops one by its process group, and
  retries only on 13 and 14.
- **No Hermes gateway and no cron in the VM.** The caller lives on the host.
  The runners drive Hermes the way a hand-run does (copy in, run over SSH on
  port 22220, copy out), and never start or stop the VM, take snapshots, or
  change Hermes's config.
- **Hermes never calls the hub,** holds no hub token, and never sees Jobhunt
  or SEO-LLM data. Every output still ends in a file Casey reviews.
- **The runners need an SSH key for `hermes@localhost`,** because they never
  prompt. Installing it is Casey's (README setup, step 10). Installed
  2026-11-03.

---

## Where to hold back

- **Jobhunt data and the messaging gateway do not mix.** Jobhunt's rule is that
  no resume or job data leaves this hardware. A Telegram, Discord, or Slack
  gateway sends Hermes's output through that platform's servers. Keep anything
  Jobhunt-related as local files, or limit the gateway to the public-data jobs
  (1 to 3). Setting up a gateway (bot tokens, accounts) is Casey's to do.
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
- **Context is fixed at 65,536 tokens.** Hermes's own system prompt and its 34
  tool definitions take 15.6K of it (24%, measured 2026-09-25), which leaves
  about 50K for the work. Trimming unused toolsets is the way to get more room
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
| VM snapshots (`clean`, `pre-update-2026-10-09`, `hermes-configured`, the last retaken on v0.21.6 on 2026-10-20) | Normal sessions and `--snapshot apply` | Deleted by name, or with the disk image when the VM is removed. Not tracked in git. |

**Rule:** a change made by hand inside the VM (Hermes `config.yaml`, a job or
schedule definition, a reviewed skill) is copied into this repo in the same
phase that makes it. Anything still only in the VM when a snapshot is applied
is presumed lost. The folders for these files are created by the first phase
that codifies one.

---

## Setup

The step-by-step setup (check the host, build the VM, install Hermes, point it
at the router, snapshots, everyday use, removal) is in
[`README.md`](README.md#setup-guide-hermes-in-a-quickemu-debian-vm).

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
