#!/bin/bash
# Runs the topic scout with no one at the keyboard: README topic scout steps 1
# to 4, then the field and URL checks, as one host command for a scheduler or a
# hand-run. It never starts or stops the VM, takes snapshots, or changes
# Hermes's config. The exit codes and status.json are described in README,
# topic scout, "Run it unattended".
#   bash jobs/run-topic-scout.sh

if [ $# -ne 0 ]; then
  echo "usage: bash jobs/run-topic-scout.sh (it takes no arguments)" >&2
  exit 2
fi
exec </dev/null
cd "$(dirname "$0")/.." || exit 12

JOB=topic-scout
OUT=$PWD/out/scout
LOG=$OUT/run.log
STATUS=$OUT/status.json
VM=hermes@localhost
# The README's commands, plus BatchMode so a missing key fails instead of prompting.
SSH=(ssh -p 22220 -o BatchMode=yes -o ConnectTimeout=10 "$VM")
SCP=(scp -P 22220 -o BatchMode=yes -o ConnectTimeout=10)
# Each Hermes session runs in its own process group in the VM, with the group's
# id in ~/scout/.hermes.pgid, because sshd does not signal a command that has no
# terminal when the client goes away, so a stopped run must stop Hermes itself.
# A command run over SSH also gets the VM's system PATH, which lacks
# ~/.local/bin, where the installer put hermes (NOT FOUND without it, 2026-11-03).
# printf fills in the toolsets and the query file.
SESSION_CMD='rm -f ~/scout/.hermes.pgid
setsid -w sh -c '\''echo $$ > ~/scout/.hermes.pgid; export PATH="$HOME/.local/bin:$PATH"; exec hermes chat --oneshot --toolsets "$0" --query-file "$1"'\'' %s %s
rc=$?; rm -f ~/scout/.hermes.pgid; exit $rc'
# Waits up to 3 seconds for a session that is still starting to record its group.
STOP_CMD='f=~/scout/.hermes.pgid
for i in 1 2 3; do [ -s "$f" ] && break; sleep 1; done
if [ -s "$f" ]; then kill -TERM -- "-$(cat "$f")" && echo "stopped Hermes process group $(cat "$f")"; rm -f "$f"; else echo "no Hermes session to stop"; fi'
ROUTER=http://10.0.2.2:8080

# One lock for every Hermes job, because they share the VM and the GPU. The
# kernel drops it when the run's last process exits, so it never goes stale.
mkdir -p "$OUT"
exec 9>"$PWD/out/.hermes-run.lock"
if ! flock -n 9; then
  echo "busy: another Hermes job holds out/.hermes-run.lock. Nothing was run or written." >&2
  exit 14
fi
rm -f "$STATUS"

OUTPUTS=()
CHECKS=()    # one "id<TAB>result<TAB>detail" entry per check
MISSING=()   # on 10, one "path<TAB>message" entry per input, path empty when there is none
REASON=""    # the first line Hermes's scanner refused, which makes the run an 11
IN_SESSION=""  # set while a Hermes session runs in the VM
SESSION_PID=""  # the local ssh running that session

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

# step NAME COMMAND...: logs the step, appends the command's output to the log,
# and returns the command's exit code.
step() {
  local name=$1 rc
  shift
  log "step: $name"
  "$@" >>"$LOG" 2>&1
  rc=$?
  log "$name exit=$rc"
  return $rc
}

write_status() {
  python3 -c '
import datetime, json, os, sys
path, job, code, stop, log, reason, n_out, n_chk = sys.argv[1:9]
rest = sys.argv[9:]
n_out, n_chk = int(n_out), int(n_chk)
def fields(items, keys):
    return [dict(zip(keys, i.split("\t", len(keys) - 1))) for i in items]
doc = {
    "job": job,
    "exit_code": int(code),
    "stop_reason": stop or None,
    "finished_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "outputs": rest[:n_out],
    "checks": fields(rest[n_out:n_out + n_chk], ("id", "result", "detail")),
    "missing": [{"path": m["path"] or None, "message": m["message"]}
                for m in fields(rest[n_out + n_chk:], ("path", "message"))],
    "reason": reason or None,
    "log": log,
}
with open(path + ".tmp", "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
' "$STATUS" "$JOB" "$1" "$2" "$LOG" "$REASON" "${#OUTPUTS[@]}" "${#CHECKS[@]}" \
    "${OUTPUTS[@]}" "${CHECKS[@]}" "${MISSING[@]}"
}

# finish CODE STOP_REASON: writes status.json and exits with CODE. A scanner
# refusal turns a finished run or a failed stage into 11, because only a person
# can clear it, and a failure after one is most likely its result.
finish() {
  local code=$1 stop=$2
  if [ -n "$REASON" ] && { [ "$code" = 0 ] || [ "$code" = 12 ]; }; then
    code=11 stop=decision
  fi
  write_status "$code" "$stop" || log "ERROR: could not write $STATUS"
  log "finished: exit $code${stop:+ ($stop)}"
  exit "$code"
}

# router_up: README setup step 5's two checks, run in the VM. Returns 0 when the
# router answers ok and lists qwen, 1 when it does not, 2 when SSH itself failed.
router_up() {
  local out rc
  log "step: router probe"
  out=$("${SSH[@]}" "curl -s --max-time 10 $ROUTER/health; echo; curl -s --max-time 10 $ROUTER/v1/models" 2>&1)
  rc=$?
  printf '%s\n' "$out" >>"$LOG"
  log "router probe exit=$rc"
  [ $rc -eq 255 ] && return 2
  grep -q '"status": *"ok"' <<<"$out" && grep -q '"id": *"qwen"' <<<"$out" && return 0
  return 1
}

# session NAME TOOLSETS QUERY_FILE: one Hermes session. Sets SESSION_OUTPUT to
# what it printed, records the first scanner refusal, and on failure exits 10
# (hermes not found), 13 (VM or router down) or 12.
session() {
  local name=$1 start rc line
  start=$(stat -c %s "$LOG")
  log "step: $name"
  # In the background, so a SIGTERM runs on_term at once, not after the session.
  IN_SESSION=1
  "${SSH[@]}" "$(printf "$SESSION_CMD" "$2" "$3")" >>"$LOG" 2>&1 &
  SESSION_PID=$!
  wait $SESSION_PID
  rc=$?
  IN_SESSION=""
  log "$name exit=$rc"
  SESSION_OUTPUT=$(tail -c +$((start + 1)) "$LOG")
  line=$(grep -m 1 -e 'BLOCKED' -e 'could not be resolved' <<<"$SESSION_OUTPUT" | sed 's/^[[:space:]]*//' | cut -c 1-300)
  if [ -n "$line" ] && [ -z "$REASON" ]; then
    REASON="$name: $line"
    log "scanner refusal in $name: $line"
  fi
  [ $rc -eq 0 ] && return 0
  if [ $rc -eq 127 ]; then
    MISSING+=("	hermes not found on PATH over non-interactive SSH (exit 127). Compare: ssh -p 22220 $VM 'bash -ic \"command -v hermes\"'")
    finish 10 hermes_not_on_path
  fi
  router_up
  case $? in 1) finish 13 router ;; 2) finish 13 vm ;; esac
  finish 12 failed
}

# on_signal CODE STOP_REASON: the hub stops a run with SIGTERM to its process
# group, and Ctrl+C sends SIGINT to it. Stop the Hermes session in the VM, then
# the local ssh waiting on it, which as a background job ignores SIGINT and
# would otherwise hold the lock until the session ends. Then record the stop.
on_signal() {
  local rc
  trap '' TERM INT
  log "signal received: stopping (exit $1, $2)"
  if [ -n "$IN_SESSION" ]; then
    "${SSH[@]}" "$STOP_CMD" >>"$LOG" 2>&1
    rc=$?
    log "stop Hermes exit=$rc"
    [ $rc -eq 0 ] || log "ERROR: could not stop Hermes in the VM. Check it with: ssh -p 22220 $VM 'pgrep -u hermes -a'"
    kill "$SESSION_PID" >>"$LOG" 2>&1
    wait "$SESSION_PID"
  fi
  finish "$1" "$2"
}
trap 'on_signal 143 terminated' TERM
trap 'on_signal 130 interrupted' INT

log "run $JOB started, pid $$"
log "plan: 0 check the local job files, SSH to the VM, and the router from the VM"
log "plan: 1 make ~/jobs and ~/scout in the VM"
log "plan: 2 copy topic-scout.md, topic-scout-sweep.md, topic-scout-seen.txt, add-idea.sh to ~/jobs"
log "plan: 3 read the VM's date and list its skills"
log "plan: 4 research session (toolsets web,terminal)"
log "plan: 5 sweep session (toolsets terminal)"
log "plan: 6 diff the VM's skills against step 3"
log "plan: 7 pull ~/scout/topic-scout-DATE.md to out/scout/topic-scout-DATE-HHMMSSZ.md"
log "plan: 8 field check, then URL check (one request per competitor URL)"

for f in jobs/topic-scout.md jobs/topic-scout-sweep.md jobs/topic-scout-seen.txt jobs/add-idea.sh jobs/check-scout.sh; do
  [ -s "$f" ] || MISSING+=("$PWD/$f	missing or empty")
done
[ ${#MISSING[@]} -eq 0 ] || finish 10 input

log "step: SSH probe"
OUTPUT=$("${SSH[@]}" true 2>&1)
RC=$?
[ -n "$OUTPUT" ] && printf '%s\n' "$OUTPUT" >>"$LOG"
log "SSH probe exit=$RC"
if [ $RC -ne 0 ]; then
  if grep -q 'Permission denied' <<<"$OUTPUT"; then
    MISSING+=("	no SSH key for $VM. Install one with: ssh-copy-id -p 22220 $VM")
    finish 10 input
  fi
  finish 13 vm
fi
router_up
case $? in 1) finish 13 router ;; 2) finish 13 vm ;; esac

step "make VM dirs" "${SSH[@]}" 'mkdir -p ~/jobs ~/scout' || finish 12 failed
step "copy job files" "${SCP[@]}" jobs/topic-scout.md jobs/topic-scout-sweep.md \
  jobs/topic-scout-seen.txt jobs/add-idea.sh "$VM:jobs/" || finish 12 failed

# Both sessions name the file by the VM's own date, so read it from the VM.
DATE=$("${SSH[@]}" 'date +%F' 2>>"$LOG")
log "VM date: '$DATE'"
[[ $DATE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || finish 12 failed

step "list skills" "${SSH[@]}" 'find ~/.hermes/skills -name SKILL.md | sort > ~/scout/skills-before.txt' || finish 12 failed
session research "web,terminal" '~/jobs/topic-scout.md'
session sweep "terminal" '~/jobs/topic-scout-sweep.md'
# The sweep replies "FILE missing: PATH" when research wrote nowhere, or when
# the VM's date changed between the sessions (a run across midnight).
LINE=$(grep -m 1 'FILE missing: [~/]' <<<"$SESSION_OUTPUT")
if [ -n "$LINE" ]; then
  CHECKS+=("sweep	fail	$LINE")
  finish 12 failed
fi

# A new skill is instructions Hermes reuses without asking, so a person reads it.
log "step: skills diff"
OUTPUT=$("${SSH[@]}" 'find ~/.hermes/skills -name SKILL.md | sort | diff ~/scout/skills-before.txt -' 2>&1)
RC=$?
[ -n "$OUTPUT" ] && printf '%s\n' "$OUTPUT" >>"$LOG"
log "skills diff exit=$RC"
case $RC in
  0) CHECKS+=("skills	pass	no new or removed skills") ;;
  1) CHECKS+=("skills	warn	$(grep -c '^>' <<<"$OUTPUT") new, $(grep -c '^<' <<<"$OUTPUT") removed. Read each new SKILL.md before trusting it: $(sed -n 's/^> //p' <<<"$OUTPUT" | paste -sd ' ')") ;;
  *) finish 12 failed ;;
esac

FILE=$OUT/topic-scout-$DATE-$(date -u +%H%M%SZ).md
step pull "${SCP[@]}" "$VM:scout/topic-scout-$DATE.md" "$FILE" || finish 12 failed
OUTPUTS+=("$FILE")

log "step: field check"
RESULT=$(bash jobs/check-scout.sh fields "$FILE" 2>&1)
RC=$?
printf '%s\n' "$RESULT" >>"$LOG"
DETAIL=$(printf '%s\n' "$RESULT" | tail -n 2 | head -n 1)
if [ $RC -eq 0 ]; then CHECKS+=("fields	pass	$DETAIL"); else CHECKS+=("fields	fail	$DETAIL"); fi
log "field check exit=$RC"

# DEAD is a made-up or gone page. UNVERIFIED is a site that blocks scripts,
# which proves nothing either way, so a person opens it in a browser.
log "step: URL check"
RESULT=$(bash jobs/check-scout.sh urls "$FILE" 2>&1)
URC=$?
printf '%s\n' "$RESULT" >>"$LOG"
DEAD=$(grep -c '^DEAD ' <<<"$RESULT")
UNVERIFIED=$(grep -c '^UNVERIFIED ' <<<"$RESULT")
DETAIL="$(grep -c '^OK ' <<<"$RESULT") OK, $UNVERIFIED UNVERIFIED, $DEAD DEAD"
if [ $URC -ne 0 ] || [ "$DEAD" -gt 0 ]; then CHECKS+=("urls	fail	$DETAIL")
elif [ "$UNVERIFIED" -gt 0 ]; then CHECKS+=("urls	warn	$DETAIL")
else CHECKS+=("urls	pass	$DETAIL"); fi
log "URL check exit=$URC"

[ $RC -eq 0 ] && [ $URC -eq 0 ] && [ "$DEAD" -eq 0 ] || finish 12 failed
finish 0 ""
