# Auto-Agent

Hermes Agent (Nous Research) running in a QEMU virtual machine on this
workstation, using the models served by the Local-LLM router on the host. The VM
is the sandbox: Hermes can run tools freely inside it and a snapshot undoes
whatever it did.

This README is the **how**: setting up the VM, pointing Hermes at the router,
and everyday use. [`PLAN.md`](PLAN.md) is the **why**: the shape of the setup,
which jobs fit, where to hold back, and the load on the models and the GPU.

**Status:** proposal. Nothing is installed yet.

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
quickget debian               # with no release it lists the available ones
quickget debian 13            # pick a release from that list; writes debian-13.conf
ls debian-13.conf             # must exist. If quickget used another name, use that below.
```

### 2. Size the VM

```bash
# Runs in: local terminal, host, in ~/VMs. Safe to re-run: it replaces these three lines.
CONF=debian-13.conf           # EDIT if quickget wrote a different name
sed -i '/^ram=/d;/^cpu_cores=/d;/^disk_size=/d' "$CONF"
printf 'ram="6G"\ncpu_cores="4"\ndisk_size="40G"\n' >> "$CONF"
cat "$CONF"                   # must show the three lines above
```

### 3. Install Debian

```bash
# Runs in: local terminal, host, in ~/VMs.
quickemu --vm debian-13.conf --public-dir none
```

`--public-dir none` stops quickemu sharing `~/Public` with the guest. In the
installer, choose no desktop environment, the SSH server, and standard system
utilities. quickemu prints an `ssh` command at start (a forwarded port on the
host's localhost) that is easier to use than the VM window. Shut the VM down
when the install finishes.

### 4. Snapshot the clean install

```bash
# Runs in: local terminal, host, in ~/VMs, with the VM shut down.
quickemu --vm debian-13.conf --snapshot create clean
quickemu --vm debian-13.conf --snapshot info       # must list "clean"
```

### 5. Reach the router from the VM

Boot it (`quickemu --vm debian-13.conf --public-dir none`), log in, then:

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
curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o install.sh
less install.sh               # read what it installs (Python 3.14, Node.js, ripgrep, FFmpeg)
bash install.sh
hermes --version              # must print a version
```

### 7. Point Hermes at the router

```bash
# Runs in: inside the VM.
hermes model
```

Choose a custom endpoint and enter:

| Setting | Value |
|---|---|
| Base URL | `http://10.0.2.2:8080/v1` |
| API key | any value, for example `local` |
| Model | `qwen` (or `lite` for quick jobs) |

If setup offers a managed local model runtime, decline it (in `config.yaml`
that is the `local_runtime` section with `enabled: false`). The router already
serves the models on the GPU, and a second llama.cpp would fight it for VRAM.
Leave the terminal backend on `local`, because the VM is the sandbox. Do not
start `hermes gateway` yet.

### 8. Snapshot the working setup

```bash
# Runs in: local terminal, host, in ~/VMs, with the VM shut down.
quickemu --vm debian-13.conf --snapshot create hermes-configured
```

### 9. First run and checks

Start the VM, run `hermes`, and give it a small task that needs one tool call
(a web search and a two-line summary). Then on the host:

```bash
# Runs in: local terminal, host.
llm status                                                        # qwen loaded while Hermes works
journalctl --user -u llama-server --since -15min --no-pager | grep -c "proxying request"
```

Leave Hermes idle for more than 10 minutes and run `llm status` again. `qwen`
should read `sleeping`. If it stays `loaded`, something in Hermes is calling the
model in the background: read the router log to see how often.

### 10. Everyday use

```bash
# Runs in: local terminal, host, in ~/VMs.
quickemu --vm debian-13.conf --public-dir none                   # normal session, changes kept
quickemu --vm debian-13.conf --public-dir none --status-quo      # throwaway session, changes discarded
quickemu --vm debian-13.conf --snapshot apply hermes-configured  # reset after a bad run (VM shut down)
```

`--status-quo` is the easy way to let Hermes try something risky: nothing it
does survives the shutdown.

### 11. Optional: router-only network

To stop the VM reaching CUPS, VS Code's ports, and anything else on the host's
loopback, add this line to `debian-13.conf`:

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
rm -ri ~/VMs/debian-13 ~/VMs/debian-13.conf
```

Nothing on the host, in this repo, or in Local-LLM changes when the VM is removed.
