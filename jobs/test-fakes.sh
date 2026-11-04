# Fakes for the runner tests, so no test touches the VM, the router or the
# network. Sourced by a test after it sets T (a temp dir) and R (the temp
# repo). Each fake reads FAKE_* variables to pick a failure. Moved verbatim
# from test-run-topic-scout.sh (Phase 19, 2026-11-03).

export FAKE_VM="$T/vm" FAKE_CALLS="$T/calls" FAKE_REPO="$R"
export FAKE_ROUTER_DOWN="$T/router-down"   # the router is down while this file exists
export FAKE_SSH_PID="$T/session-ssh.pid"   # the PID of the local ssh running a Hermes session

mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
# fake ssh: runs the remote command here, with HOME at the fake VM home
while [ $# -gt 0 ]; do case $1 in -p|-o) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
echo "ssh $*" >> "$FAKE_CALLS"
[[ $* == *"hermes chat"* ]] && echo $$ > "$FAKE_SSH_PID"
case $FAKE_SSH in
  denied) echo "hermes@localhost: Permission denied (publickey,password)." >&2; exit 255 ;;
  down)   echo "ssh: connect to host localhost port 22220: Connection refused" >&2; exit 255 ;;
  127)    [[ $* == *"hermes chat"* ]] && { echo "bash: line 1: hermes: command not found" >&2; exit 127; } ;;
  drop)   [[ $* == *"hermes chat"* ]] && { echo "Connection to localhost closed by remote host." >&2; exit 255; } ;;
  nostop) [[ $* == *"kill -TERM"* ]] && { echo "ssh: connect to host localhost port 22220: Connection refused" >&2; exit 255; } ;;
esac
# The VM side does not get the runner's lock fd: a real VM process never holds it.
HOME=$FAKE_VM bash -c "$*" 9>&-
EOF
cat > "$T/bin/scp" <<'EOF'
#!/bin/bash
# fake scp: hermes@localhost:PATH is PATH under the fake VM home
while [ $# -gt 0 ]; do case $1 in -P|-o) shift 2 ;; -*) shift ;; *) break ;; esac; done
echo "scp $*" >> "$FAKE_CALLS"
[ "$FAKE_HANG" = copy ] && /usr/bin/sleep 300
args=()
for a in "$@"; do args+=("${a/#hermes@localhost:/$FAKE_VM/}"); done
cp "${args[@]}"
EOF
cat > "$T/bin/hermes" <<'EOF'
#!/bin/bash
# fake hermes: echoes the query as the real one does, then research writes the
# fixture as today's file and the sweep only replies
q=""
while [ $# -gt 0 ]; do [ "$1" = --query-file ] && q=$2; shift; done
echo "hermes $(basename "$q")" >> "$FAKE_CALLS"
[ -f "$q" ] || { echo "no query file $q" >&2; exit 1; }
printf 'Query: '; cat "$q"
case $q in
  */topic-scout.md)
    [ -e "$FAKE_REPO/out/scout/status.json" ] && echo "status.json present during research" >> "$FAKE_CALLS"
    # What the session found, before it writes: the real one may skip the
    # prompt's step 1 and add to whatever is there (Phase 22, batch 1).
    f="$HOME/scout/topic-scout-$(date +%F).md" l="$HOME/scout/left-out-$(date +%F).txt"
    if [ -e "$f" ]; then saw=$(tr '\n' '|' < "$f"); else saw=none; fi
    if [ -e "$l" ]; then left=$(wc -c < "$l"); else left=none; fi
    echo "research found FILE: $saw LEFT bytes: $left" >> "$FAKE_CALLS"
    cp "$FAKE_FIXTURE" "$f"
    # The fixture has 2 ideas, so research says why in LEFT, unless FAKE_LEFT
    # is empty (nothing said, as batch 2 run 5) or missing (no LEFT file).
    case $FAKE_LEFT in
      empty)   : > "$l" ;;
      missing) rm -f "$l" ;;
      *)       echo 'Left out: fixture idea (2 competitors found)' >> "$l" ;;
    esac
    [ "$FAKE_BLOCK" = research ] && echo "  ┊ 💻 \$ cat <<'X' | bash  BLOCKED: single-query mode (-q) runs without a user present to approve it"
    [ "$FAKE_NEW_SKILL" = 1 ] && mkdir -p "$HOME/.hermes/skills/scout-tricks" && touch "$HOME/.hermes/skills/scout-tricks/SKILL.md"
    [ "$FAKE_ROUTER_DIES" = 1 ] && touch "$FAKE_ROUTER_DOWN"
    [ "$FAKE_HANG" = research ] && exec /usr/bin/sleep 300
    echo "research reply"
    exit "${FAKE_RESEARCH_RC:-0}" ;;
  */topic-scout-sweep.md)
    [ "$FAKE_BLOCK" = sweep ] && echo "Nested executable body could not be resolved"
    [ "$FAKE_HANG" = sweep ] && exec /usr/bin/sleep 300
    if [ "$FAKE_SWEEP_MISSING" = 1 ]; then echo "FILE missing: ~/scout/topic-scout-2099-01-01.md"; else echo "sweep reply"; fi ;;
esac
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
# fake curl: the router's two endpoints, or a competitor page's status code
url=${!#}
case $url in
  */health)    [ -e "$FAKE_ROUTER_DOWN" ] && exit 7; echo '{"status":"ok"}' ;;
  */v1/models) [ -e "$FAKE_ROUTER_DOWN" ] && exit 7
               # Each model's launch args carry its context, as the real router's do.
               # FAKE_CTX sets qwen's (default 131072), FAKE_CTX=none drops it.
               q='{"id":"qwen","status":{"value":"sleeping","args":["--ctx-size","'"${FAKE_CTX:-131072}"'"]}}'
               [ "$FAKE_CTX" = none ] && q='{"id":"qwen","status":{"value":"sleeping","args":[]}}'
               g='{"id":"gemma","status":{"value":"unloaded","args":["--ctx-size","131072"]}}'
               if [ "$FAKE_NO_QWEN" = 1 ]; then echo '{"data":['"$g"']}'; else echo '{"data":['"$g,$q"']}'; fi ;;
  *)           code=200
               for m in $FAKE_URL_CODES; do [ "${m%=*}" = "$url" ] && code=${m##*=}; done
               printf %s "$code" ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
# fake_hermes_config [CONTEXT]: the fake VM's Hermes config, with
# model.context_length CONTEXT (default 131072), or none for no such line.
fake_hermes_config() {
  mkdir -p "$FAKE_VM/.hermes"
  { echo 'model:'; echo '  default: qwen'
    [ "${1:-131072}" = none ] || echo "  context_length: ${1:-131072}"
    echo 'auxiliary:'; echo '  context_length: 999'; } > "$FAKE_VM/.hermes/config.yaml"
}
chmod +x "$T/bin/"*
mv "$T/bin/hermes" "$T/hermes"
