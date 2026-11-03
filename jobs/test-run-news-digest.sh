#!/bin/bash
# Tests for run-news-digest.sh. Run on the host from the repo: bash jobs/test-run-news-digest.sh
# Each test copies jobs/ into a temp repo and runs the runner there, so the real
# out/ is never written. The shared fakes in jobs/test-fakes.sh stand in for the
# VM, and this file adds a fake collector (written over the temp repo's
# news-collect.py, which has its own suite) and a fake hermes that rates
# through the real add-rating.sh. The profile is made up: the real one is
# personal and never goes into a test. No network, no VM, no router.
JOBS="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d)
R="$T/repo"            # the temp repo the runner runs in
. "$JOBS/test-fakes.sh"
export NEWS_CONTACT=test@example.com NEWS_PROFILE="$T/profile.md"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail+1)); }

cat > "$NEWS_PROFILE" <<'EOF'
# CASEY-INTERESTS.md (test fixture)

PROFILE-BODY-MARKER

## Tier 1

- **AI automation:** agent frameworks and tooling.

## Tuning notes

PROFILE-TUNING-MARKER
EOF

cat > "$T/hermes" <<'EOF'
#!/bin/bash
# fake hermes for the news job: echoes the query as the real one does, then
# rates every unrated hn: and arxiv: item as none through add-rating.sh
q=""
while [ $# -gt 0 ]; do [ "$1" = --query-file ] && q=$2; shift; done
echo "hermes $(basename "$q")" >> "$FAKE_CALLS"
[ -f "$q" ] || { echo "no query file $q" >&2; exit 1; }
printf 'Query: '; cat "$q"
p=~/news/CASEY-INTERESTS.md
[ -s "$p" ] && echo "profile in the VM during the rating, Tuning notes lines: $(grep -c 'Tuning notes' "$p")" >> "$FAKE_CALLS"
[ "$FAKE_BLOCK" = rating ] && echo "  ┊ 💻 \$ cat <<'X' | bash  BLOCKED: single-query mode (-q) runs without a user present to approve it"
[ "$FAKE_ROUTER_DIES" = 1 ] && touch "$FAKE_ROUTER_DOWN"
[ "$FAKE_HANG" = rating ] && exec /usr/bin/sleep 300
cand=$(ls ~/news/candidates-*.md | sort | tail -n 1)
ids=$(sed -n 's/^### \(hn:.*\|arxiv:.*\)$/\1/p' "$cand")
[ "$FAKE_LEAVE_ONE" = 1 ] && ids=$(sed '$d' <<<"$ids")
for id in $ids; do echo "$id | 2 | none | a test item that no tier names"; done > ~/news/batch.txt
bash ~/jobs/add-rating.sh < ~/news/batch.txt
bash ~/jobs/add-rating.sh --left
# A directory in the profile's place, so the runner's rm -f cannot remove it.
[ "$FAKE_PIN_PROFILE" = 1 ] && rm "$p" && mkdir "$p"
exit "${FAKE_RATING_RC:-0}"
EOF
chmod +x "$T/hermes"

# Writes a candidates file in the collector's format and prints its summary
# line. FAKE_COLLECT: ok, partial (arxiv FAILED), allfail, crash.
cat > "$T/news-collect.py" <<'EOF'
import os, sys
from datetime import datetime, timezone
mode = os.environ.get("FAKE_COLLECT", "ok")
if not os.environ.get("NEWS_CONTACT", "").strip():
    print("ERROR: set NEWS_CONTACT", file=sys.stderr)
    sys.exit(1)
if mode == "crash":
    print("Traceback: fake crash", file=sys.stderr)
    sys.exit(2)
failed = {"partial": {"arxiv"}, "allfail": {"hn", "hf", "arxiv"}}.get(mode, set())
items = {
    "hn": [("hn:101", "Agent tooling release", "https://example.com/a", "", "", "points 120, comments 30"),
           ("hn:102", "A Go concurrency article", "https://example.com/b", "", "", "points 80, comments 12")],
    "hf": [("hf:test/Model-7B", "test/Model-7B", "https://huggingface.co/test/Model-7B", "text-generation", "7.0B", "likes 10")],
    "arxiv": [("arxiv:2611.00001", "A paper on agents", "https://arxiv.org/abs/2611.00001", "", "", "none")],
}
day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
out = os.environ.get("NEWS_OUT", "out/news")
os.makedirs(out, exist_ok=True)
lines = [f"# News candidates {day}", "", "## Sources", ""]
lines += [f"- {n}: FAILED: fake" if n in failed else f"- {n}: {len(v)} items" for n, v in items.items()]
lines += ["", "## Items"]
for n, v in items.items():
    if n in failed:
        continue
    for i, t, u, k, p, z in v:
        lines += ["", f"### {i}", "", f"- Title: {t}", f"- URL: {u}"]
        lines += [f"- Kind: {k}"] if k else []
        lines += [f"- Params: {p}"] if p else []
        lines += ["- Published: 2026-11-03T00:00:00Z", f"- Size: {z}"]
with open(f"{out}/candidates-{day}.md", "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"{out}/candidates-{day}.md: " + ", ".join(f"{n} FAILED" if n in failed else f"{n} {len(v)}" for n, v in items.items()))
sys.exit(3 if failed else 0)
EOF

fresh() {  # a clean temp repo, fake VM and call log
  rm -rf "$R" "$FAKE_VM" "$FAKE_CALLS" "$FAKE_ROUTER_DOWN" "$FAKE_SSH_PID"
  mkdir -p "$R" "$FAKE_VM/.hermes/skills" "$FAKE_VM/.local/bin"
  touch "$FAKE_CALLS"
  cp "$T/hermes" "$FAKE_VM/.local/bin/hermes"
  cp -r "$JOBS" "$R/jobs"
  cp "$T/news-collect.py" "$R/jobs/news-collect.py"
}
run() { PATH="$T/bin:$PATH" bash "$R/jobs/run-news-digest.sh" "$@"; }
S="$R/out/news/status.json"
DAY=$(date -u +%F)
j() { python3 -c "import json, sys; d = json.load(open(sys.argv[1])); print($2)" "$1"; }
stop() { j "$S" 'd["exit_code"], d["stop_reason"]'; }
check() { j "$S" '[c["result"] + " " + c["detail"] for c in d["checks"] if c["id"] == "'"$1"'"][0]'; }
hermes_ran() { grep -q '^hermes ' "$FAKE_CALLS"; }
profile_gone() { [ ! -e "$FAKE_VM/news/CASEY-INTERESTS.md" ] && [[ $(check profile) == "pass "* ]]; }

# --- any argument: usage, exit 2, nothing written ---
fresh
out=$(run now 2>&1); rc=$?
[ $rc -eq 2 ] && [[ $out == *usage* ]] && [ ! -e "$R/out" ] && [ ! -s "$FAKE_CALLS" ] \
  && ok "argument: exit 2, nothing written" || bad "argument" "rc=$rc out=$out"

# --- happy path ---
fresh
mkdir -p "$R/out/news"
echo '{"stale": true}' > "$S"
out=$(run 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(j "$S" 'd["job"], d["exit_code"], d["stop_reason"], d["missing"], d["reason"]')" = "news-digest 0 None [] None" ] \
  && ok "happy path: exit 0, status news-digest" || bad "happy path" "rc=$rc $(cat "$S" 2>&1) $(tail -n 5 "$R/out/news/run.log")"
[ "$(j "$S" '"|".join(d["outputs"])')" = "$R/out/news/digest-$DAY.md|$R/out/news/ratings-$DAY.txt" ] \
  && [ -s "$R/out/news/digest-$DAY.md" ] && [ -s "$R/out/news/ratings-$DAY.txt" ] \
  && ok "outputs: the digest and the ratings, pulled" || bad "outputs" "$(j "$S" 'd["outputs"]')"
[ "$(j "$S" '"|".join(c["id"] + " " + c["result"] for c in d["checks"])')" = "collect pass|digest pass|profile pass" ] \
  && [ "$(check digest)" = "pass WROTE: $FAKE_VM/news/digest-$DAY.md (4 of 4 rated)" ] \
  && ok "checks: collect, digest (4 of 4 rated), profile" || bad "checks" "$(j "$S" 'd["checks"]')"
grep -q '^ADDED: hf:test/Model-7B (5, tier1)' "$R/out/news/run.log" && ok "hf items rated by the script before the session" || bad "hf" "$(grep ADDED "$R/out/news/run.log")"
grep -q 'profile in the VM during the rating, Tuning notes lines: 0' "$FAKE_CALLS" \
  && ok "profile in the VM for the rating, without Tuning notes" || bad "profile during rating" "$(cat "$FAKE_CALLS")"
profile_gone && ok "profile removed from the VM after the run" || bad "profile removed" "$(ls "$FAKE_VM/news")"
! grep -rq 'PROFILE-BODY-MARKER\|PROFILE-TUNING-MARKER' "$R/out" && ! grep -q "$NEWS_CONTACT" "$R/out/news/run.log" \
  && ok "no profile text and no NEWS_CONTACT under out/" || bad "leak" "$(grep -rl 'MARKER' "$R/out")"
first_plan=$(grep -n 'plan: 0' "$R/out/news/run.log" | cut -d: -f1)
first_step=$(grep -n 'step: ' "$R/out/news/run.log" | head -n 1 | cut -d: -f1)
[ -n "$first_plan" ] && [ -n "$first_step" ] && [ "$first_plan" -lt "$first_step" ] \
  && ok "log: the plan comes before the first step" || bad "plan order" "plan=$first_plan step=$first_step"

# --- inputs: 10 ---
fresh
out=$(NEWS_CONTACT= run 2>&1); rc=$?
[ $rc -eq 10 ] && [ "$(stop)" = "10 input" ] && [[ $(j "$S" 'd["missing"][0]["message"]') == "NEWS_CONTACT is empty"* ]] \
  && [ ! -s "$FAKE_CALLS" ] && ok "NEWS_CONTACT empty: exit 10, VM untouched" || bad "no contact" "rc=$rc $(cat "$S" 2>&1)"
fresh
out=$(NEWS_PROFILE="$T/no-such-profile.md" run 2>&1); rc=$?
[ $rc -eq 10 ] && [ "$(stop)" = "10 input" ] && [ "$(j "$S" 'd["missing"][0]["path"]')" = "$T/no-such-profile.md" ] \
  && ok "profile missing: exit 10, path named" || bad "no profile" "rc=$rc $(cat "$S" 2>&1)"

# --- the collector ---
fresh
out=$(FAKE_COLLECT=partial run 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(check collect)" = "warn hn 2, hf 1, arxiv FAILED" ] && [[ $(check digest) == *"(3 of 3 rated)" ]] \
  && ok "one source FAILED: warn, the run goes on" || bad "partial" "rc=$rc $(cat "$S" 2>&1)"
fresh
out=$(FAKE_COLLECT=allfail run 2>&1); rc=$?
[ $rc -eq 13 ] && [ "$(stop)" = "13 network" ] && [ "$(check collect)" = "fail hn FAILED, hf FAILED, arxiv FAILED" ] && ! hermes_ran \
  && [ ! -e "$FAKE_VM/news/CASEY-INTERESTS.md" ] && ok "every source FAILED: exit 13 network, profile never sent" || bad "allfail" "rc=$rc $(cat "$S" 2>&1)"
fresh
out=$(FAKE_COLLECT=crash run 2>&1); rc=$?
[ $rc -eq 12 ] && [ "$(stop)" = "12 failed" ] && ! hermes_ran && ok "collector crashes: exit 12" || bad "crash" "rc=$rc $(cat "$S" 2>&1)"

# --- after the profile went in, it leaves on every exit ---
fresh
out=$(FAKE_LEAVE_ONE=1 run 2>&1); rc=$?
[ $rc -eq 12 ] && [ "$(stop)" = "12 failed" ] && [[ $(check digest) == "fail "*"(3 of 4 rated). Some items are unrated" ]] \
  && [ -s "$R/out/news/digest-$DAY.md" ] && profile_gone \
  && ok "an item left unrated: exit 12, digest still pulled, profile removed" || bad "unrated" "rc=$rc $(cat "$S" 2>&1)"
fresh
out=$(FAKE_BLOCK=rating run 2>&1); rc=$?
[ $rc -eq 11 ] && [ "$(stop)" = "11 decision" ] && [[ $(j "$S" 'd["reason"]') == "rating: "*BLOCKED* ]] && profile_gone \
  && ok "scanner refusal: exit 11, profile removed" || bad "refusal" "rc=$rc $(cat "$S" 2>&1)"
fresh
out=$(FAKE_RATING_RC=1 FAKE_ROUTER_DIES=1 run 2>&1); rc=$?
[ $rc -eq 13 ] && [ "$(stop)" = "13 router" ] && profile_gone \
  && ok "session fails with the router down: exit 13, profile removed" || bad "router died" "rc=$rc $(cat "$S" 2>&1)"
fresh
out=$(FAKE_RATING_RC=1 run 2>&1); rc=$?
[ $rc -eq 12 ] && [ "$(stop)" = "12 failed" ] && profile_gone \
  && ok "session fails with the router up: exit 12, profile removed" || bad "session fails" "rc=$rc $(cat "$S" 2>&1)"

fresh
out=$(FAKE_PIN_PROFILE=1 run 2>&1); rc=$?
[ $rc -eq 12 ] && [ "$(stop)" = "12 failed" ] && [[ $(check profile) == "fail may still be in the VM"* ]] \
  && [ "$(j "$S" 'len(d["outputs"])')" = 2 ] \
  && ok "profile removal fails: exit 12, check says so" || bad "removal fails" "rc=$rc $(cat "$S" 2>&1)"

# --- VM, router, lock ---
fresh
out=$(FAKE_SSH=down run 2>&1); rc=$?
[ $rc -eq 13 ] && [ "$(stop)" = "13 vm" ] && ! hermes_ran && ok "VM down: exit 13 vm" || bad "VM down" "rc=$rc $(cat "$S" 2>&1)"
fresh
touch "$FAKE_ROUTER_DOWN"
out=$(run 2>&1); rc=$?
[ $rc -eq 13 ] && [ "$(stop)" = "13 router" ] && ! hermes_ran && ok "router down: exit 13 router" || bad "router down" "rc=$rc $(cat "$S" 2>&1)"
fresh
mkdir -p "$R/out/news"
echo '{"held": true}' > "$S"
exec 8>"$R/out/.hermes-run.lock"
flock -n 8
out=$(run 2>&1); rc=$?
exec 8>&-
[ $rc -eq 14 ] && [[ $out == *busy* ]] && [ "$(cat "$S")" = '{"held": true}' ] && [ ! -s "$FAKE_CALLS" ] \
  && ok "lock held (one lock for both jobs): exit 14, nothing run" || bad "lock held" "rc=$rc out=$out"

# --- SIGTERM during the rating: Hermes stopped, profile removed, status 143 ---
fresh
FAKE_HANG=rating PATH="$T/bin:$PATH" setsid env --default-signal=INT bash "$R/jobs/run-news-digest.sh" >"$T/term.out" 2>&1 &
RUN=$!
for i in $(seq 100); do grep -q '^hermes news-rate.md' "$FAKE_CALLS" && break; /usr/bin/sleep 0.1; done
HPG=$(cat "$FAKE_VM/scout/.hermes.pgid" 2>/dev/null)
/usr/bin/sleep 0.3
kill -TERM -- "-$RUN"
for i in $(seq 100); do ps -p "$RUN" >/dev/null || break; /usr/bin/sleep 0.1; done
ps -p "$RUN" >/dev/null && { echo "run $RUN still alive 10 s after TERM, killing it"; kill -KILL "$RUN"; }
wait "$RUN"; rc=$?
[ -n "$HPG" ] && [ $rc -eq 143 ] && [ "$(stop)" = "143 terminated" ] && ! pgrep -g "$HPG" >/dev/null && profile_gone \
  && flock -n "$R/out/.hermes-run.lock" true \
  && ok "SIGTERM in the rating: Hermes stopped, profile removed, lock free, status 143" \
  || bad "SIGTERM" "HPG=$HPG rc=$rc $(cat "$S" 2>&1 | head -5)"
[ -n "$HPG" ] && pgrep -g "$HPG" >/dev/null && kill -KILL -- "-$HPG"
pgrep -g "$RUN" >/dev/null && kill -KILL -- "-$RUN"

echo "passed=$pass failed=$fail"
rm -rf "$T"
[ $fail -eq 0 ]
