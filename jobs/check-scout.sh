#!/bin/bash
# Checks a pulled topic scout file on the host. Both checks moved verbatim from
# the README's old topic scout step 4 (Phase 15, 2026-11-02) so a runner can call them.
#   bash jobs/check-scout.sh fields FILE   a FAIL line per problem and exit 1, or PASS and exit 0
#   bash jobs/check-scout.sh urls FILE     an OK, UNVERIFIED or DEAD line per competitor URL,
#                                          one request every two seconds
# The field check's word rules are add-idea.sh's, so keep the two identical.

if [ $# -ne 2 ] || { [ "$1" != fields ] && [ "$1" != urls ]; }; then
  echo "usage: bash jobs/check-scout.sh fields|urls FILE" >&2
  exit 2
fi
F=$2

if [ "$1" = fields ]; then
SEEN="$(dirname "$0")/topic-scout-seen.txt"
awk -v year="$(date +%Y)" '
  function sing(w) {
    if (w ~ /ies$/) return substr(w, 1, length(w) - 3) "y"
    if (w ~ /(ss|x|ch|sh)es$/) return substr(w, 1, length(w) - 2)
    if (w ~ /[^s]s$/) return substr(w, 1, length(w) - 1)
    return w
  }
  function sigwords(s,   w, k, i, out) {
    k = split(s, w, "-"); out = ""
    for (i = 1; i <= k; i++) if (w[i] !~ ("^(best|how|to|choose|cat|cats|canada|canadian|for|the|in|your|and|a|of|guide|" year "|keep|safe|with|vs|on|at|from|during|is|can|do|my|you)$")) out = out " " sing(w[i])
    return out
  }
  function overlap(a, b,   wa, wb, i, j, na, nb, c) {
    na = split(a, wa, " "); nb = split(b, wb, " "); c = 0
    for (i = 1; i <= na; i++) for (j = 1; j <= nb; j++) if (wa[i] == wb[j]) { c++; break }
    return c
  }
  function done_idea(   s, mine, need, tmp) {
    if (!n) return
    if (slug !~ /^[a-z0-9][a-z0-9-]*$/)            bad("slug " slug " is not lowercase-hyphen")
    if (slug in seen)                              bad("slug " slug " is on the seen list")
    else { mine = sigwords(slug); need = (split(mine, tmp, " ") >= 2) ? 2 : 1
           for (s in seen) if (overlap(mine, seenw[s]) >= need) { printf "WARN idea %s: slug %s looks like seen slug %s. Same topic?\n", hn, slug, s; break } }
    if (timely !~ /^(yes|no)$/)                    bad("Timely line missing or not yes/no")
    if (timely == "yes")                           timelies++
    if (type !~ /^(review|roundup|guide|how-to)$/) bad("type \"" type "\" is not review, roundup, guide or how-to")
    if (ymyl !~ /^(yes|no)$/)                      bad("YMYL line missing or not yes/no")
    if (kw < 3 || kw > 6)                          bad(kw " suggested keywords, expected 3 to 6")
    if (comp < 3 || comp > 5)                      bad(comp " competitors, expected 3 to 5")
    if (ymyl == "no" && tolower(words) ~ /health|treat|diet|nutrition|toxic|poison|plant|veterinar|dental|teeth|overweight|obes|weight loss|medic|sick|illness|symptom|supplement/)
      printf "WARN idea %s: YMYL is no, but the title, slug or keywords mention a YMYL word. Check it.\n", hn
    if (type != "roundup" && title ~ /^## [0-9]+\. Best / && tolower(title) !~ / types/)
      bad("titled \"Best ...\" but typed " type ". A \"Best ...\" title is a roundup")
    if (type != "roundup" && slug ~ /^best-/ && slug !~ /-types/)
      bad("slug " slug " starts with best- but typed " type ". A best- slug is a roundup")
  }
  function bad(msg) { printf "FAIL idea %s: %s\n", hn, msg; fails++ }
  FNR == NR                  { if ($0 !~ /^#/ && NF) { seen[$1] = 1; seenw[$1] = sigwords($1) } next }
  /amazon\./                 { printf "FAIL line %d: amazon URL: %s\n", NR, $0; fails++ }
  /^- Ideas: /               { declared = $3 }
  /^## [0-9]+\. /            { done_idea(); n++; hn = $2; sub(/\.$/, "", hn); slug = type = ymyl = timely = ""; kw = comp = 0; list = ""; words = title = $0; next }
  /^- Slug: /                { slug = $3; gsub(/`/, "", slug); words = words " " slug; list = ""; next }
  /^- Type: /                { type = $3; if (type == "roundup") roundups++; list = ""; next }
  /^- YMYL: /                { ymyl = $3; list = ""; next }
  /^- Timely: /              { timely = $3; list = ""; next }
  /^- Sources:/              { list = "src"; next }
  /^- Suggested keywords:/   { list = "kw"; next }
  /^- Competitors:/          { list = "comp"; next }
  /^- /                      { list = ""; next }
  /^  - / && list == "kw"    { kw++; words = words " " $0 }
  /^  - / && list == "comp"  { comp++; if ($2 !~ /^https?:\/\//) bad("competitor line is not a URL: " $0)
                               if ($2 ~ /^https?:\/\/[^\/]+\.store(\/|$)|\/(shop|b|best|product|products|collections|pet-supplies|category)\//) bad("competitor is a shop page: " $2)
                               if ($2 ~ /^https?:/ && ($2 in used)) bad("competitor already used by idea " used[$2] ": " $2); else used[$2] = hn }
  END {
    done_idea()
    if (n == 0)             { print "FAIL: no ideas found"; fails++ }
    if (n > 10)             { printf "FAIL: %d ideas, expected 10 or fewer\n", n; fails++ }
    if (roundups > 3)       { printf "FAIL: %d roundup ideas, expected 3 or fewer\n", roundups; fails++ }
    need = int((n * 6 + 9) / 10)
    if (timelies < need)    { printf "FAIL: %d timely ideas, expected at least %d (60%% of %d)\n", timelies, need, n; fails++ }
    if (declared != n)      { printf "FAIL: header says %s ideas, file has %d\n", declared, n; fails++ }
    if (fails) { printf "%d check(s) failed\n", fails; exit 1 }
    printf "PASS: %d ideas, all fields in shape\n", n
  }' "$SEEN" "$F"
rc=$?
echo "check exit=$rc"
exit $rc
fi

awk '/^- Competitors:/{c=1;next} /^- /{c=0} c && /^  - https?:/{print $2}' "$F" | while read -r url; do
  code=$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 15 "$url")
  case "$code" in
    2??|3??)             label=OK ;;
    401|402|403|429|5??) label=UNVERIFIED ;;
    *)                   label=DEAD ;;
  esac
  echo "$label $code $url"
  sleep 2
done
