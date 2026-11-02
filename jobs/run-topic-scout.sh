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
CHECKS=()   # one "id<TAB>result<TAB>detail" entry per check

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
path, job, code, stop, log, n = sys.argv[1:7]
rest = sys.argv[7:]
doc = {
    "job": job,
    "exit_code": int(code),
    "stop_reason": stop or None,
    "finished_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "outputs": rest[:int(n)],
    "checks": [dict(zip(("id", "result", "detail"), c.split("\t", 2))) for c in rest[int(n):]],
    "missing": [],
    "reason": None,
    "log": log,
}
with open(path + ".tmp", "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
' "$STATUS" "$JOB" "$1" "$2" "$LOG" "${#OUTPUTS[@]}" "${OUTPUTS[@]}" "${CHECKS[@]}"
}

# finish CODE STOP_REASON: writes status.json and exits with CODE.
finish() {
  write_status "$1" "$2" || log "ERROR: could not write $STATUS"
  log "finished: exit $1${2:+ ($2)}"
  exit "$1"
}

log "run $JOB started, pid $$"
log "plan: 1 make ~/jobs and ~/scout in the VM"
log "plan: 2 copy topic-scout.md, topic-scout-sweep.md, topic-scout-seen.txt, add-idea.sh to ~/jobs"
log "plan: 3 read the VM's date and list its skills"
log "plan: 4 research session (toolsets web,terminal)"
log "plan: 5 sweep session (toolsets terminal)"
log "plan: 6 diff the VM's skills against step 3"
log "plan: 7 pull ~/scout/topic-scout-DATE.md to out/scout/topic-scout-DATE-HHMMSSZ.md"
log "plan: 8 field check, then URL check (one request per competitor URL)"

step "make VM dirs" "${SSH[@]}" 'mkdir -p ~/jobs ~/scout' || finish 12 failed
step "copy job files" "${SCP[@]}" jobs/topic-scout.md jobs/topic-scout-sweep.md \
  jobs/topic-scout-seen.txt jobs/add-idea.sh "$VM:jobs/" || finish 12 failed

# Both sessions name the file by the VM's own date, so read it from the VM.
DATE=$("${SSH[@]}" 'date +%F' 2>>"$LOG")
log "VM date: '$DATE'"
[[ $DATE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || finish 12 failed

step "list skills" "${SSH[@]}" 'find ~/.hermes/skills -name SKILL.md | sort > ~/scout/skills-before.txt' || finish 12 failed
step research "${SSH[@]}" 'hermes chat --oneshot --toolsets "web,terminal" --query-file ~/jobs/topic-scout.md' || finish 12 failed
step sweep "${SSH[@]}" 'hermes chat --oneshot --toolsets "terminal" --query-file ~/jobs/topic-scout-sweep.md' || finish 12 failed

# diff exits 1 when the skills changed, and 2 only when it could not compare.
step "skills diff" "${SSH[@]}" 'find ~/.hermes/skills -name SKILL.md | sort | diff ~/scout/skills-before.txt -'
[ $? -le 1 ] || finish 12 failed

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

log "step: URL check"
RESULT=$(bash jobs/check-scout.sh urls "$FILE" 2>&1)
URC=$?
printf '%s\n' "$RESULT" >>"$LOG"
DETAIL="$(grep -c '^OK ' <<<"$RESULT") OK, $(grep -c '^UNVERIFIED ' <<<"$RESULT") UNVERIFIED, $(grep -c '^DEAD ' <<<"$RESULT") DEAD"
if [ $URC -eq 0 ]; then CHECKS+=("urls	pass	$DETAIL"); else CHECKS+=("urls	fail	$DETAIL"); fi
log "URL check exit=$URC"

[ $RC -eq 0 ] && [ $URC -eq 0 ] || finish 12 failed
finish 0 ""
