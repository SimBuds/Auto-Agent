#!/bin/bash
# Topic scout helper, run inside the VM with bash.
#   bash ~/jobs/add-idea.sh --check the-slug    prints OK, or TAKEN and exits 2
#   bash ~/jobs/add-idea.sh <<'IDEA' ... IDEA   checks the idea, then appends it
# The idea's heading is `## Title` with no number: the script numbers it, so the
# model never edits headings (run 15 lost about 8 tool calls to `## N.` repairs).
#
# TAKEN (exit 2): the slug is on the seen list, already in today's file, or
# repeats a seen topic. Topic words are the slug's words minus generic ones,
# singularized, because run 16 got carriers, beds and fountains past a check
# that compared carrier with carriers. A slug with 2 or more topic words
# repeats a seen slug sharing 2 of them. A slug with 1 repeats any seen slug
# sharing it (run 16's best-cat-trees-guide-canada was just "trees"). The
# README field check uses the same word rules, so keep the two identical.
#
# REJECTED (exit 3): rules the prompt alone did not hold in run 16. A "Best ..."
# title compares products, so it is a roundup, and a run has at most 3. A
# Timely: yes idea names, in "Why now", a month from this month to 3 months ahead.

file="$HOME/scout/topic-scout-$(date +%F).md"
seen="$HOME/jobs/topic-scout-seen.txt"

check() {
  awk -v slug="$1" '
    function sing(w) {
      if (w ~ /ies$/) return substr(w, 1, length(w) - 3) "y"
      if (w ~ /(ss|x|ch|sh)es$/) return substr(w, 1, length(w) - 2)
      if (w ~ /[^s]s$/) return substr(w, 1, length(w) - 1)
      return w
    }
    function sigwords(s,   w, k, i, out) {
      k = split(s, w, "-"); out = ""
      for (i = 1; i <= k; i++) if (w[i] !~ /^(best|how|to|choose|cat|cats|canada|for|the|in|your|and|a|of|guide|2026|keep|safe|with|vs|on|at|from|during|is|can|do|my|you)$/) out = out " " sing(w[i])
      return out
    }
    function overlap(a, b,   wa, wb, i, j, na, nb, c) {
      na = split(a, wa, " "); nb = split(b, wb, " "); c = 0
      for (i = 1; i <= na; i++) for (j = 1; j <= nb; j++) if (wa[i] == wb[j]) { c++; break }
      return c
    }
    FNR == 1 && NR == 1 { mine = sigwords(slug); need = (split(mine, tmp, " ") >= 2) ? 2 : 1 }
    FILENAME != ARGV[1] { if ($0 ~ /^- Slug: / && $3 == "`" slug "`") print "  already in today'\''s file"; next }
    /^#/ || !NF { next }
    $1 == slug { print "  " $1 " (same slug)"; next }
    overlap(mine, sigwords($1)) >= need { print "  " $1 }
  ' "$seen" "$file"
}

reject() {
  echo "REJECTED: $1"
  echo "Nothing was added."
  exit 3
}

if [ ! -f "$seen" ]; then echo "ERROR: $seen is missing."; exit 1; fi
if [ ! -f "$file" ]; then echo "ERROR: $file is missing. Run step 1 first."; exit 1; fi

if [ "${1:-}" = "--check" ]; then
  slug=${2:-}
  if [ -z "$slug" ]; then echo "ERROR: give a slug after --check."; exit 1; fi
else
  idea=$(cat)
  title=$(printf '%s\n' "$idea" | sed -n 's/^## //p' | head -n 1)
  slug=$(printf '%s\n' "$idea" | sed -n 's/^- Slug: `\(.*\)`$/\1/p' | head -n 1)
  type=$(printf '%s\n' "$idea" | sed -n 's/^- Type: //p' | head -n 1)
  timely=$(printf '%s\n' "$idea" | sed -n 's/^- Timely: //p' | head -n 1)
  whynow=$(printf '%s\n' "$idea" | sed -n 's/^- Why now: //p' | head -n 1)
  if [ -z "$title" ]; then echo "ERROR: no '## Title' line. Nothing was added."; exit 1; fi
  if [ -z "$slug" ]; then echo "ERROR: no '- Slug: \`the-slug\`' line. Nothing was added."; exit 1; fi
fi

taken=$(check "$slug")
if [ -n "$taken" ]; then
  echo "TAKEN: $slug repeats a topic already covered:"
  echo "$taken"
  echo "Nothing was added. Pick a different topic, not another slug for this one."
  exit 2
fi

if [ "${1:-}" = "--check" ]; then echo "OK: $slug is new ground."; exit 0; fi

if [[ $title == Best\ * && ${title,,} != *" types"* && $type != roundup ]]; then
  reject "\"$title\" compares products, so its type is roundup, not $type. Change the type to roundup, or give it a how-to-choose title that names no product."
fi
if [ "$type" = roundup ] && [ "$(grep -c '^- Type: roundup' "$file")" -ge 3 ]; then
  reject "FILE already has 3 roundups, the most a run may have (rule 9). Pick an idea that is a guide or how-to."
fi
if [ "$timely" = yes ]; then
  months=""
  for i in 0 1 2 3; do
    m=$(LC_ALL=C date -d "$(date +%Y-%m-15) +$i month" +%B)
    months="$months|$m|${m:0:3}"
  done
  if ! printf '%s\n' "$whynow" | grep -qiwE "(${months#|})"; then
    reject "Timely: yes, but \"Why now\" names no month from ${months#|} (rule 11). Name the event's month, or mark it Timely: no."
  fi
fi

n=$(awk '/^## [0-9]+\. / { v = $2 + 0; if (v > m) m = v } END { print m + 1 }' "$file")
{ echo; printf '%s\n' "$idea" | sed '/./,$!d' | sed "0,/^## /s//## $n. /"; } >> "$file"
echo "ADDED: idea $n, $slug. FILE now has $(grep -c '^## [0-9]' "$file") ideas, $(grep -c '^- Timely: yes' "$file") timely, $(grep -c '^- Type: roundup' "$file") roundups."
