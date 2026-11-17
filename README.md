# Auto-Agent

[Hermes Agent](https://github.com/NousResearch/hermes-agent) running in a
QEMU virtual machine, using models served by a llama.cpp router on the host.
The VM is the sandbox: Hermes runs its tools freely inside it, and a snapshot
undoes whatever it did. You talk to it through a private Telegram chat, as a
search assistant for tech and AI news, products and prices, and deep
research, which can also schedule tasks and post the results back.

```text
Host                                     VM (Debian, quickemu)
  llama.cpp router 127.0.0.1:8080  <----   Hermes Agent, base_url http://10.0.2.2:8080/v1
  Telegram (your phone)  <-------------   Hermes's Telegram gateway
```

**You need:** a Linux host with [quickemu](https://github.com/quickemu-project/quickemu),
and an OpenAI-compatible llama.cpp router on the host's loopback. This repo
was built against the Local-LLM router (models `gemma`, `qwen`, `lite`,
context 131,072). Anything that differs on your machine is listed in
[How to tailor](#how-to-tailor).

[`PLAN.md`](PLAN.md) holds the purpose, what was learned behind each
setting, and the roadmap.

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

#### Topics

The bot chat is split into three topics, General, Research and Night, each
with its own history. Memory and skills stay shared across topics. Cron
job results post in Night. With Threaded Mode
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

#### Scheduling from Telegram

Ask in any topic, in plain words: "every weekday at 8am, find the top
three llama.cpp changes and summarize them with links". Hermes creates a
cron job, and each run posts its result back in the topic you asked from.
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
python3 hermes-plugin/test_aa_guard.py                      # must end passed=23 failed=0
ssh -p 22220 hermes@localhost 'mkdir -p ~/.hermes/plugins/aa_guard'
scp -P 22220 hermes-plugin/aa_guard/plugin.yaml hermes-plugin/aa_guard/__init__.py hermes@localhost:.hermes/plugins/aa_guard/
ssh -p 22220 hermes@localhost 'ls ~/.hermes/plugins/aa_guard'   # must list __init__.py plugin.yaml
```

```bash
# Runs in: inside the VM. Safe to run twice. Telegram is down for about 30 s.
hermes plugins enable aa_guard
hermes plugins list --plain --no-bundled                    # aa_guard must show enabled
if hermes plugins list --plain --no-bundled | grep -q 'aa_guard.*enabled'; then
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
| `model.default`                       | `qwen`                                         | One pinned model                                                                                                                                |
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
| `hermes-plugin/aa_guard/`, `hermes-plugin/test_aa_guard.py` | The cron guard plugin and its tests |
| `PLAN.md`, `AGENTS.md` | The why, and the rules for coding agents |
