# Auto-Agent

[Hermes Agent](https://github.com/NousResearch/hermes-agent) running in a
QEMU virtual machine, using models served by a llama.cpp router on the host.
The VM is the sandbox: Hermes runs its tools freely inside it, and a snapshot
undoes whatever it did. Two jobs are included, a topic scout for a content
site and a daily news digest, each run by one host command.

```text
Host                                     VM (Debian, quickemu)
  llama.cpp router 127.0.0.1:8080  <----   Hermes Agent, base_url http://10.0.2.2:8080/v1
  jobs/run-*.sh  ---- ssh -p 22220 ---->   ~/jobs, ~/scout, ~/news
```

**You need:** a Linux host with [quickemu](https://github.com/quickemu-project/quickemu),
and an OpenAI-compatible llama.cpp router on the host's loopback. This repo
was built against the Local-LLM router (models `gemma`, `qwen`, `lite`,
context 131,072). Anything that differs on your machine is listed in
[How to tailor](#how-to-tailor).

[`PLAN.md`](PLAN.md) holds the why: which jobs fit, the findings behind each
setting, and the load on the GPU.

## Setup guide

These steps write outside this repo (`~/VMs`, a disk image, installs in the
guest). Each block says where it runs.

### 1. Check the host

```bash
# Runs in: local terminal, host. Read-only.
quickemu --version                          # 4.9.9 was used to write this guide
ss -ltn | grep ':8080 '                     # must show 127.0.0.1:8080 (the router, loopback only)
curl -s http://127.0.0.1:8080/health        # must print {"status":"ok"}
free -g                                     # room for a 6 GB VM next to the models
```

### 2. Create the VM

```bash
# Runs in: local terminal, host. Creates ~/VMs. Safe to re-run: it replaces the three sizing lines.
mkdir -p ~/VMs && cd ~/VMs
quickget debian 13.7.0 netinst                # with no release, quickget debian lists them
CONF=debian-13.7.0-netinst.conf               # EDIT if quickget wrote a different name
sed -i '/^ram=/d;/^cpu_cores=/d;/^disk_size=/d' "$CONF"
printf 'ram="6G"\ncpu_cores="4"\ndisk_size="40G"\n' >> "$CONF"
cat "$CONF"                                   # must show the three lines above
quickemu --vm "$CONF" --public-dir none       # boots the installer
```

In the installer, choose no desktop, the SSH server and standard utilities.
Leave the root password blank, so your user gets `sudo`. Shut down with
`sudo poweroff` when it finishes.

### 3. Snapshot the clean install

```bash
# Runs in: local terminal, host, in ~/VMs, with the VM shut down.
quickemu --vm debian-13.7.0-netinst.conf --snapshot create clean
quickemu --vm debian-13.7.0-netinst.conf --snapshot info       # must list "clean"
```

### 4. Reach the router from the VM

Boot the VM (see [Connecting guide](#connecting-guide)), log in, then:

```bash
# Runs in: inside the VM.
sudo apt update && sudo apt install -y curl
curl -s http://10.0.2.2:8080/health                         # must print {"status":"ok"}
curl -s http://10.0.2.2:8080/v1/models | grep -o '"id":"[a-z]*"'   # must list your models
```

`10.0.2.2` is QEMU's address for the host's loopback. If the first `curl`
fails, stop: nothing after this works without it.

### 5. Install Hermes, reading the installer first

```bash
# Runs in: inside the VM, as your user.
sudo apt install -y git       # the installer needs git, and netinst lacks it
curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o install.sh
sha256sum install.sh          # compare with the hash of the copy you reviewed
less install.sh               # read what it installs (uv, Python, dependencies, Chromium)
bash install.sh --non-interactive
source ~/.bashrc
hermes --version              # must print a version
```

`--non-interactive` skips API-key setup and the messaging gateway service.
The next step sets the endpoint, and the gateway stays off.

### 6. Point Hermes at the router

```bash
# Runs in: inside the VM. Safe to re-run: each line overwrites the same key.
hermes config set model.provider custom
hermes config set model.base_url http://10.0.2.2:8080/v1
hermes config set model.default qwen
hermes config set model.api_key local
hermes config set model.context_length 131072
hermes config set skills.write_approval true
hermes config set auxiliary.background_review.enabled false
grep -n -E 'base_url|default:|context_length|write_approval' ~/.hermes/config.yaml
grep -n -A1 'background_review:' ~/.hermes/config.yaml   # the line after must show enabled: false
grep -n 'local_runtime' -A2 ~/.hermes/config.yaml         # nothing, or enabled: false
```

This block is the durable copy of Hermes's config: re-run it after
restoring an older snapshot. Each key is explained under
[Hermes config](#hermes-config).

### 7. Check it, then snapshot

Run `hermes` and give it a task that needs one tool call:

```text
Use your terminal tool to run `uname -r`, then tell me the kernel version in one line.
```

It should run the command without asking and answer in one line. On the
host, the router's log should show the requests, and after 10 idle minutes
the model should unload or sleep (with Local-LLM: `llm status`). Then shut
the VM down and snapshot it:

```bash
# Runs in: local terminal, host, in ~/VMs. Refuses to run while the VM is up.
if pgrep -af '[q]emu-system' ; then echo "STOP: the VM is still running."; else
  quickemu --vm debian-13.7.0-netinst.conf --snapshot create hermes-configured
  quickemu --vm debian-13.7.0-netinst.conf --snapshot info   # must list clean and hermes-configured
fi
```

### Removing it

```bash
# Runs in: local terminal, host. Deletes the VM and its disk. Not undoable.
rm -ri ~/VMs/debian-13.7.0-netinst ~/VMs/debian-13.7.0-netinst.conf
```

Nothing on the host or in this repo changes when the VM is removed.

## Connecting guide

Start the VM in its own terminal and leave that terminal open:

```bash
# Runs in: local terminal, host, in ~/VMs.
quickemu --vm debian-13.7.0-netinst.conf --public-dir none                   # normal session, changes kept
quickemu --vm debian-13.7.0-netinst.conf --public-dir none --status-quo      # throwaway session, changes discarded at shutdown
quickemu --vm debian-13.7.0-netinst.conf --snapshot apply hermes-configured  # reset after a bad run (VM shut down)
```

quickemu forwards the guest's SSH to a port on the host's loopback, recorded
in `~/VMs/debian-13.7.0-netinst/debian-13.7.0-netinst.ports`. This repo uses
22220 and the user `hermes`:

```bash
# Runs in: local terminal, host. An interactive shell in the VM.
ssh -p 22220 hermes@localhost
```

The job runners never prompt, so they need an SSH key. Install it once, with
the VM running. It asks for the password one last time:

```bash
# Runs in: local terminal, host. Safe to run twice: a key already there is skipped.
ssh-copy-id -p 22220 hermes@localhost
ssh -p 22220 -o BatchMode=yes hermes@localhost true; echo "key check exit=$?"   # must print 0
```

quickemu forwards the port on all of the host's interfaces, so turn off
password login once the key works:

```bash
# Runs in: inside the VM. Keys only for SSH, then a config check and a reload. Safe to run twice.
echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/10-no-password.conf
sudo sshd -t && echo "sshd config OK"
sudo systemctl reload ssh
```

### Telegram

You talk to Hermes by DM with a Telegram bot. The gateway runs as a service
in the VM and answers your user ID only. The token never leaves the VM.

1. In Telegram, message **@BotFather**: `/newbot` (a username ending in
   `bot`), then `/setjoingroups` and choose **Disable**, so the bot cannot
   be added to a group. Leave group privacy on. Keep the token for the
   setup prompt only, never in a command line, chat or note.
2. Find your numeric user ID: message @userinfobot (Android), or in
   Telegram Desktop turn on Settings, Advanced, Experimental, "Show Peer
   IDs in Profile".
3. In the VM, run the setup, answer the service question with "Skip", then
   limit Telegram chats to five tools that run no commands, before anything starts:

```bash
# Runs in: inside the VM. Interactive: choose Telegram, paste the token, give your user ID as the only allowed user. Skip the service.
hermes gateway setup
hermes config set platform_toolsets.telegram "[web, todo, clarify, session_search, memory]"
grep -n -A5 '^  telegram:' ~/.hermes/config.yaml                          # must list exactly those five
grep -c '^TELEGRAM_BOT_TOKEN=' ~/.hermes/.env                              # must print 1 (a count, never the token)
grep '^TELEGRAM_ALLOWED_USERS=' ~/.hermes/.env | cut -d= -f2 | tr ',' '\n' | grep -c .   # must print 1
grep -c -E '^(TELEGRAM_GROUP_ALLOWED|GATEWAY_ALLOW_ALL)' ~/.hermes/.env       # must print 0
```

4. Install the service, and let it start at boot with no login:

```bash
# Runs in: inside the VM. Choose "User service". Safe to run twice.
hermes gateway install
sudo loginctl enable-linger hermes
loginctl show-user hermes -p Linger                  # must show Linger=yes
systemctl --user is-active hermes-gateway.service    # must print active
```

Send `/new` when a chat starts repeating itself: a session's earlier
replies steer the next ones. Messages sent while the VM is off or
rebooting are dropped, not queued. `/skills pending` lists skills waiting
for approval.

#### Topics

The bot chat is split into three topics, General, Research and Night, each
with its own history. Memory and skills stay shared, so a night task queued
in any topic is picked up. Night results post in Night. With Threaded Mode
on there is no plain chat: a message sent in **All Messages** makes Telegram
open a new topic, which Hermes treats as a new session (seen 2026-11-06). So
write in General, Research or Night. Do not send `/topic`: it makes the
main chat a commands-only lobby.

1. On the phone, open BotFather's Mini App (search `botfather`, tap
   **Open** on the verified result. The `/mybots` text menu does not have
   this). Then **My bots**, the bot, **Bot Settings**, **Threads
   Settings**, and turn on **Threaded Mode**.
2. Back up the config and declare the topics. Telegram is configured from
   `.env`, so this adds a new `platforms:` section and edits nothing else:

```bash
# Runs in: inside the VM. Safe to run twice: it skips when dm_topics or a platforms: section already exists.
CFG=~/.hermes/config.yaml
BAK=~/.hermes/config.yaml.before-topics
if grep -q 'dm_topics' "$CFG"; then
  echo "skip: dm_topics already in config.yaml"
elif grep -q '^platforms:' "$CFG"; then
  echo "STOP: config.yaml already has a platforms: section. Nothing changed."
else
  TG_ID=$(sed -n 's/^TELEGRAM_ALLOWED_USERS=//p' ~/.hermes/.env | tr -d "\"' ")
  case "$TG_ID" in
    ''|*[!0-9]*) echo "STOP: TELEGRAM_ALLOWED_USERS is not one numeric ID. Nothing changed." ;;
    *)
      echo "user ID found: ${#TG_ID} digits"
      if [ -e "$BAK" ]; then echo "skip: backup already exists"; else cp "$CFG" "$BAK" && echo "backup made: $BAK"; fi
      printf '%s\n' '' 'platforms:' '  telegram:' '    extra:' '      dm_topics:' \
        "      - chat_id: $TG_ID" '        topics:' '        - name: General' \
        '        - name: Research' '        - name: Night' >> "$CFG"
      echo "added dm_topics:"
      tail -n 9 "$CFG" | sed -E 's/chat_id: [0-9]+/chat_id: <your ID>/'
      ;;
  esac
fi
```

3. Restart the gateway. It creates the topics and writes their IDs back
   into `config.yaml`:

```bash
# Runs in: inside the VM. Telegram is down for about 30 s.
systemctl --user restart hermes-gateway.service
sleep 45
systemctl --user is-active hermes-gateway.service    # must print active
grep -E "Setting up [0-9]+ DM topic|Created DM topic|Persisted thread_id|not a forum|forums_disabled" ~/.hermes/logs/gateway.log | tail -n 8
```

The log must show three `Persisted thread_id` lines. `not a forum` means
Threaded Mode is still off. Turn it on and repeat this step.

4. Send cron results to Night:

```bash
# Runs in: inside the VM. Safe to run twice: it skips when the key is already set.
ENVF=~/.hermes/.env
LOG=~/.hermes/logs/gateway.log
if grep -q '^TELEGRAM_CRON_THREAD_ID=' "$ENVF"; then
  echo "skip: TELEGRAM_CRON_THREAD_ID already set"
else
  TID=$(sed -n "s/.*Persisted thread_id=\([0-9]*\) for topic 'Night'.*/\1/p" "$LOG" | tail -n 1)
  echo "Night thread_id: ${TID:-none}"
  case "$TID" in
    ''|*[!0-9]*) echo "STOP: no Night topic ID in the gateway log. Nothing changed." ;;
    *)
      printf 'TELEGRAM_CRON_THREAD_ID=%s\n' "$TID" >> "$ENVF"
      echo "added TELEGRAM_CRON_THREAD_ID=$TID"
      systemctl --user restart hermes-gateway.service
      sleep 45
      systemctl --user is-active hermes-gateway.service
      ;;
  esac
fi
```

To undo, restore `~/.hermes/config.yaml.before-topics`, delete the
`TELEGRAM_CRON_THREAD_ID=` line from `.env`, and restart the gateway.

## How to tailor

### VM settings

- RAM, cores and disk are the three lines in setup step 2. 6 GB and 4 cores
  leave room for a model that offloads to the CPU. More can push the host
  into swap.
- A different port or user: use them in your SSH commands, and set
  `AUTO_AGENT_VM` (default `hermes@localhost`) and `AUTO_AGENT_SSH_PORT`
  (default `22220`) for the runners. They read nothing else about the VM.

### Router and models

- Base URL: `model.base_url` in setup step 6, and `AUTO_AGENT_ROUTER`
  (default `http://10.0.2.2:8080`), which each run probes from inside the
  VM.
- Model: `model.default`. Pin one, so Hermes never makes the router swap
  models. Set `AUTO_AGENT_MODEL` (default `qwen`) to the same name: each run
  checks the router lists it.
- Context: `model.context_length` must match what the router serves. Read it
  with `curl -s http://127.0.0.1:8080/v1/models` (`--ctx-size` in each
  model's `args`, or `n_ctx` once it is loaded). Below 512K, Hermes compacts
  the conversation at 75% of it, so a smaller value compacts sooner. Each
  run compares the two and exits 10 on a mismatch, naming the fix.

**Router-only network (optional).** To stop the VM reaching anything else
on the host's loopback, add this line to the VM's `.conf`, then use
`http://10.0.2.100:8080/v1` as the base URL and repeat setup step 4 against
it:

```text
extra_args="-netdev user,id=n1,restrict=on,guestfwd=tcp:10.0.2.100:8080-tcp:127.0.0.1:8080 -device virtio-net-pci,netdev=n1"
```

`restrict=on` also cuts the VM off from the internet, so web search and
installs stop working. It is untested with quickemu 4.9.9's own network
setup.

### Hermes config

| Key                                     | Value                                            | Why                                                                                                                                   |
| --------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| `model.provider`                      | `custom`                                       | Any OpenAI-compatible server                                                                                                          |
| `model.base_url`                      | `http://10.0.2.2:8080/v1`                      | The host's router, through QEMU's address for the host                                                                                |
| `model.default`                       | `qwen`                                         | One pinned model                                                                                                                      |
| `model.api_key`                       | `local`                                        | A placeholder: the router has no auth                                                                                                 |
| `model.context_length`                | `131072`                                       | The router's context, stated rather than guessed                                                                                      |
| `skills.write_approval`               | `true`                                         | Skills Hermes writes wait in `~/.hermes/pending/skills/` until you approve them (`/skills pending`, `/skills approve`)          |
| `auxiliary.background_review.enabled` | `false`                                        | Stops the post-run review drafting skills and memory notes on its own                                                                 |
| `platform_toolsets.telegram`          | `[web, todo, clarify, session_search, memory]` | Telegram chats can search the web, plan, ask you questions, search past chats and keep notes. They cannot run commands or write files |
| `platform_toolsets.cron`              | `[web]`                                        | Every cron job, including the night-tasks job, can only search and read the web. Unset, cron jobs get Hermes's default tools, terminal included |

Leave the managed local runtime (`local_runtime`) off, since a second
llama.cpp would fight the router for VRAM. Keep the terminal backend
`local`, because the VM is the sandbox. A new skill is instructions Hermes
reuses without asking, so read its `SKILL.md` before trusting it.

### Job prompts and profile

**Topic scout** (article ideas for a content site, in the input shape of an
SEO pipeline):

- `jobs/topic-scout.md` is the research prompt: the site, its audience and
  the seasons it covers. `jobs/topic-scout-sweep.md` checks and finishes the
  file.
- `jobs/topic-scout-seen.txt` lists slugs already covered or suggested, so
  each run finds new ground. `jobs/topic-scout-seen-archive.txt` holds
  unreviewed tuning-run slugs, and nothing reads it.
- `jobs/add-idea.sh` is the only way an idea is added, and
  `jobs/check-scout.sh` checks the pulled file. They share their word rules,
  so change both together.

**News digest** (Hacker News, Hugging Face trending models and new arXiv
papers, rated against your interests):

- The profile is a markdown file of your interests, read from
  `~/Apps/Portfolio/CASEY-INTERESTS.md` or from `NEWS_PROFILE`. It never goes
  into this repo. Its `## Tuning notes` section, if any, stays on the host.
- `NEWS_CONTACT` is the contact address in the collector's User-Agent. It is
  read at run time and never stored.
- Collector limits, each an environment override: `NEWS_HN_HOURS` (24),
  `NEWS_HN_MIN_POINTS` (50), `NEWS_HN_LIMIT` (40), `NEWS_HF_LIMIT` (15),
  `NEWS_ARXIV_LIMIT` (20), `NEWS_ARXIV_CATS` (`cs.AI cs.CL cs.LG cs.SE`),
  `NEWS_CACHE_TTL` (3600 seconds).
- `jobs/news-rate.md` is the rating prompt. `jobs/add-rating.sh` is the only
  way a rating is recorded, and its header lists the scoring rules.

## How to use

### Run a job

With the VM running:

```bash
# Runs in: local terminal, host, in this repo, with the VM running. About 20 minutes on the GPU.
bash jobs/run-topic-scout.sh
echo "exit=$?"
```

```bash
# Runs in: local terminal, host, in this repo, with the VM running.
NEWS_CONTACT='you@example.com'   # EDIT: your contact address, for the User-Agent
NEWS_CONTACT="$NEWS_CONTACT" bash jobs/run-news-digest.sh
echo "exit=$?"
```

Each runner copies its files into the VM, runs the Hermes sessions, pulls the
result back and checks it. It never starts or stops the VM or changes
Hermes's config. One lock (`out/.hermes-run.lock`) lets only one job run at
a time.

| Job         | Writes to `out/`                                                                                                  |
| ----------- | ------------------------------------------------------------------------------------------------------------------- |
| Topic scout | `scout/topic-scout-DATE-HHMMSSZ.md`, `scout/status.json`, `scout/run.log`                                     |
| News digest | `news/digest-DAY.md`, `news/ratings-DAY.txt`, `news/candidates-DAY.*`, `news/status.json`, `news/run.log` |

Follow a run with `tail -f out/scout/run.log` (or `out/news/`). Do not start
a scout run between 23:00 and 01:00 VM time: a date change between its two
sessions fails the run.

### After a run

**Topic scout.** Review the file. Open each `UNVERIFIED` URL in a browser
(the site blocks scripts or had a server error), and check each timely
idea's event date. Then add the run's slugs to the seen list, so later runs
skip them:

```bash
# Runs in: local terminal, host, in this repo. NOT safe to run twice for the same file: it would add the slugs again.
F=out/scout/topic-scout-2026-01-01-000000Z.md   # EDIT: the file you reviewed
{ printf '\n# Suggested in %s\n' "$(basename "$F" .md)"; sed -n 's/^- Slug: `\(.*\)`$/\1/p' "$F"; } >> jobs/topic-scout-seen.txt
tail -n 12 jobs/topic-scout-seen.txt
```

**News digest.** Read `digest-DAY.md`, highest interest first. Where a
rating feels wrong, add a dated line to the profile's *Tuning notes* and
adjust the profile's wording.

### Exit codes

Both runners share these. A scheduler retries only 13 and 14.

| Exit | Meaning                                                                                                                                                                                         | `status.json` |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| 0    | Done and checked. Review any `warn` in `checks`                                                                                                                                             | Written         |
| 10   | Missing input or a setup fault: a job file, `NEWS_CONTACT`, the profile, the SSH key, `hermes` on the VM's `PATH`, or Hermes's context not matching the router's (`missing` names each) | Written         |
| 11   | Hermes's scanner refused a command. `reason` holds the line                                                                                                                                   | Written         |
| 12   | A step or check failed. Read `run.log`                                                                                                                                                        | Written         |
| 13   | A service is down: the VM (`vm`, including a session whose connection dropped), the router (`router`), or every news source (`network`). Retry later                                      | Written         |
| 14   | Another job holds the lock. Nothing ran                                                                                                                                                         | None            |
| 143  | Stopped by SIGTERM                                                                                                                                                                              | Written         |
| 130  | Stopped by Ctrl+C. Not retried                                                                                                                                                                  | Written         |
| 2    | Called with an argument                                                                                                                                                                         | None            |

`status.json` is written atomically, and every key is always present:

```json
{
  "job": "topic-scout",
  "exit_code": 0,
  "stop_reason": null,
  "finished_at": "2026-11-02T22:30:00Z",
  "outputs": ["/path/to/Auto-Agent/out/scout/topic-scout-2026-11-02-223000Z.md"],
  "checks": [{"id": "urls", "result": "warn", "detail": "38 OK, 4 UNVERIFIED, 0 DEAD"}],
  "missing": [],
  "reason": null,
  "log": "/path/to/Auto-Agent/out/scout/run.log"
}
```

`stop_reason` is `input` or `hermes_not_on_path` (10), `decision` (11),
`failed` (12), `vm`, `router` or `network` (13), `terminated` (143),
`interrupted` (130), or `null`. The scout's `checks` are `skills`, `fields`,
`urls` and `count` (plus `sweep` when research wrote no file). `count` warns
when a file has fewer than 10 ideas and nothing in the left-out list, which
can mean the session stopped early. The digest's are
`collect`, `digest` and `profile`.

### Stop a run

Start it with `setsid` and send SIGTERM to its process group. The runner
stops Hermes in the VM, writes `status.json` and exits 143. Killing only the
ssh client leaves Hermes running in the VM.

```bash
# Runs in: local terminal, host, in this repo.
setsid bash jobs/run-topic-scout.sh &
```

To stop it later, find the runner by its command line. `$!` does not work
here: in an interactive shell `setsid` forks, so `$!` is a process that has
already exited.

```bash
# Runs in: local terminal, host. Safe to run twice: with no run going it stops nothing.
JOB=run-topic-scout.sh   # EDIT: or run-news-digest.sh
PIDS=$(pgrep -f "^bash jobs/$JOB")
echo "runner PIDs found: ${PIDS:-none}"
if [ -z "$PIDS" ]; then
  echo "STOP: no $JOB run is going. Nothing was stopped."
elif [ "$(printf '%s\n' "$PIDS" | wc -l)" -ne 1 ]; then
  echo "STOP: more than one match. Nothing was stopped."
else
  kill -TERM -- "-$PIDS" && echo "sent TERM to process group $PIDS"
fi
```

It must print one PID and `sent TERM`. The run's `out/scout/status.json`
(or `out/news/`) then shows `"exit_code": 143`.

### Night tasks

Queue research from Telegram during the day. One cron job in the VM runs the
queue at 03:00 VM time and sends the results to the Night topic (see
*Topics*). Up to 3 tasks
run a night, and the rest wait for the next night. A night with nothing
queued sends nothing and does not start the model.

To queue a task, send the bot a message that starts with the save, so it
files the task instead of doing it now:

> Save this to memory as its own entry, exactly, and do not do the task now: NIGHT: find the three most-discussed llama.cpp changes this week

A message that starts with the task gets the task done in the chat, with
no entry saved (seen 2026-11-05).

Each task runs once. `jobs/night-queue.py` records each one it hands to the
job in `~/jobs/night-queue-done.txt`, so a task that runs and fails is not
retried. Queue it again with different wording to retry it. The job can only
search and read the web: a task that needs a command, a file, a login or a
post comes back as "Not done". The feeder also deletes each NIGHT entry
from memory once it has handed it over, so memory (about 2,200 characters in
all) does not fill with old tasks. It never touches other entries. If Hermes
reworded an entry after it ran, the new wording counts as a new task.

What a night can look like in Telegram:

- **Results:** one message with each task, its answer and its sources.
- **Nothing:** no tasks were queued, so the model never started.
- **"Cron 'night-tasks' failed: Night tasks did not run":** the feeder
  could not read the queue. The error follows. Fix it, then run the job by
  hand with `hermes cron run JOB_ID`.
- **Late results:** the VM was off at 03:00. The job runs once when the VM
  starts again (`catch_up: true` on the job).

`hermes cron runs JOB_ID` lists every run, and each run's full prompt and
reply is in `~/.hermes/cron/output/JOB_ID/` in the VM.

Install it once. Copy the feeder and the prompt into the VM (`--script`
only runs files from `~/.hermes/scripts/`):

```bash
# Runs in: local terminal, host, in this repo, with the VM running. Safe to run twice: scp overwrites.
ssh -p 22220 hermes@localhost 'mkdir -p ~/.hermes/scripts ~/jobs'
scp -P 22220 jobs/night-queue.py hermes@localhost:.hermes/scripts/night-queue.py
scp -P 22220 jobs/night-tasks.md hermes@localhost:jobs/night-tasks.md
```

Then limit every cron job to the web tools, and create the job:

```bash
# Runs in: inside the VM. Safe to run twice: the create is skipped when the job exists.
hermes config set platform_toolsets.cron "[web]"
grep -n -A2 '^  cron:' ~/.hermes/config.yaml        # must list only web
if hermes cron list | grep -q 'night-tasks'; then
  echo "skip: the night-tasks job already exists"
else
  hermes cron create --name night-tasks --script night-queue.py --deliver telegram --catch-up on '0 3 * * *' "$(cat ~/jobs/night-tasks.md)"
fi
hermes cron list                                    # night-tasks, 0 3 * * *, script night-queue.py, deliver telegram
```

After changing `jobs/night-tasks.md`, copy it again and update the job with
`hermes cron edit JOB_ID --prompt "$(cat ~/jobs/night-tasks.md)"`, using the
ID that `hermes cron list` shows. To see what tonight's run would get,
without marking anything done, read the queue with
`grep -i '^night:' ~/.hermes/memories/MEMORY.md` in the VM.

### Tests

The tests run on the host with fakes for the VM, the router and the network:

```bash
# Runs in: local terminal, host, in this repo. Each must end with failed=0 and exit 0.
bash jobs/test-run-topic-scout.sh    # passed=58
bash jobs/test-run-news-digest.sh    # passed=24
bash jobs/test-add-idea.sh           # passed=37
bash jobs/test-add-rating.sh         # passed=57
python3 jobs/test-news-collect.py    # passed=36
python3 jobs/test-night-queue.py     # passed=29
```

### Repo layout

| Path                                                                  | What it is                                     |
| --------------------------------------------------------------------- | ---------------------------------------------- |
| `jobs/run-topic-scout.sh`, `jobs/run-news-digest.sh`              | The runners, one per job                       |
| `jobs/runner-lib.sh`                                                | Shared runner code: SSH, lock, status, signals |
| `jobs/*.md`                                                         | Prompts Hermes receives                        |
| `jobs/add-idea.sh`, `jobs/add-rating.sh`, `jobs/check-scout.sh` | The scripts that hold each job's rules         |
| `jobs/news-collect.py`                                              | Fetches the news candidates on the host        |
| `jobs/night-queue.py`                                               | Feeds queued night tasks to the VM's cron job  |
| `jobs/test-*`, `jobs/fixtures/`                                   | Tests and their fixtures                       |
| `out/`                                                              | Results and logs, gitignored                   |
| `PLAN.md`, `AGENTS.md`                                            | The why, and the rules for coding agents       |
