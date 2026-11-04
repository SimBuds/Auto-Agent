#!/bin/bash
# Tests for run-topic-scout.sh. Run on the host from the repo: bash jobs/test-run-topic-scout.sh
# Each test copies jobs/ into a temp repo and runs the runner there, so the real
# out/ is never written. Fakes in jobs/test-fakes.sh stand in for the VM: ssh
# and scp run the remote side locally with a temp dir as the VM's home, hermes
# (only in that home's ~/.local/bin, as in the VM) writes the fixture scout
# file, and curl answers as the router or a competitor page. FAKE_* variables
# pick the failure.
# No network, no VM, no router.
JOBS="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d)
R="$T/repo"            # the temp repo the runner runs in
. "$JOBS/test-fakes.sh"
export FAKE_FIXTURE="$JOBS/fixtures/scout/topic-scout.md"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail+1)); }

fresh() {  # a clean temp repo, fake VM and call log
  rm -rf "$R" "$FAKE_VM" "$FAKE_CALLS" "$FAKE_ROUTER_DOWN" "$FAKE_SSH_PID"
  mkdir -p "$R" "$FAKE_VM/.hermes/skills/demo" "$FAKE_VM/.local/bin"
  touch "$FAKE_VM/.hermes/skills/demo/SKILL.md" "$FAKE_CALLS"
  cp "$T/hermes" "$FAKE_VM/.local/bin/hermes"
  fake_hermes_config
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

# --- the runner starts today's FILE and LEFT before research, because Hermes
# may skip the prompt's step 1 and add to an earlier run's file (Phase 22) ---
D=$(date +%F)
found() { grep '^research found' "$FAKE_CALLS"; }
fresh
out=$(run 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(found)" = "research found FILE: # Topic scout $D| LEFT bytes: 0" ] \
  && ok "first run of the day: research finds the title line and an empty LEFT" || bad "first run start" "rc=$rc $(found)"

fresh
mkdir -p "$FAKE_VM/scout"
printf '# Topic scout %s\n\n## 1. STALE-IDEA-MARKER\n' "$D" > "$FAKE_VM/scout/topic-scout-$D.md"
echo 'Left out: STALE-LEFT-MARKER' > "$FAKE_VM/scout/left-out-$D.txt"
echo 'YESTERDAY-MARKER' > "$FAKE_VM/scout/topic-scout-2026-01-01.md"
out=$(run 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(found)" = "research found FILE: # Topic scout $D| LEFT bytes: 0" ] \
  && ! grep -rq 'STALE-IDEA-MARKER' "$R/out/scout" \
  && ok "an earlier run today: research starts fresh, no stale idea pulled" || bad "stale file" "rc=$rc $(found)"
[ "$(cat "$FAKE_VM/scout/topic-scout-2026-01-01.md")" = YESTERDAY-MARKER ] \
  && ok "an earlier day's file is left alone" || bad "earlier day" "$(ls -l "$FAKE_VM/scout")"
grep -q "plan: 3 .*start today's FILE and LEFT empty" "$R/out/scout/run.log" \
  && ok "log: plan line 3 names the reset" || bad "plan 3" "$(grep 'plan: 3' "$R/out/scout/run.log")"

fresh
mkdir -p "$FAKE_VM/scout/topic-scout-$D.md"   # a directory: the reset cannot write it
out=$(run 2>&1); rc=$?
[ $rc -eq 12 ] && [ "$(j "$S" 'd["stop_reason"]')" = failed ] && ! grep -q '^hermes ' "$FAKE_CALLS" \
  && ok "the reset fails: exit 12, no session runs" || bad "reset fails" "rc=$rc $(grep '^hermes' "$FAKE_CALLS")"

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

# --- settings: AUTO_AGENT_* overrides reach the commands (a wrapper records
# ssh's own arguments, which the fake drops) ---
mkdir -p "$T/wrap"
printf '#!/bin/bash\necho "args $*" >> "%s/ssh-args"\nexec "%s/bin/ssh" "$@"\n' "$T" "$T" > "$T/wrap/ssh"
chmod +x "$T/wrap/ssh"
wrun() { PATH="$T/wrap:$T/bin:$PATH" bash "$R/jobs/run-topic-scout.sh"; }
fresh; rm -f "$T/ssh-args"
out=$(AUTO_AGENT_VM=tester@vm.example.test AUTO_AGENT_SSH_PORT=2299 FAKE_SSH=down wrun 2>&1); rc=$?
grep -q -- '-p 2299 .* tester@vm.example.test true$' "$T/ssh-args" && [ $rc -eq 13 ] \
  && ok "AUTO_AGENT_VM and AUTO_AGENT_SSH_PORT reach ssh" || bad "vm and port" "rc=$rc $(cat "$T/ssh-args" 2>&1)"

fresh
out=$(AUTO_AGENT_ROUTER=http://10.0.2.9:9999 run 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q '^ssh curl -s --max-time 10 http://10.0.2.9:9999/health' "$FAKE_CALLS" \
  && ok "AUTO_AGENT_ROUTER reaches the router probe" || bad "router url" "rc=$rc $(grep curl "$FAKE_CALLS")"

fresh
out=$(AUTO_AGENT_MODEL=gemma FAKE_NO_QWEN=1 run 2>&1); rc=$?
[ $rc -eq 0 ] && ok "AUTO_AGENT_MODEL=gemma passes the probe without qwen" || bad "model gemma" "rc=$rc $(cat "$S" 2>&1)"
fresh
out=$(AUTO_AGENT_MODEL=nomodel run 2>&1); rc=$?
[ $rc -eq 13 ] && [ "$(stop)" = "13 router" ] && ok "AUTO_AGENT_MODEL not served: exit 13 router" || bad "model missing" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(AUTO_AGENT_SSH_PORT=22x run 2>&1); rc=$?
[ $rc -eq 10 ] && [ "$(stop)" = "10 input" ] && [[ $(j "$S" 'd["missing"][0]["message"]') == *AUTO_AGENT_SSH_PORT* ]] && ! grep -q '^ssh ' "$FAKE_CALLS" \
  && ok "a non-numeric port: exit 10 input, no ssh" || bad "bad port" "rc=$rc $(cat "$FAKE_CALLS") $(cat "$S" 2>&1)"

# --- context: Hermes's model.context_length must equal what the router serves
# for the model (AGENTS.md: context length is checked, never assumed) ---
ctx_msg() { j "$S" 'd["missing"][0]["message"]'; }
fresh
out=$(run 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q 'context: Hermes 131072, router 131072 (qwen)' "$R/out/scout/run.log" \
  && ok "context equal: run goes on, both values logged" || bad "context equal" "rc=$rc $(grep context: "$R/out/scout/run.log")"
for c in 262144 65536; do
  fresh; fake_hermes_config $c
  out=$(run 2>&1); rc=$?
  [ $rc -eq 10 ] && [ "$(stop)" = "10 input" ] && ! hermes_ran \
    && [[ $(ctx_msg) == *"is $c"*"serves 131072"*"hermes config set model.context_length 131072"* ]] \
    && ok "Hermes context $c against 131072: exit 10, fix named" || bad "context $c" "rc=$rc $(cat "$S" 2>&1)"
done
fresh; fake_hermes_config none
out=$(run 2>&1); rc=$?
[ $rc -eq 10 ] && ! hermes_ran && [[ $(ctx_msg) == *"not set"* ]] \
  && ok "Hermes context unset: exit 10" || bad "context unset" "rc=$rc $(cat "$S" 2>&1)"
fresh
out=$(FAKE_CTX=none run 2>&1); rc=$?
[ $rc -eq 10 ] && ! hermes_ran && [[ $(ctx_msg) == *"router reports no context"* ]] \
  && ok "router serves no context for the model: exit 10" || bad "router no ctx" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_SSH=127 run 2>&1); rc=$?
[ $rc -eq 10 ] && [ "$(stop)" = "10 hermes_not_on_path" ] && [[ $(j "$S" 'd["missing"][0]["message"]') == "hermes not found on PATH"* ]] \
  && ! grep -q 'topic-scout-sweep.md$' <(grep '^ssh .*hermes chat' "$FAKE_CALLS") \
  && ok "hermes exits 127: exit 10 hermes_not_on_path, no sweep" || bad "hermes 127" "rc=$rc $(cat "$S" 2>&1)"

# A guest that reboots mid-session drops the connection (ssh exits 255) and can
# answer again by the time the router is probed (Phase 22, 2026-11-03).
fresh
out=$(FAKE_SSH=drop run 2>&1); rc=$?
[ $rc -eq 13 ] && [ "$(stop)" = "13 vm" ] \
  && ! grep -q 'topic-scout-sweep.md$' <(grep '^ssh .*hermes chat' "$FAKE_CALLS") \
  && [ "$(grep -c '^ssh curl -s --max-time 10' "$FAKE_CALLS")" -eq 1 ] \
  && ok "session ssh exits 255, VM answers again: exit 13 vm, no sweep, no second router probe" || bad "dropped session" "rc=$rc $(cat "$S" 2>&1)"

# Keepalive: ssh gives up on a dead VM in about a minute instead of waiting
# forever. ssh -G reads the options only and connects to nothing.
VM=hermes@localhost PORT=22220
eval "$(grep '^SSH=' "$R/jobs/runner-lib.sh")"
G=$(/usr/bin/ssh -G "${SSH[@]:1}" 2>&1)
grep -qx 'serveraliveinterval 15' <<<"$G" && grep -qx 'serveralivecountmax 4' <<<"$G" \
  && grep -q '^SCP=.*ServerAliveInterval=15 -o ServerAliveCountMax=4' "$R/jobs/runner-lib.sh" \
  && ok "ssh and scp keepalive: 15 seconds, 4 misses" || bad "keepalive" "$(grep -E '^serveralive' <<<"$G")"

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

# A 5xx is the server's own fault, not a gone page: in Phase 22 three 500s
# answered 200 half an hour later.
fresh
out=$(FAKE_URL_CODES="https://example.org/window-perch-setup=500 https://example.net/cat-puzzle-toys=503" run 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(j "$S" '[c["result"] + " " + c["detail"] for c in d["checks"] if c["id"] == "urls"][0]')" = "warn 4 OK, 2 UNVERIFIED, 0 DEAD" ] \
  && grep -q '^UNVERIFIED 500 ' "$R/out/scout/run.log" && grep -q '^UNVERIFIED 503 ' "$R/out/scout/run.log" \
  && ok "500 and 503: UNVERIFIED, warn, exit 0" || bad "5xx" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_URL_CODES="https://example.org/window-perch-setup=000" run 2>&1); rc=$?
[ $rc -eq 12 ] && [ "$(j "$S" '[c["result"] + " " + c["detail"] for c in d["checks"] if c["id"] == "urls"][0]')" = "fail 5 OK, 0 UNVERIFIED, 1 DEAD" ] \
  && ok "no answer (000): DEAD, exit 12" || bad "000" "rc=$rc $(cat "$S" 2>&1)"

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
