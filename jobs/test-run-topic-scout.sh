#!/bin/bash
# Tests for run-topic-scout.sh. Run on the host from the repo: bash jobs/test-run-topic-scout.sh
# Each test copies jobs/ into a temp repo and runs the runner there, so the real
# out/ is never written. Fakes on PATH stand in for the VM: ssh and scp run the
# remote side locally with a temp dir as the VM's home, hermes writes the
# fixture scout file, and curl answers 200. No network, no VM, no router.
JOBS="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d)
R="$T/repo"            # the temp repo the runner runs in
export FAKE_VM="$T/vm" FAKE_CALLS="$T/calls" FAKE_REPO="$R"
export FAKE_FIXTURE="$JOBS/fixtures/scout/topic-scout.md"
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
HOME=$FAKE_VM bash -c "$*"
EOF
cat > "$T/bin/scp" <<'EOF'
#!/bin/bash
# fake scp: hermes@localhost:PATH is PATH under the fake VM home
while [ $# -gt 0 ]; do case $1 in -P|-o) shift 2 ;; -*) shift ;; *) break ;; esac; done
echo "scp $*" >> "$FAKE_CALLS"
args=()
for a in "$@"; do args+=("${a/#hermes@localhost:/$FAKE_VM/}"); done
cp "${args[@]}"
EOF
cat > "$T/bin/hermes" <<'EOF'
#!/bin/bash
# fake hermes: research writes the fixture as today's file, the sweep only replies
q=""
while [ $# -gt 0 ]; do [ "$1" = --query-file ] && q=$2; shift; done
echo "hermes $(basename "$q")" >> "$FAKE_CALLS"
[ -f "$q" ] || { echo "no query file $q" >&2; exit 1; }
case $q in
  */topic-scout.md)
    [ -e "$FAKE_REPO/out/scout/status.json" ] && echo "status.json present during research" >> "$FAKE_CALLS"
    cp "$FAKE_FIXTURE" "$HOME/scout/topic-scout-$(date +%F).md"
    echo "research reply"
    exit "${FAKE_RESEARCH_RC:-0}" ;;
  */topic-scout-sweep.md)
    echo "sweep reply" ;;
esac
EOF
printf '#!/bin/bash\nprintf 200\n' > "$T/bin/curl"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*

fresh() {  # a clean temp repo, fake VM and call log
  rm -rf "$R" "$FAKE_VM" "$FAKE_CALLS"
  mkdir -p "$R" "$FAKE_VM/.hermes/skills/demo"
  touch "$FAKE_VM/.hermes/skills/demo/SKILL.md" "$FAKE_CALLS"
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
[ "$(j "$S" '"|".join(c["id"] + " " + c["result"] for c in d["checks"])')" = "fields pass|urls pass" ] \
  && [ "$(j "$S" 'd["checks"][1]["detail"]')" = "6 OK, 0 UNVERIFIED, 0 DEAD" ] \
  && ok "status: fields and urls pass" || bad "checks" "$(j "$S" 'd["checks"]')"
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

echo "passed=$pass failed=$fail"
rm -rf "$T"
[ $fail -eq 0 ]
