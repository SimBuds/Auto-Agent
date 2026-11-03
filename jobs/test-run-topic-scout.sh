#!/bin/bash
# Tests for run-topic-scout.sh. Run on the host from the repo: bash jobs/test-run-topic-scout.sh
# Each test copies jobs/ into a temp repo and runs the runner there, so the real
# out/ is never written. Fakes stand in for the VM: ssh and scp run the remote
# side locally with a temp dir as the VM's home, hermes (only in that home's
# ~/.local/bin, as in the VM) writes the fixture scout file, and curl answers
# as the router or a competitor page. FAKE_* variables pick the failure.
# No network, no VM, no router.
JOBS="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d)
R="$T/repo"            # the temp repo the runner runs in
export FAKE_VM="$T/vm" FAKE_CALLS="$T/calls" FAKE_REPO="$R"
export FAKE_FIXTURE="$JOBS/fixtures/scout/topic-scout.md"
export FAKE_ROUTER_DOWN="$T/router-down"   # the router is down while this file exists
export FAKE_SSH_PID="$T/session-ssh.pid"   # the PID of the local ssh running a Hermes session
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail+1)); }

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
    cp "$FAKE_FIXTURE" "$HOME/scout/topic-scout-$(date +%F).md"
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
               if [ "$FAKE_NO_QWEN" = 1 ]; then echo '{"data":[{"id":"gemma"}]}'; else echo '{"data":[{"id":"gemma"},{"id":"qwen"}]}'; fi ;;
  *)           code=200
               for m in $FAKE_URL_CODES; do [ "${m%=*}" = "$url" ] && code=${m##*=}; done
               printf %s "$code" ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*
mv "$T/bin/hermes" "$T/hermes"

fresh() {  # a clean temp repo, fake VM and call log
  rm -rf "$R" "$FAKE_VM" "$FAKE_CALLS" "$FAKE_ROUTER_DOWN" "$FAKE_SSH_PID"
  mkdir -p "$R" "$FAKE_VM/.hermes/skills/demo" "$FAKE_VM/.local/bin"
  touch "$FAKE_VM/.hermes/skills/demo/SKILL.md" "$FAKE_CALLS"
  cp "$T/hermes" "$FAKE_VM/.local/bin/hermes"
  cp -r "$JOBS" "$R/jobs"
  # A fixed seen list, so changes to the live one cannot move the results.
  printf '# Fixture seen list\n\ncat-water-fountain\n' > "$R/jobs/topic-scout-seen.txt"
}
run() { PATH="$T/bin:$PATH" bash "$R/jobs/run-topic-scout.sh" "$@"; }
S="$R/out/scout/status.json"
j() { python3 -c "import json, sys; d = json.load(open(sys.argv[1])); print($2)" "$1"; }

# --- any argument: usage, exit 2, nothing written ---
fresh
out=$(run now 2>&1); rc=$?
[ $rc -eq 2 ] && [[ $out == *usage* ]] && [ ! -e "$R/out" ] && [ ! -s "$FAKE_CALLS" ] \
  && ok "argument: exit 2, nothing written" || bad "argument" "rc=$rc out=$out"

# --- happy path ---
fresh
mkdir -p "$R/out/scout"
echo '{"stale": true}' > "$S"
out=$(run 2>&1); rc=$?
[ $rc -eq 0 ] && ok "happy path: exit 0" || bad "happy path exit" "rc=$rc out=$out"
[ -f "$S" ] && [ "$(j "$S" 'd["job"], d["exit_code"], d["stop_reason"], d["missing"], d["reason"]')" = "topic-scout 0 None [] None" ] \
  && ok "status: job, exit 0, no stop reason" || bad "status fields" "$(cat "$S" 2>&1)"
[[ $(j "$S" 'd["finished_at"]') =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  && ok "status: finished_at is UTC" || bad "finished_at" "$(j "$S" 'd["finished_at"]')"
P=$(j "$S" '"\n".join(d["outputs"])')
[[ $P == "$R/out/scout/topic-scout-$(date +%F)-"[0-9][0-9][0-9][0-9][0-9][0-9]Z.md ]] && cmp -s "$P" "$FAKE_FIXTURE" \
  && ok "status: outputs holds the pulled file" || bad "outputs" "P=$P"
[ "$(j "$S" '"|".join(c["id"] + " " + c["result"] for c in d["checks"])')" = "skills pass|fields pass|urls pass" ] \
  && [ "$(j "$S" 'd["checks"][2]["detail"]')" = "6 OK, 0 UNVERIFIED, 0 DEAD" ] \
  && ok "status: skills, fields and urls pass" || bad "checks" "$(j "$S" 'd["checks"]')"
[ "$(j "$S" 'd["log"]')" = "$R/out/scout/run.log" ] && ok "status: log path" || bad "log path" "$(j "$S" 'd["log"]')"
! grep -q "status.json present" "$FAKE_CALLS" && ok "old status.json deleted before research" || bad "stale status" "$(cat "$FAKE_CALLS")"
first_plan=$(grep -n 'plan: 1' "$R/out/scout/run.log" | cut -d: -f1)
first_step=$(grep -n 'step: ' "$R/out/scout/run.log" | head -n 1 | cut -d: -f1)
[ -n "$first_plan" ] && [ -n "$first_step" ] && [ "$first_plan" -lt "$first_step" ] && grep -q 'plan: 8' "$R/out/scout/run.log" \
  && ok "log: the plan comes before the first step" || bad "plan order" "plan=$first_plan step=$first_step"
grep -q 'research reply' "$R/out/scout/run.log" && grep -q 'sweep reply' "$R/out/scout/run.log" \
  && ok "log: both session replies" || bad "replies in log" "$(cat "$R/out/scout/run.log")"
[ "$(grep -c '^hermes ' "$FAKE_CALLS")" -eq 2 ] && ok "two sessions ran" || bad "sessions" "$(cat "$FAKE_CALLS")"

# --- a second run the same day keeps the first file ---
/usr/bin/sleep 1
out=$(run 2>&1); rc=$?
n=$(ls "$R/out/scout/topic-scout-$(date +%F)-"*Z.md | wc -l)
[ $rc -eq 0 ] && [ "$n" -eq 2 ] && [ -f "$P" ] && ok "second run: a second file, the first kept" || bad "second run" "rc=$rc n=$n"

# --- lock held: exit 14, nothing run or written ---
fresh
mkdir -p "$R/out/scout"
echo '{"held": true}' > "$S"
exec 8>"$R/out/.hermes-run.lock"
flock -n 8
out=$(run 2>&1); rc=$?
exec 8>&-
[ $rc -eq 14 ] && [[ $out == *busy* ]] && [ "$(cat "$S")" = '{"held": true}' ] \
  && [ ! -e "$R/out/scout/run.log" ] && [ ! -s "$FAKE_CALLS" ] \
  && ok "lock held: exit 14, status and log untouched, nothing run" || bad "lock held" "rc=$rc out=$out"
out=$(run 2>&1); rc=$?
[ $rc -eq 0 ] && ok "lock released: the next run proceeds" || bad "after lock" "rc=$rc out=$out"

# --- research fails: exit 12, status written, no sweep ---
fresh
out=$(FAKE_RESEARCH_RC=1 run 2>&1); rc=$?
[ $rc -eq 12 ] && [ "$(j "$S" 'd["exit_code"], d["stop_reason"], d["outputs"]')" = "12 failed []" ] \
  && ! grep -q '^hermes topic-scout-sweep' "$FAKE_CALLS" \
  && ok "research fails: exit 12, status failed, no sweep" || bad "research fails" "rc=$rc $(cat "$S" 2>&1)"

# --- failures sorted into 10, 11, 12 and 13 ---
stop() { j "$S" 'd["exit_code"], d["stop_reason"]'; }
hermes_ran() { grep -q '^hermes ' "$FAKE_CALLS"; }
# A finished scout file whose summary miscounts its ideas, so the field check fails.
sed 's/^- Ideas: 2$/- Ideas: 3/' "$FAKE_FIXTURE" > "$T/miscount.md"

fresh
rm "$R/jobs/topic-scout-sweep.md"
out=$(run 2>&1); rc=$?
[ $rc -eq 10 ] && [ "$(stop)" = "10 input" ] && [ "$(j "$S" 'd["missing"][0]["path"]')" = "$R/jobs/topic-scout-sweep.md" ] \
  && [ ! -s "$FAKE_CALLS" ] && ok "job file missing: exit 10, path named, VM untouched" || bad "job file missing" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_SSH=denied run 2>&1); rc=$?
[ $rc -eq 10 ] && [ "$(stop)" = "10 input" ] && [ "$(j "$S" 'd["missing"][0]["path"]')" = None ] \
  && [[ $(j "$S" 'd["missing"][0]["message"]') == "no SSH key for hermes@localhost"* ]] \
  && ok "no SSH key: exit 10, missing says so" || bad "no SSH key" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_SSH=down run 2>&1); rc=$?
[ $rc -eq 13 ] && [ "$(stop)" = "13 vm" ] && ! hermes_ran && ok "VM down: exit 13 vm" || bad "VM down" "rc=$rc $(cat "$S" 2>&1)"

fresh
touch "$FAKE_ROUTER_DOWN"
out=$(run 2>&1); rc=$?
[ $rc -eq 13 ] && [ "$(stop)" = "13 router" ] && ! hermes_ran && ok "router down: exit 13 router, no session" || bad "router down" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_NO_QWEN=1 run 2>&1); rc=$?
[ $rc -eq 13 ] && [ "$(stop)" = "13 router" ] && ! hermes_ran && ok "qwen not served: exit 13 router" || bad "no qwen" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_SSH=127 run 2>&1); rc=$?
[ $rc -eq 10 ] && [ "$(stop)" = "10 hermes_not_on_path" ] && [[ $(j "$S" 'd["missing"][0]["message"]') == "hermes not found on PATH"* ]] \
  && ! grep -q 'topic-scout-sweep.md$' <(grep '^ssh .*hermes chat' "$FAKE_CALLS") \
  && ok "hermes exits 127: exit 10 hermes_not_on_path, no sweep" || bad "hermes 127" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_BLOCK=research run 2>&1); rc=$?
[ $rc -eq 11 ] && [ "$(stop)" = "11 decision" ] && [[ $(j "$S" 'd["reason"]') == "research: "*BLOCKED* ]] \
  && [ "$(j "$S" 'len(d["outputs"])')" = 1 ] && ok "scanner refusal in a passing run: exit 11, reason holds the line" \
  || bad "refusal" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_BLOCK=sweep FAKE_FIXTURE="$T/miscount.md" run 2>&1); rc=$?
[ $rc -eq 11 ] && [ "$(stop)" = "11 decision" ] && [[ $(j "$S" 'd["reason"]') == "sweep: "*"could not be resolved"* ]] \
  && [ "$(j "$S" '[c["result"] for c in d["checks"] if c["id"] == "fields"][0]')" = fail ] \
  && ok "refusal and a failed field check: still 11" || bad "refusal over 12" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_RESEARCH_RC=1 FAKE_ROUTER_DIES=1 run 2>&1); rc=$?
[ $rc -eq 13 ] && [ "$(stop)" = "13 router" ] && ok "session fails with the router down: exit 13 router" || bad "router died" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_SWEEP_MISSING=1 run 2>&1); rc=$?
[ $rc -eq 12 ] && [ "$(stop)" = "12 failed" ] && [ "$(j "$S" 'd["outputs"]')" = "[]" ] \
  && [[ $(j "$S" 'd["checks"][0]["id"], d["checks"][0]["result"], d["checks"][0]["detail"]') == "sweep fail FILE missing: "* ]] \
  && ok "sweep finds no file (a run across midnight): exit 12" || bad "FILE missing" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_FIXTURE="$T/miscount.md" run 2>&1); rc=$?
[ $rc -eq 12 ] && [ "$(stop)" = "12 failed" ] \
  && [ "$(j "$S" '[c["result"] + " " + c["detail"] for c in d["checks"] if c["id"] == "fields"][0]')" = "fail 1 check(s) failed" ] \
  && ok "field check fails: exit 12" || bad "fields fail" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_URL_CODES="https://example.org/window-perch-setup=404" run 2>&1); rc=$?
[ $rc -eq 12 ] && [ "$(stop)" = "12 failed" ] \
  && [ "$(j "$S" '[c["result"] + " " + c["detail"] for c in d["checks"] if c["id"] == "urls"][0]')" = "fail 5 OK, 0 UNVERIFIED, 1 DEAD" ] \
  && ok "a DEAD URL: exit 12" || bad "dead URL" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_URL_CODES="https://example.org/window-perch-setup=403" run 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(j "$S" '[c["result"] + " " + c["detail"] for c in d["checks"] if c["id"] == "urls"][0]')" = "warn 5 OK, 1 UNVERIFIED, 0 DEAD" ] \
  && ok "an UNVERIFIED URL: warn, exit 0" || bad "unverified URL" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_NEW_SKILL=1 run 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(j "$S" 'd["checks"][0]["id"], d["checks"][0]["result"]')" = "skills warn" ] \
  && [[ $(j "$S" 'd["checks"][0]["detail"]') == "1 new, 0 removed."*"/scout-tricks/SKILL.md" ]] \
  && ok "a new skill: warn naming it, exit 0" || bad "new skill" "rc=$rc $(cat "$S" 2>&1)"

# --- SIGTERM and SIGINT: the hub starts each run with setsid and stops it by
# process group with TERM, and Ctrl+C sends INT to a hand-run's group ---
# stop_at SIGNAL WHERE PATTERN: starts a run whose fake hangs at WHERE, waits
# for PATTERN in the call log, then sends SIGNAL to the run's group. The run
# starts with INT at its default, as a job in a terminal does.
stop_at() {
  local i
  fresh
  FAKE_HANG=$2 PATH="$T/bin:$PATH" setsid env --default-signal=INT bash "$R/jobs/run-topic-scout.sh" >"$T/term.out" 2>&1 &
  RUN=$!
  for i in $(seq 100); do grep -q "$3" "$FAKE_CALLS" && break; /usr/bin/sleep 0.1; done
  HPG=$(cat "$FAKE_VM/scout/.hermes.pgid" 2>/dev/null)
  /usr/bin/sleep 0.3
  kill "-$1" -- "-$RUN"
  for i in $(seq 100); do ps -p "$RUN" >/dev/null || break; /usr/bin/sleep 0.1; done
  ps -p "$RUN" >/dev/null && { echo "run $RUN still alive 10 s after $1, killing it"; kill -KILL "$RUN"; }
  wait "$RUN"
  RC=$?
  for i in $(seq 30); do [ -z "$HPG" ] || ! pgrep -g "$HPG" >/dev/null && break; /usr/bin/sleep 0.1; done
}
lock_free() { flock -n "$R/out/.hermes-run.lock" true; }
hermes_gone() { ! pgrep -g "$HPG" >/dev/null; }
ssh_gone() { [ -s "$FAKE_SSH_PID" ] && ! ps -p "$(cat "$FAKE_SSH_PID")" >/dev/null; }
leftovers() {  # whatever a failed run left behind, so the next test starts clean
  pgrep -g "$RUN" >/dev/null && kill -KILL -- "-$RUN"
  [ -n "$HPG" ] && pgrep -g "$HPG" >/dev/null && kill -KILL -- "-$HPG"
  /usr/bin/sleep 0.2
}
session_pattern() { echo "^hermes topic-scout$([ "$1" = sweep ] && echo -sweep).md"; }

for where in research sweep; do
  stop_at TERM "$where" "$(session_pattern "$where")"
  [ -n "$HPG" ] && [ $RC -eq 143 ] && [ "$(stop)" = "143 terminated" ] && hermes_gone && lock_free \
    && grep -q '^stopped Hermes process group' "$R/out/scout/run.log" \
    && ok "SIGTERM in $where: Hermes stopped in the VM, lock free, status 143 terminated" \
    || bad "SIGTERM in $where" "HPG=$HPG rc=$RC alive=$(pgrep -g "${HPG:-0}" | wc -l) $(cat "$S" 2>&1 | head -3)"
  leftovers
done

stop_at TERM copy "^scp .*add-idea.sh"
[ $RC -eq 143 ] && [ "$(stop)" = "143 terminated" ] && lock_free && ! grep -q 'kill -TERM' "$FAKE_CALLS" \
  && ok "SIGTERM during the copy: status 143, no remote stop tried" || bad "SIGTERM in copy" "rc=$RC $(cat "$FAKE_CALLS")"
leftovers

for where in research sweep; do
  stop_at INT "$where" "$(session_pattern "$where")"
  [ -n "$HPG" ] && [ $RC -eq 130 ] && [ "$(stop)" = "130 interrupted" ] && hermes_gone && ssh_gone && lock_free \
    && grep -q '^stopped Hermes process group' "$R/out/scout/run.log" \
    && ok "SIGINT in $where: Hermes stopped in the VM, local ssh gone, lock free, status 130 interrupted" \
    || bad "SIGINT in $where" "HPG=$HPG rc=$RC hermes_alive=$(pgrep -g "${HPG:-0}" | wc -l) ssh_alive=$(ps -p "$(cat "$FAKE_SSH_PID")" -o pid= | wc -l) $(cat "$S" 2>&1 | head -3)"
  leftovers
done

FAKE_SSH=nostop stop_at INT research "$(session_pattern research)"
[ $RC -eq 130 ] && [ "$(stop)" = "130 interrupted" ] && ssh_gone && lock_free \
  && grep -q 'could not stop Hermes' "$R/out/scout/run.log" \
  && ok "SIGINT when the remote stop fails: local ssh gone, lock free, status 130, log says so" \
  || bad "SIGINT, stop fails" "rc=$RC ssh_alive=$(ps -p "$(cat "$FAKE_SSH_PID")" -o pid= | wc -l) $(cat "$S" 2>&1 | head -3)"
leftovers

echo "passed=$pass failed=$fail"
rm -rf "$T"
[ $fail -eq 0 ]
