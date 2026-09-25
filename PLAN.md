# PLAN.md: Hermes Agent in a VM

A plan for running [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(Nous Research) on this workstation, against the Local-LLM router, inside a
QEMU virtual machine. Written 2026-09-25. **Status: proposal. Nothing is
installed yet.**

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
4. **Router uptime watch.** The VM can reach `http://10.0.2.2:8080/health` and
   `/models`, so Hermes can alert when the router is down. Neither endpoint
   loads or wakes a model. It cannot see the host's kernel log, so it will not
   catch a GPU fault (Xid), only its effect on the router.
5. **Company research for Jobhunt.** Given a company name from `jobhunt list`,
   a one-page brief from public sources: what they do, recent news, stack, red
   flags. Casey passes the names by hand, because the VM cannot see Jobhunt's
   database. That is deliberate.

Suggested order: start with #1, which needs no repo access, touches nothing
outward, and feeds a pipeline already in use. Add #3 or #4 once Hermes has been
seen behaving on `qwen`.

---

## Where to hold back

- **Jobhunt data and the messaging gateway do not mix.** Jobhunt's rule is that
  no resume or job data leaves this hardware. A Telegram, Discord, or Slack
  gateway sends Hermes's output through that platform's servers. Keep anything
  Jobhunt-related as local files, or limit the gateway to the public-data jobs
  (1 to 4). Setting up a gateway (bot tokens, accounts) is Casey's to do.
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
  (memory upkeep, summaries, skill-writing). Whether Hermes has such background
  calls is not known yet. Check with `llm status` after it has been idle for 10
  minutes. It should say `sleeping`.
- **Wake-up cost:** `lite` answers in about 1 to 2 seconds after sleeping
  (measured). `gemma` and `qwen` wake times were not measured, but cold loads
  took about 7 and 13 seconds on build 11022, so expect roughly that on the
  first request after a quiet spell.
- **Thinking.** A request that does not set `enable_thinking` gets the chat
  template's default, and `gemma` was observed thinking by default. Check what
  Hermes sends: thinking makes every reply slower than the leaderboard's
  thinking-off numbers.

### Memory and CPU budget (31 GiB RAM, 24 threads)

- `qwen` runs its expert layers on the CPU with `load-mode = none`, so most of
  its 20.2 GiB GGUF sits in host RAM while it is loaded. Whether sleeping frees
  that RAM as well as the VRAM has not been measured.
- Give the VM **6 GB of RAM and 4 cores**. More RAM pushes the host into swap
  while `qwen` is loaded. The MoE layers use the host's CPU, so every busy VM
  core slows generation.
- **Context is fixed at 65,536 tokens.** Hermes's own system prompt and 40-plus
  tool definitions take a large share. An oversized request gets HTTP 400 from
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

## Setup

The step-by-step setup (check the host, build the VM, install Hermes, point it
at the router, snapshots, everyday use, removal) is in
[`README.md`](README.md#setup-guide-hermes-in-a-quickemu-debian-vm).

---

## Open questions

- Does Hermes call the model in the background while idle? README setup step 9 answers it.
- Does sleeping free `qwen`'s host RAM as well as its VRAM?
- How does Hermes's context compaction behave against the router's HTTP 400 on
  an oversized request?
- What does Hermes send for `enable_thinking`, and how slow is `qwen` with
  thinking on?

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
