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

# The shared runner code: VM commands, lock, status, session and signal handling.
. jobs/runner-lib.sh || { echo "jobs/runner-lib.sh is missing. Nothing was run." >&2; exit 10; }

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

probe_vm

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
