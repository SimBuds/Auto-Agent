# Auto-Agent

Hermes Agent (Nous Research) running in a QEMU virtual machine on this
workstation, using the models served by the Local-LLM router on the host. The VM
is the sandbox: Hermes can run tools freely inside it and a snapshot undoes
whatever it did.

This README is the **how**: setting up the VM, pointing Hermes at the router,
and everyday use. [`PLAN.md`](PLAN.md) is the **why**: the shape of the setup,
which jobs fit, where to hold back, and the load on the models and the GPU.

**Status:** installed and verified 2026-09-25 by following this guide. No
jobs are scheduled yet.

**Prerequisite:** the Local-LLM `llama-server` router running on the host at
`127.0.0.1:8080` and serving `gemma`, `qwen`, and `lite` (see the Local-LLM
README, *Serving other apps*).

## Setup guide: Hermes in a quickemu Debian VM

Every step here writes outside the repos (a `~/VMs` folder, a disk image, and
installs inside the guest), so Casey runs them. Each block says where it runs.

### 0. Check the host

```bash
# Runs in: local terminal, host. Read-only.
quickemu --version                          # 4.9.9 was used to write this guide
ss -ltn | grep ':8080 '                     # must show 127.0.0.1:8080 (the router, loopback only)
curl -s http://127.0.0.1:8080/health        # must print {"status":"ok"}
free -g                                     # room for a 6 GB VM next to the models
```

### 1. Download Debian

```bash
# Runs in: local terminal, host. Creates ~/VMs.
mkdir -p ~/VMs && cd ~/VMs
quickget debian                  # with no release it lists releases and editions
quickget debian 13.7.0 netinst   # release and edition are both required; netinst is the installer
ls debian-13.7.0-netinst.conf    # must exist. If quickget used another name, use that below.
```

### 2. Size the VM

```bash
# Runs in: local terminal, host, in ~/VMs. Safe to re-run: it replaces these three lines.
CONF=debian-13.7.0-netinst.conf           # EDIT if quickget wrote a different name
sed -i '/^ram=/d;/^cpu_cores=/d;/^disk_size=/d' "$CONF"
printf 'ram="6G"\ncpu_cores="4"\ndisk_size="40G"\n' >> "$CONF"
cat "$CONF"                   # must show the three lines above
```

### 3. Install Debian

```bash
# Runs in: local terminal, host, in ~/VMs.
quickemu --vm debian-13.7.0-netinst.conf --public-dir none
```

`--public-dir none` stops quickemu sharing `~/Public` with the guest. In the
installer, choose no desktop environment, the SSH server, and standard system
utilities. **Leave the root password blank**: Debian then installs `sudo` and
grants it to the user you create, which step 5 relies on. quickemu forwards
SSH to a port on the host's localhost (22220 on 2026-09-25, recorded in
`~/VMs/debian-13.7.0-netinst/debian-13.7.0-netinst.ports`), and
`ssh -p 22220 USER@localhost` is easier to use than the VM window. Shut the VM
down (`sudo poweroff`) when the install finishes.

### 4. Snapshot the clean install

```bash
# Runs in: local terminal, host, in ~/VMs, with the VM shut down.
quickemu --vm debian-13.7.0-netinst.conf --snapshot create clean
quickemu --vm debian-13.7.0-netinst.conf --snapshot info       # must list "clean"
```

### 5. Reach the router from the VM

Boot it (`quickemu --vm debian-13.7.0-netinst.conf --public-dir none`), log in, then:

```bash
# Runs in: inside the VM.
sudo apt update && sudo apt install -y curl
curl -s http://10.0.2.2:8080/health                         # must print {"status":"ok"}
curl -s http://10.0.2.2:8080/v1/models | grep -o '"id":"[a-z]*"'   # must list gemma, lite, qwen
```

If the first `curl` fails, stop here: nothing after this step works without it.

### 6. Install Hermes, reading the installer first

```bash
# Runs in: inside the VM, as your user.
sudo apt install -y git       # the installer requires git, and netinst does not ship it
curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o install.sh
sha256sum install.sh          # compare with the hash of the copy you reviewed
less install.sh               # read what it installs (uv, Python, dependencies, Chromium)
bash install.sh --non-interactive
source ~/.bashrc
hermes --version              # must print a version
```

`--non-interactive` skips the installer's last two stages: `hermes setup`
(API keys) and `hermes gateway install` (the messaging gateway service). The
endpoint is set in step 7 instead, and the gateway stays off until Casey
decides otherwise. On 2026-09-25 this installed Hermes Agent v0.21.5
(`v0.21.5+2367.g5dcfd72`, Python 3.14.7) into `~/.hermes`. On 2026-10-09
`hermes update` (which follows `main`) moved it to `v0.21.6+337.g26610b0`.
The config migration from schema 46 to 50 asked nothing and left every step 7
key as set, and step 9 and a news digest run passed on it (2026-10-20). The
update also tries to install cua-driver, the computer-use tool, which fails
on a missing `libXi.so.6` and cannot run in this desktop-less VM anyway.

### 7. Point Hermes at the router

```bash
# Runs in: inside the VM. Safe to re-run: each line overwrites the same key.
hermes config set model.provider custom
hermes config set model.base_url http://10.0.2.2:8080/v1
hermes config set model.default qwen
hermes config set model.api_key local
hermes config set model.context_length 65536
hermes config set skills.write_approval true
hermes config set auxiliary.background_review.enabled false
sed -n '/^model:/,/^[a-z_]*:/p' ~/.hermes/config.yaml | grep -v '^ *#' | grep -v '^ *$'
grep -n 'local_runtime' -A2 ~/.hermes/config.yaml   # nothing, or enabled: false
grep -n 'write_approval' ~/.hermes/config.yaml       # must show true
grep -n -A1 'background_review:' ~/.hermes/config.yaml   # the line after must show enabled: false
```

These seven keys are the whole change from the installed `config.yaml`, and
this block is their durable copy (see *Persistence split* in PLAN.md). The
five `model.*` keys replace the interactive `hermes model` picker, and the
result is the same.

| Key | Value | Why |
|---|---|---|
| `model.provider` | `custom` | Any OpenAI-compatible server (`llamacpp` is an alias) |
| `model.base_url` | `http://10.0.2.2:8080/v1` | The host's router, through QEMU's address for the host |
| `model.default` | `qwen` | One pinned model, so Hermes never makes the router swap |
| `model.api_key` | `local` | Placeholder. The router has no auth. |
| `model.context_length` | `65536` | The router's fixed context, stated rather than guessed |
| `auxiliary.background_review.enabled` | `false` | Turns off the post-run review that drafts skills and writes memory notes on its own. On 2026-09-26 it drafted a new `topic-scout` skill after four runs in a row, each a partial copy of `jobs/topic-scout.md`. `/refine` still runs a review by hand. (Hermes's example config names `skills.creation_nudge_interval` for this, but v0.21.5 does not recognize that key.) |
| `skills.write_approval` | `true` | Skills Hermes writes, including from its post-run self-improvement review, wait in `~/.hermes/pending/skills/` until approved with `/skills pending` and `/skills approve`. On 2026-09-25 it wrote one unasked, and it was truncated mid-command. |

The managed local runtime (`local_runtime` in `config.yaml`) is disabled by
default and stays that way. The router already serves the models on the GPU,
and a second llama.cpp would fight it for VRAM. Leave the terminal backend on
`local`, because the VM is the sandbox. Do not start `hermes gateway` yet.

### 8. Snapshot the working setup

Before snapshotting, prove the endpoint once: run `hermes`, ask it to reply
with the single word OK, and exit. Then shut the VM down (`sudo poweroff`).

```bash
# Runs in: local terminal, host, in ~/VMs. Refuses to run while the VM is up.
if pgrep -af '[q]emu-system' ; then echo "STOP: the VM is still running."; else
  quickemu --vm debian-13.7.0-netinst.conf --snapshot create hermes-configured
  quickemu --vm debian-13.7.0-netinst.conf --snapshot info   # must list clean and hermes-configured
fi
```

### 9. First run and checks

Start the VM, run `hermes`, and give it a task that needs one tool call and no
API key:

```text
Use your terminal tool to run `uname -r`, then tell me the kernel version in one line.
```

Hermes runs the command without asking for approval (terminal backend
`local`). Then on the host:

```bash
# Runs in: local terminal, host.
llm status                                                        # qwen loaded while Hermes works
journalctl --user -u llama-server --since -15min --no-pager | grep -E "proxying request|prompt eval time"
```

Expect at least two proxied requests: the first carries Hermes's full prompt
(about 15.6K tokens) and returns the tool call, and the second carries only the
tool result (under 100 new tokens, because the router reuses the cached
prefix). A short third request is Hermes's automatic session title.

Leave Hermes open and idle for more than 10 minutes and run `llm status` again.
`qwen` should read `sleeping`. If it stays `loaded`, something in Hermes is
calling the model in the background: read the router log to see how often.

Observed on 2026-09-25: the tool call worked, no requests arrived while Hermes
sat idle, and `qwen` slept exactly 10 minutes after the last request (VRAM
6,240 to 264 MiB).

### 10. Everyday use

```bash
# Runs in: local terminal, host, in ~/VMs.
quickemu --vm debian-13.7.0-netinst.conf --public-dir none                   # normal session, changes kept
quickemu --vm debian-13.7.0-netinst.conf --public-dir none --status-quo      # throwaway session, changes discarded
quickemu --vm debian-13.7.0-netinst.conf --snapshot apply hermes-configured  # reset after a bad run (VM shut down)
```

`--status-quo` is the easy way to let Hermes try something risky: nothing it
does survives the shutdown.

### 11. Optional: router-only network

To stop the VM reaching CUPS, VS Code's ports, and anything else on the host's
loopback, add this line to `debian-13.7.0-netinst.conf`:

```text
extra_args="-netdev user,id=n1,restrict=on,guestfwd=tcp:10.0.2.100:8080-tcp:127.0.0.1:8080 -device virtio-net-pci,netdev=n1"
```

Then use `http://10.0.2.100:8080/v1` as the base URL. The trade-off:
`restrict=on` also cuts the VM off from the internet, so web search and installs
inside the VM stop working. Do step 6 before switching it on. This line has not
been tested with quickemu 4.9.9's own network setup, so repeat step 5 against
`10.0.2.100` after adding it.

### 12. Removing it

```bash
# Runs in: local terminal, host. Deletes the VM and its disk. Not undoable.
rm -ri ~/VMs/debian-13.7.0-netinst ~/VMs/debian-13.7.0-netinst.conf
```

Nothing on the host, in this repo, or in Local-LLM changes when the VM is removed.

---

## Job: topic scout

Hermes researches article ideas for everything4cats and writes them in the
shape SEO-LLM takes as input. The prompt is [`jobs/topic-scout.md`](jobs/topic-scout.md),
and this repo holds its only durable copy. It runs by hand for now. Scheduling
waits until the output has proven worth automating (see PLAN.md, *Good fits*).

Each idea carries a slug, a type (`review`, `roundup`, `guide` or `how-to`),
3 to 6 suggested keywords (for SEO-LLM's `suggested.txt`), 3 to 5 competitor
URLs (for `competitors.txt`), a line on why now, a YMYL flag, and its sources.
The keyword-tool CSV exports that SEO-LLM also wants are still yours to pull.
When an idea becomes an SEO-LLM page, add its slug to
`jobs/topic-scout-seen.txt`.

### 1. Copy the prompt and the seen list into the VM

With the VM running:

```bash
# Runs in: local terminal, host, in this repo. Safe to re-run: it overwrites the VM copies.
ssh -p 22220 hermes@localhost 'mkdir -p ~/jobs ~/scout'
scp -P 22220 jobs/topic-scout.md jobs/topic-scout-sweep.md jobs/topic-scout-seen.txt jobs/add-idea.sh hermes@localhost:jobs/
```

`jobs/topic-scout-seen.txt` lists every slug already in SEO-LLM or already
suggested, so each run has to find new topics. The repo copy is the durable
one: step 5 adds to it, and this step copies it in before every run. Add
only reviewed runs. Tuning runs made on one day for one window exhausted
that window's topics (run 17 found 4 ideas in 40 minutes), so their
unreviewed suggestions live in `jobs/topic-scout-seen-archive.txt`, which
nothing reads.

`jobs/add-idea.sh` is the only way the research session adds an idea. It
prints TAKEN for a slug that is on the seen list, already in the file, or
repeats a seen topic (the word rules are in step 4). It prints REJECTED for a
"Best ..." title or a `best-` slug not typed `roundup`, a fourth roundup, or a
`Timely: yes`
idea whose "Why now" names no month from now to 3 months ahead. It numbers
the heading itself. Its word rules are the same as the field check's in step
4 (`jobs/check-scout.sh`), so keep the two identical. Its tests run on the
host, never in the VM:
`bash jobs/test-add-idea.sh` must end `passed=37 failed=0` and exit 0.

### 2. Run it

The prompt goes in as the user message itself, with `--query-file`, not as a
file Hermes is told to read. Hermes compresses its context when it fills,
which happened in every run on 2026-09-25 (13 to 17 searches returned 168,000
to 259,000 characters). Compression drops tool results but restates the user
message. When the prompt arrived through `read_file`, two of three runs lost
its rules and wrote an improvised file to the wrong path. `--query-file` sends
the file verbatim, with no shell interpretation.

```bash
# Runs in: inside the VM. Two non-interactive sessions, one after the other.
find ~/.hermes/skills -name SKILL.md | sort > ~/scout/skills-before.txt
hermes chat --oneshot --toolsets "web,terminal" --query-file ~/jobs/topic-scout.md && \
hermes chat --oneshot --toolsets "terminal" --query-file ~/jobs/topic-scout-sweep.md
```

The job runs as two sessions. The first researches and appends ideas. The
second, `topic-scout-sweep.md`, starts with a fresh context, checks the file
against the rules with fixed commands, and appends the summary. On 2026-09-26
one session doing both ran out of room: run 11 skipped most of the finishing
steps after 39 minutes of research. `--toolsets` limits each session to the
tools its prompt allows, so `execute_code`, `patch` and `write_file` are not
offered at all (run 11 used `execute_code` five times against the prompt).
If the second session replies "FILE missing", the first one wrote nowhere,
and there is nothing to sweep. `--oneshot` makes each session answer and exit.
Without it, `--query-file` on a real terminal leaves the session open for a
follow-up, and the second session only starts after Ctrl+C. `&&` starts the
sweep only if research exited cleanly.

When it exits, check whether Hermes wrote itself any new skills during the
run:

```bash
# Runs in: inside the VM. No output means no new or removed skills.
find ~/.hermes/skills -name SKILL.md | sort | diff ~/scout/skills-before.txt -
```

A new skill is instructions Hermes will reuse without asking, so read it
before trusting it (AGENTS.md, *Project-specific rules*).

### 3. Pull the file out

```bash
# Runs in: local terminal, host, in this repo. Safe to re-run: it overwrites local copies.
mkdir -p out/scout
scp -P 22220 'hermes@localhost:scout/topic-scout-*.md' out/scout/
ls -l out/scout/
```

`out/` is gitignored. Scout files are generated output and never committed.

### 4. Check the fields

This prints one `FAIL` line per problem and exits non-zero, or prints `PASS`.
It checks slug format, type, the YMYL and Timely lines, keyword and competitor
counts, that every competitor line is a URL, not a shop page, and not used by
another idea (or twice in one), at most 3 roundups, at least 60% timely ideas
(tied to a named event or season, which you judge from "Why now"), the idea count against the summary, slugs on the
seen list (`jobs/topic-scout-seen.txt`), "Best ..." titles and `best-` slugs
typed anything but `roundup` (run 16 relabelled 8 of 10, run 21 retitled one
"How to Choose the Best ..."), and Amazon URLs. It also prints a
`WARN` (without failing) when an idea marked `YMYL: no` mentions a health,
food, toxin, vet or weight word, or when a slug repeats a seen topic by the
same word rules as `add-idea.sh` (plurals count as the same word, and a slug
with one topic word matches on that word), because both are judgment calls.
The search results carry no publication dates, so timeliness is event-based:
check that each timely idea's event and date are right (for example,
Canadian Thanksgiving is the second Monday of October).

```bash
# Runs in: local terminal, host, in this repo.
F=out/scout/topic-scout-2026-09-25.md   # EDIT: the file you pulled
bash jobs/check-scout.sh fields "$F"
```

Then check that each competitor URL exists. Each line is labelled:

- `OK`: the page answered (200 to 399).
- `DEAD`: 404, 410, or no answer (`000`). The URL was probably made up, or
  the page is gone. Drop it.
- `UNVERIFIED`: 401, 402, 403 or 429. The site blocks scripts, and on
  2026-09-26 catster.com, nytimes.com (Wirecutter), consumerreports.org,
  purina.com and dailypaws.com answered 403 or 402 even for a made-up path.
  So this code proves nothing either way. Open these in a browser before
  using the idea.

```bash
# Runs in: local terminal, host, in this repo. One request per URL, two seconds apart.
F=out/scout/topic-scout-2026-09-25.md   # EDIT: the file you pulled
bash jobs/check-scout.sh urls "$F"
```

### 5. Record the run's topics as seen

Once you have reviewed a run and kept or rejected its ideas, add all of its
slugs to the seen list, so later runs do not suggest them again. Kept ideas
are covered, and rejected ones were already considered.

```bash
# Runs in: local terminal, host, in this repo. NOT safe to run twice for the same file: it would add the slugs again.
F=out/scout/topic-scout-2026-09-25.md   # EDIT: the file you reviewed
{ printf '\n# Suggested in %s\n' "$(basename "$F" .md)"; sed -n 's/^- Slug: `\(.*\)`$/\1/p' "$F"; } >> jobs/topic-scout-seen.txt
tail -n 12 jobs/topic-scout-seen.txt
```

### Run it unattended

`jobs/run-topic-scout.sh` runs steps 1 to 4 as one host command, for a
scheduler or a hand-run. It never prompts, never starts or stops the VM, and
never changes Hermes's config. Step 5 stays yours, after you review the file.

```bash
# Runs in: local terminal, host, in this repo, with the VM running.
bash jobs/run-topic-scout.sh
echo "exit=$?"
```

It connects with `BatchMode=yes`, so it needs an SSH key for
`hermes@localhost` (`ssh-copy-id -p 22220 hermes@localhost`, once). Without
one, ssh fails instead of asking for a password. A command run over SSH gets
the VM's system `PATH`, which lacks `~/.local/bin`, where the installer put
`hermes` (checked 2026-11-03), so the runner puts that directory first.

In order, it:

- takes `out/.hermes-run.lock`, one lock for every Hermes job, because they
  share the VM and the GPU
- deletes the last `out/scout/status.json`
- logs its plan
- checks its job files, SSH to the VM, and the router from inside the VM
  (setup step 5's two `curl` checks, with `qwen` listed)
- runs steps 1 to 4, reading the date from the VM
- pulls today's file to `out/scout/topic-scout-DATE-HHMMSSZ.md` (the time is
  UTC), so a second run on the same day keeps the first file
- writes `out/scout/status.json` and exits

The terminal shows only the step lines. Every command's output, Hermes's
replies included, is appended to `out/scout/run.log`. Follow a run with
`tail -f out/scout/run.log`.

| Exit | Meaning | `status.json` |
| --- | --- | --- |
| 0 | The file is pulled, the field check passed and no URL is DEAD. Review it, starting with any `warn` in `checks` | Written |
| 10 | A job file is missing, there is no SSH key, or `hermes` was not found over SSH (`stop_reason` `hermes_not_on_path`). Each is named in `missing` | Written |
| 11 | Hermes's scanner refused a command (`BLOCKED` or `could not be resolved`). `reason` holds the line. Decide what the job may run | Written |
| 12 | A step failed, the sweep found no file, the field check failed, or a URL is DEAD. Read `run.log` | Written |
| 13 | The VM did not answer SSH (`vm`), or the router is down or not serving `qwen` (`router`). Run again later | Written |
| 14 | Another Hermes job holds the lock. Nothing was run or written | None |
| 2 | Called with an argument | None |

A refusal outranks a later failure or a pass, because only a person can
clear it, and a failure after one is most likely its result. When a session
fails, the runner checks the router again, and a router that went down makes
the run 13, not 12. The sweep finds no file when research wrote nowhere, or
when the VM's date changed between the two sessions, so do not start a run
between 23:00 and 01:00 VM time. A `warn` never changes the exit code: an
`UNVERIFIED` URL (open it in a browser), or a new skill (read its `SKILL.md`
before trusting it).

The status file is written beside its final name and renamed into place, so a
reader sees the whole file or none. No file after a run means the run was
killed or crashed. Its keys follow SEO-LLM's `status.json`:

```json
{
  "job": "topic-scout",
  "exit_code": 0,
  "stop_reason": null,
  "finished_at": "2026-11-02T22:30:00Z",
  "outputs": ["/path/to/Auto-Agent/out/scout/topic-scout-2026-11-02-223000Z.md"],
  "checks": [
    {"id": "skills", "result": "pass", "detail": "no new or removed skills"},
    {"id": "fields", "result": "pass", "detail": "PASS: 10 ideas, all fields in shape"},
    {"id": "urls", "result": "warn", "detail": "38 OK, 4 UNVERIFIED, 0 DEAD"}
  ],
  "missing": [],
  "reason": null,
  "log": "/path/to/Auto-Agent/out/scout/run.log"
}
```

| Key | What it holds |
| --- | --- |
| `job`, `exit_code` | The job, and the same exit code the process returned |
| `stop_reason` | `input` or `hermes_not_on_path` (10), `decision` (11), `failed` (12), `vm` or `router` (13), or `null` when it finished |
| `finished_at` | When the file was written, in UTC |
| `outputs` | The pulled file's absolute path, or an empty list when none was pulled |
| `checks` | `sweep` (only when it found no file), `skills`, `fields` and `urls`, each with `result` `pass`, `warn` or `fail` and a one-line `detail` |
| `missing` | On 10 only: each thing to supply, with its absolute `path` (`null` when it is not a file) and a `message` |
| `reason` | On 11 only: the session and the line the scanner refused |
| `log` | The absolute path to `run.log` |

Every key is always present. The tests run on the host with fakes for the VM,
never against it: `bash jobs/test-run-topic-scout.sh` must end
`passed=29 failed=0` and exit 0.

## Job: news digest

A daily digest of AI, tech and programming news, rated for interest against
`CASEY-INTERESTS.md` (PLAN.md, Good fits #6). **Status:** built 2026-09-27,
run by hand. Collect on the host (step 1), rate in the VM (steps 2 and 3),
pull the digest (step 4).

The collector runs on the host, not in the VM. It reads three public,
keyless APIs whose terms allow this use: Hacker News through Algolia (stories
from the last 24 hours, counted from the start of the hour so the cache can
hit, with at least 50 points, top 40), Hugging Face's
trending models (top 15), and arXiv's newest papers in cs.AI, cs.CL, cs.LG
and cs.SE (20). Each item keeps its source's own numbers (points and
comments, trending score and likes). A Hugging Face model also gets a
`Params` line, its total parameters in billions: the largest of the API's
GGUF and safetensors totals and the size in its name ("27B", never the
active "A4B"), left out when none is known. Lobsters is not used: its robots.txt
disallows all clients and declares `ai-input=no`.

`CASEY-INTERESTS.md` is personal. It lives in `~/Apps/Portfolio`, next to
`MASTER-CASEY.md`, gitignored there, and is never copied into this repo.

### 1. Collect the candidates

The User-Agent carries a contact address, as the fetching rules require. It
comes from `NEWS_CONTACT` at run time and is never stored in the repo. Left
empty, the script stops before fetching anything.

```bash
# Runs in: local terminal, host, in this repo. Safe to re-run: within an hour it reads its cache and fetches nothing.
NEWS_CONTACT=''   # EDIT: your contact address, for the User-Agent
NEWS_CONTACT="$NEWS_CONTACT" python3 jobs/news-collect.py
echo "collect exit=$?"   # 0: all sources read. 3: a source FAILED (named in the file). 1: NEWS_CONTACT empty
```

It writes `out/news/candidates-DATE.md` (what Hermes will rate) and
`candidates-DATE.json` (kept, so trends can be counted later). Each request
is logged to stderr with its time. arXiv's terms allow one request every
three seconds, and a source that answers 429 or 5xx gets three tries with a
growing wait before it is marked FAILED. Limits and windows are constants at
the top of the script, each with a `NEWS_*` environment override.

Tests run on the host with no network, against `jobs/fixtures/news/`:
`python3 jobs/test-news-collect.py` must end `passed=36 failed=0` and exit 0.

### 2. Copy the candidates, the profile and the job into the VM

`DAY` is the date in the candidates file name from step 1. The profile goes
in only for this run: step 3 deletes it again. It goes in without its
*Tuning notes*, which are Casey's log, not rules: in run 13 the model cited
them to drop two LLMs to `none`.

```bash
# Runs in: local terminal, host, in this repo. Safe to re-run: it overwrites the VM copies.
DAY=$(date +%F)   # EDIT if step 1 ran on another day
ls -l "out/news/candidates-$DAY.md" ~/Apps/Portfolio/CASEY-INTERESTS.md   # both must exist
ssh -p 22220 hermes@localhost 'mkdir -p ~/news ~/jobs'
scp -P 22220 "out/news/candidates-$DAY.md" hermes@localhost:news/
awk '/^## Tuning notes/ { exit } 1' ~/Apps/Portfolio/CASEY-INTERESTS.md | ssh -p 22220 hermes@localhost 'cat > ~/news/CASEY-INTERESTS.md'
ssh -p 22220 hermes@localhost 'grep -c "Tuning notes" ~/news/CASEY-INTERESTS.md'   # must print 0
scp -P 22220 jobs/news-rate.md jobs/add-rating.sh hermes@localhost:jobs/
```

### 3. Rate them

Hermes gets only the `terminal` tool, so the profile cannot end up in a web
search. The VM's terminal can still reach the internet, so the prompt forbids
fetching anything, and the block deletes the profile from the VM whatever
the run's outcome. Setup step 11 (router-only network) would close that
fully.

`add-rating.sh` is the only way a rating is recorded. Each line is
`ID | SCORE | MATCH | REASON`, and it refuses a line whose ID is not in the
candidates or is already rated, whose score is not 1 to 5 or does not fit
its MATCH (machine 5, tier1 5 or 4, tier2 4, tier3 3, none 2,
not-interested 1), or whose reason is not 10 to 200 characters. A machine or
tier rating must quote, in double quotes, a term from that MATCH's own
section of the profile (read at run time), and tier1 at 4 must say "in
passing". An arXiv paper takes at most 4 and is never machine, so for
papers tier1 is 4 without "in passing". A quote that is only one of the profile's
bold headings ("Local AI", "AI automation") is refused, since it names a
category rather than a topic. Hugging Face items are rated by the script
before Hermes starts (`--hf`), from the collector's Kind and Params lines: a
text-generation or image-text-to-text model from 3B to 35B total
parameters is tier1 5. One under 3B (mostly OCR tools), over 35B, or of
unknown size is tier2 4, and so is any other kind. Hermes rates only HN and arXiv. Its tests run on the host with a made-up
profile, never the real one: `bash jobs/test-add-rating.sh` must end
`passed=57 failed=0`.

```bash
# Runs in: inside the VM.
bash ~/jobs/add-rating.sh --hf   # rates the hf: items first, prints one ADDED line each
hermes chat --oneshot --toolsets "terminal" --query-file ~/jobs/news-rate.md
bash ~/jobs/add-rating.sh --left
bash ~/jobs/add-rating.sh --digest; echo "digest exit=$?"   # 0: all rated. 3: some unrated, listed at the end
rm -v ~/news/CASEY-INTERESTS.md
ls ~/news/
```

### 4. Pull the digest

```bash
# Runs in: local terminal, host, in this repo.
DAY=$(date +%F)   # EDIT to the same DAY as step 2
scp -P 22220 "hermes@localhost:news/digest-$DAY.md" "hermes@localhost:news/ratings-$DAY.txt" out/news/
ls -l out/news/
```

`out/news/digest-DAY.md` lists every item by interest, highest first, with
the MATCH, the reason and the source's own size numbers. Where a rating feels
wrong, add a dated line to the profile's *Tuning notes*.
