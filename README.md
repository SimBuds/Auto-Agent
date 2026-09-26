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
(commit `5dcfd72`, Python 3.14.7) into `~/.hermes`.

### 7. Point Hermes at the router

```bash
# Runs in: inside the VM. Safe to re-run: each line overwrites the same key.
hermes config set model.provider custom
hermes config set model.base_url http://10.0.2.2:8080/v1
hermes config set model.default qwen
hermes config set model.api_key local
hermes config set model.context_length 65536
sed -n '/^model:/,/^[a-z_]*:/p' ~/.hermes/config.yaml | grep -v '^ *#' | grep -v '^ *$'
grep -n 'local_runtime' -A2 ~/.hermes/config.yaml   # nothing, or enabled: false
```

These five keys are the whole change from the installed `config.yaml`, and
this block is their durable copy (see *Persistence split* in PLAN.md). They
replace the interactive `hermes model` picker, and the result is the same.

| Key | Value | Why |
|---|---|---|
| `model.provider` | `custom` | Any OpenAI-compatible server (`llamacpp` is an alias) |
| `model.base_url` | `http://10.0.2.2:8080/v1` | The host's router, through QEMU's address for the host |
| `model.default` | `qwen` | One pinned model, so Hermes never makes the router swap |
| `model.api_key` | `local` | Placeholder. The router has no auth. |
| `model.context_length` | `65536` | The router's fixed context, stated rather than guessed |

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
