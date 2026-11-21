# Auto-Agent

**Status: finished (2026-11-21).** This was a test of
[Hermes Agent](https://github.com/NousResearch/hermes-agent) on local
models, run from 2026-09-25 to 2026-11-21. It is kept as a record and is
no longer developed. What it taught went into
[Friends-Hermes](https://github.com/SimBuds/Friends-Hermes), which reused
this setup guide, the VM persistence split and the memory budget for a
Discord bot that answers a few friends.

The test ran Hermes in a QEMU virtual machine, using models served by a
llama.cpp router on the host. The VM was the sandbox: Hermes ran its tools
freely inside it, and a snapshot undid whatever it did. Casey talked to it
through a private Telegram chat, as a search assistant for tech and AI
news, products and prices, and deep research, which could also schedule
tasks and post the results back.

The guide below is written in the present tense, as it was used. It worked
as written on Hermes v0.23.2.

```text
Host                                     VM (Debian, quickemu)
  llama.cpp router 127.0.0.1:8080  <----   Hermes Agent, base_url http://10.0.2.2:8080/v1
  Telegram (your phone)  <-------------   Hermes's Telegram gateway
```

**You need:** a Linux host with [quickemu](https://github.com/quickemu-project/quickemu),
and an OpenAI-compatible llama.cpp router on the host's loopback. This repo
was built against the Local-LLM router (models `freedom`, `gemma`, `qwen`, `lite`,
context 131,072). Anything that differs on your machine is listed in
[How to tailor](#how-to-tailor).

[`PLAN.md`](PLAN.md) holds the purpose, what was learned behind each
setting, and how the test ended.

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
hermes config set model.default freedom
hermes config set model.api_key local
hermes config set model.context_length 131072
hermes config set model.default_headers '{"Host": "localhost:8080"}'
hermes config set skills.write_approval true
hermes config set auxiliary.background_review.enabled false
grep -n -E 'base_url|default:|context_length|write_approval|Host:' ~/.hermes/config.yaml
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

Copying files into the VM with `scp` uses an SSH key. Install it once, with
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

#### One plain chat

Everything happens in one plain DM with the bot. BotFather's Threaded Mode
stays off and no `dm_topics` are declared. Topics were tried and dropped
(2026-11-17): with Threaded Mode on there is no plain chat, every message
in All Messages opens a new topic, and deleting topics leaves Hermes
pointing at thread IDs that no longer exist. Send `/new` to start a fresh
session instead.

#### Asking for research

Send these in the chat, starting with `/new`. Edit the topic and
the "I run ..." line to suit. Each asks for a quote per fact, because
tested replies (2026-11-17) were accurate where they quoted the page and
drifted where they did not: a number added, a word made stronger, or a
fact credited to the wrong source. Treat a reply as a map. Before acting
on a claim, open its link.

**News** (tested: quoted facts all held up)

```text
Search the web for the most important open-weight AI model and llama.cpp news from the past 7 days. I run local models on a single RTX 3080 (10 GB) with llama.cpp on Linux, NVIDIA/CUDA only, so skip AMD/HIP, Apple and funding news. Give me up to 5 items; fewer is fine. Check each page's own date and drop anything older than 7 days. For each: a bold one-line headline, the date, a short exact quote from the page that supports it, one sentence on why it matters to me, and the link. Every fact needs a quote or leave it out. End with a "Sources" list.
```

**Products and prices** (tested: quoted prices with store links; an
earlier version without the quote rule returned prices with no links)

```text
Find three well-reviewed PRODUCT under BUDGET CAD sold in Canada. Use only prices you saw on a page you opened. For each: model, price, store, a short exact quote from the page showing the price, rating if shown, and the link. If a store page would not load or showed no price, write "price not confirmed" and give the link anyway. Then one sentence of recommendation. Do not fill in any price you did not see.
```

Prices change daily. Confirm on the store page before buying.

**Deep research** (tested: the core findings were real, some details
stretched)

```text
Research this question and answer it for me: QUESTION. Start with a 3-sentence answer. Then group the evidence under short headings, each claim with a short exact quote from the page and its link. Say when a source's setup differs from mine (I run llama.cpp on one RTX 3080, 10 GB). Do not state the same finding twice. End with what is still uncertain and a "Sources" list. Keep it short enough to read on a phone.
```

#### Scheduling from Telegram

Ask in the chat, in plain words: "every weekday at 8am, find the top
three llama.cpp changes and summarize them with links". Hermes creates a
cron job, and each run posts its result back in the chat.
Ask "list my scheduled tasks" or "remove the llama.cpp task" the same way.
`/cron` does not work in Telegram (it is CLI-only).

Every scheduled job can only use the web tools, and the `aa_guard` plugin
(`hermes-plugin/aa_guard/`) refuses any job that asks for more: other
tools, a script, a working directory, or delivery anywhere but the chat it
came from. A refused request comes back as "Scheduling blocked by
aa_guard: ...". Why the guard exists is in PLAN.md, *What we learned*, *Cron*.

Install the plugin, then give Telegram the `cronjob` toolset. The guard must
be enabled before the tool is added:

```bash
# Runs in: local terminal, host, in this repo, with the VM running. Safe to run twice: scp overwrites.
python3 hermes-plugin/test_aa_guard.py                      # must end passed=41 failed=0
ssh -p 22220 hermes@localhost 'mkdir -p ~/.hermes/plugins/aa_guard'
scp -P 22220 hermes-plugin/aa_guard/plugin.yaml hermes-plugin/aa_guard/__init__.py hermes@localhost:.hermes/plugins/aa_guard/
ssh -p 22220 hermes@localhost 'ls ~/.hermes/plugins/aa_guard'   # must list __init__.py plugin.yaml
```

```bash
# Runs in: inside the VM. Safe to run twice. Telegram is down for about 30 s.
hermes plugins enable aa_guard
hermes plugins list --plain --no-bundled                    # aa_guard must show enabled
if hermes plugins list --plain --no-bundled | grep -Eq '^enabled[[:space:]].*[[:space:]]aa_guard$'; then
  hermes config set platform_toolsets.telegram "[web, todo, clarify, session_search, memory, cronjob]"
  grep -n -A7 '^  telegram:' ~/.hermes/config.yaml | head -n 8   # must list the five tools plus cronjob
  systemctl --user restart hermes-gateway.service
  sleep 45
  systemctl --user is-active hermes-gateway.service         # must print active
  grep -n -i 'aa_guard' ~/.hermes/logs/gateway.log | tail -n 5   # a load line for aa_guard, and no error
else
  echo "STOP: aa_guard is not enabled. Telegram was not given the cronjob tool."
fi
```

To undo, set `platform_toolsets.telegram` back to the five tools, restart
the gateway, then `hermes plugins disable aa_guard`.

**Offline reply (built and unit tested, never run in a live Hermes).** The
same plugin can answer for a router that is not there. With
`AA_ROUTER_URL=http://127.0.0.1:8080` in `~/.hermes/.env`, it checks the
router's `/health` before every model call. If nothing answers, a chat
message gets "Not online right now. The PC is off. Try again later." and a
scheduled job posts "Not online. The PC was off, so this run was skipped.",
with no model call. Unset, which is how the VM ran, there is no check. It
was written for a move to an always-on mini PC that was dropped. The
details are in PLAN.md, *Model and router* and *Cron*.

## How to tailor

### VM settings

- RAM, cores and disk are the three lines in setup step 2. 6 GB and 4 cores
  leave room for a model that offloads to the CPU. More can push the host
  into swap.
- A different port or user: use them in your SSH and `scp` commands.

### Router and models

- Base URL: `model.base_url` in setup step 6.
- Model: `model.default`. Pin one, so Hermes never makes the router swap
  models.
- Context: `model.context_length` must match what the router serves. Read it
  with `curl -s http://127.0.0.1:8080/v1/models` (`--ctx-size` in each
  model's `args`, or `n_ctx` once it is loaded). Below 512K, Hermes compacts
  the conversation at 75% of it, so a smaller value compacts sooner.

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

| Key                                     | Value                                            | Why                                                                                                                                             |
| --------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `model.provider`                      | `custom`                                       | Any OpenAI-compatible server                                                                                                                    |
| `model.base_url`                      | `http://10.0.2.2:8080/v1`                      | The host's router, through QEMU's address for the host                                                                                          |
| `model.default` | `freedom` | One pinned model: the uncensored Qwen 3.6 35B A3B |
| `model.default_headers` | `{Host: localhost:8080}` | Passes llama.cpp's loopback Host check from inside the VM (see PLAN.md, *Model and router*) |
| `model.api_key`                       | `local`                                        | A placeholder: the router has no auth                                                                                                           |
| `model.context_length`                | `131072`                                       | The router's context, stated rather than guessed                                                                                                |
| `skills.write_approval`               | `true`                                         | Skills Hermes writes wait in `~/.hermes/pending/skills/` until you approve them (`/skills pending`, `/skills approve`)                    |
| `auxiliary.background_review.enabled` | `false`                                        | Stops the post-run review drafting skills and memory notes on its own                                                                           |
| `platform_toolsets.telegram`          | `[web, todo, clarify, session_search, memory, cronjob]` | Telegram chats can search the web, plan, ask you questions, search past chats, keep notes and schedule tasks (guarded by `aa_guard`). They cannot run commands or write files |
| `platform_toolsets.cron`              | `[web]`                                        | Every cron job can only search and read the web. Unset, cron jobs get Hermes's default tools, terminal included |

Leave the managed local runtime (`local_runtime`) off, since a second
llama.cpp would fight the router for VRAM. Keep the terminal backend
`local`, because the VM is the sandbox. A new skill is instructions Hermes
reuses without asking, so read its `SKILL.md` before trusting it.

## Repo layout

| Path                   | What it is                               |
| ---------------------- | ---------------------------------------- |
| `hermes-plugin/aa_guard/`, `hermes-plugin/test_aa_guard.py` | The plugin (cron guard and offline reply) and its tests |
| `PLAN.md`, `AGENTS.md` | The why, and the rules for coding agents |
