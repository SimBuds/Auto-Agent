#!/bin/bash
# Runs the news digest with no one at the keyboard: collect, copy in, rate,
# pull the digest, as one host command for a scheduler or a hand-run. It never
# starts or stops the VM, takes snapshots, or changes Hermes's config. The exit
# codes and status.json are described in README, How to use, "Exit codes".
#   NEWS_CONTACT=you@example.com bash jobs/run-news-digest.sh
# NEWS_CONTACT is the User-Agent's contact address, read at run time and never
# stored. NEWS_PROFILE overrides the profile's path.

if [ $# -ne 0 ]; then
  echo "usage: NEWS_CONTACT=ADDRESS bash jobs/run-news-digest.sh (it takes no arguments)" >&2
  exit 2
fi
exec </dev/null
cd "$(dirname "$0")/.." || exit 12

JOB=news-digest
OUT=$PWD/out/news
LOG=$OUT/run.log
STATUS=$OUT/status.json
PROFILE=${NEWS_PROFILE:-$HOME/Apps/Portfolio/CASEY-INTERESTS.md}

# The shared runner code: VM commands, lock, status, session and signal handling.
. jobs/runner-lib.sh || { echo "jobs/runner-lib.sh is missing. Nothing was run." >&2; exit 10; }

# The profile is personal: it goes into the VM for the rating only, and leaves
# on every exit after it went in, signals included, before the status is written.
PROFILE_IN_VM=""
remove_profile() {
  [ -n "$PROFILE_IN_VM" ] || return 0
  PROFILE_IN_VM=""
  if step "remove profile" "${SSH[@]}" 'rm -f ~/news/CASEY-INTERESTS.md && test ! -e ~/news/CASEY-INTERESTS.md'; then
    CHECKS+=("profile	pass	removed from the VM")
    return 0
  fi
  CHECKS+=("profile	fail	may still be in the VM. Remove it: ssh -p $PORT $VM 'rm ~/news/CASEY-INTERESTS.md'")
  return 1
}
before_finish() { remove_profile; }

log "run $JOB started, pid $$"
log "plan: 0 check NEWS_CONTACT, the profile, the job files, SSH to the VM, and the router from the VM"
log "plan: 1 collect the candidates on the host (news-collect.py)"
log "plan: 2 copy the candidates, the profile without its Tuning notes, news-rate.md and add-rating.sh into the VM"
log "plan: 3 rate the hf: items (add-rating.sh --hf)"
log "plan: 4 rating session (toolsets terminal)"
log "plan: 5 add-rating.sh --left, then --digest"
log "plan: 6 pull the digest and the ratings to out/news/"
log "plan: 7 remove the profile from the VM (on every exit once it went in)"

[ -n "$NEWS_CONTACT" ] || MISSING+=("	NEWS_CONTACT is empty. Set it to a contact address for the User-Agent")
[ -s "$PROFILE" ] || MISSING+=("$PROFILE	missing or empty")
for f in jobs/news-collect.py jobs/news-rate.md jobs/add-rating.sh; do
  [ -s "$f" ] || MISSING+=("$PWD/$f	missing or empty")
done
[ ${#MISSING[@]} -eq 0 ] || finish 10 input

probe_vm

# The collector prints "PATH: hn N, hf N, arxiv N", with FAILED for a source
# it could not read. It names the file by its UTC date.
log "step: collect"
RESULT=$(NEWS_CONTACT="$NEWS_CONTACT" python3 jobs/news-collect.py 2>>"$LOG")
RC=$?
printf '%s\n' "$RESULT" >>"$LOG"
log "collect exit=$RC"
CAND=${RESULT%%: *}
SUMMARY=${RESULT#*: }
case $RC in
  0) CHECKS+=("collect	pass	$SUMMARY") ;;
  3) if [[ $SUMMARY =~ [0-9] ]]; then
       CHECKS+=("collect	warn	$SUMMARY")
     else
       # Every source failed: no internet, not one bad feed.
       CHECKS+=("collect	fail	$SUMMARY")
       finish 13 network
     fi ;;
  *) CHECKS+=("collect	fail	exit $RC. Read run.log"); finish 12 failed ;;
esac
[[ $CAND =~ /candidates-([0-9]{4}-[0-9]{2}-[0-9]{2})\.md$ ]] && [ -s "$CAND" ] || { log "no candidates file in: '$RESULT'"; finish 12 failed; }
DAY=${BASH_REMATCH[1]}

# ~/scout holds the session's process group id (runner-lib.sh).
step "make VM dirs" "${SSH[@]}" 'mkdir -p ~/news ~/jobs ~/scout' || finish 12 failed
step "copy candidates" "${SCP[@]}" "$CAND" "$VM:news/" || finish 12 failed
# Set before the copy, so a copy that fails halfway is removed too.
PROFILE_IN_VM=1
log "step: copy profile"
awk '/^## Tuning notes/ { exit } 1' "$PROFILE" | "${SSH[@]}" 'cat > ~/news/CASEY-INTERESTS.md' >>"$LOG" 2>&1
RC="${PIPESTATUS[0]} ${PIPESTATUS[1]}"
log "copy profile exit=$RC (awk, ssh)"
[ "$RC" = "0 0" ] || finish 12 failed
COUNT=$("${SSH[@]}" 'grep -c "Tuning notes" ~/news/CASEY-INTERESTS.md' 2>>"$LOG")
log "Tuning notes in the VM copy: '$COUNT'"
[ "$COUNT" = 0 ] || finish 12 failed
step "copy job files" "${SCP[@]}" jobs/news-rate.md jobs/add-rating.sh "$VM:jobs/" || finish 12 failed

step "rate hf items" "${SSH[@]}" 'bash ~/jobs/add-rating.sh --hf' || finish 12 failed
session rating "terminal" '~/jobs/news-rate.md'
step "left" "${SSH[@]}" 'bash ~/jobs/add-rating.sh --left' || finish 12 failed

log "step: digest"
RESULT=$("${SSH[@]}" 'bash ~/jobs/add-rating.sh --digest' 2>&1)
DRC=$?
printf '%s\n' "$RESULT" >>"$LOG"
log "digest exit=$DRC"
DETAIL=$(grep -m 1 '^WROTE: ' <<<"$RESULT")
case $DRC in
  0) CHECKS+=("digest	pass	$DETAIL") ;;
  3) CHECKS+=("digest	fail	$DETAIL. Some items are unrated") ;;
  *) CHECKS+=("digest	fail	exit $DRC. Read run.log"); finish 12 failed ;;
esac

step pull "${SCP[@]}" "$VM:news/digest-$DAY.md" "$VM:news/ratings-$DAY.txt" "$OUT/" || finish 12 failed
OUTPUTS+=("$OUT/digest-$DAY.md" "$OUT/ratings-$DAY.txt")

[ $DRC -eq 0 ] || finish 12 failed
finish 0 ""
