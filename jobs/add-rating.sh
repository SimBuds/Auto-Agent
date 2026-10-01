#!/bin/bash
# News digest helper, run inside the VM with bash. It reads the newest
# ~/news/candidates-DATE.md.
#   bash ~/jobs/add-rating.sh < ~/news/batch.txt   checks each line, appends the good ones
#   bash ~/jobs/add-rating.sh --left               how many are rated, the next unrated ids
#   bash ~/jobs/add-rating.sh --digest             renders ~/news/digest-DATE.md
#   bash ~/jobs/add-rating.sh --hf                 rates every unrated hf: item itself
#
# A rating line is `ID | SCORE | MATCH | REASON`. MATCH names the part of
# CASEY-INTERESTS.md that matched, and SCORE must fit it, as that file's
# scoring section says: machine 5, tier1 5 (or 4 when only in passing), tier2
# 4, tier3 3, none 2, not-interested 1. Each line is checked on its own: good
# lines are added, bad ones print REJECTED with the reason (exit 3), because
# the topic scout showed the model bends any rule a script does not hold.
#
# The MATCH itself is checked too (round 1, after run 1 filed WordPress news
# under tier3 and agent news under machine): a machine or tier rating quotes,
# in double quotes, a term from that MATCH's own section of the profile, read
# at run time. And tier1 is 5 unless the reason says "in passing" (run 1 gave
# all 21 Tier 1 items a 4). An arXiv paper takes at most 4 (round 3, after
# research papers took the top slots through broad terms), so for papers tier1
# is 4 with no "in passing" needed. A paper is never machine either (Phase 11:
# run 16 put a MoE scaling-laws paper at machine 5 by quoting "MoE layers",
# and research changes nothing on this workstation the way a release does).
#
# Hugging Face items are rated by --hf from their Kind and Params lines, not
# by the model (Phase 10, after runs 10 to 15 split the same models between
# 5, 4 and 2). An LLM up to HF_FIT_B billion total parameters fits this
# machine (a 10 GB GPU with MoE offload) and is tier1 5. A larger LLM, an LLM
# of unknown size, and any other kind of model are tier2 4. So is one under
# HF_MIN_B: small image-text models are mostly OCR tools (TeleOCR, 1.4B, took
# tier1 5 in runs 16 and 17), which the profile puts in Tier 2.
HF_FIT_B=35
HF_MIN_B=3

dir="$HOME/news"
profile="$dir/CASEY-INTERESTS.md"
cand=$(ls "$dir"/candidates-*.md 2>/dev/null | sort | tail -n 1)
if [ -z "$cand" ]; then echo "ERROR: no $dir/candidates-*.md. Copy the candidates in first."; exit 1; fi
date=${cand##*/candidates-}; date=${date%.md}
ratings="$dir/ratings-$date.txt"
digest="$dir/digest-$date.md"
touch "$ratings"

# id, title, url, size, kind and params of every candidate, one tab-separated line each, in file order.
table=$(awk '
  /^### / { if (id != "") print id "\t" t "\t" u "\t" z "\t" k "\t" p; id = substr($0, 5); t = u = z = k = p = "" }
  /^- Title: / { t = substr($0, 10) }
  /^- URL: / { u = substr($0, 8) }
  /^- Size: / { z = substr($0, 9) }
  /^- Kind: / { k = substr($0, 9) }
  /^- Params: / { p = substr($0, 11) }
  END { if (id != "") print id "\t" t "\t" u "\t" z "\t" k "\t" p }
' "$cand")
total=$(printf '%s\n' "$table" | grep -c .)

rated_ids() { cut -f1 "$ratings"; }

# The text of one profile section on one line, without markdown's backticks and
# stars, so a term the file wraps across two lines ("Core Web" / "Vitals") still matches.
section() { awk -v h="$1" '/^## / { on = (index($0, h) == 1); next } on' "$profile" | tr -d '`*' | tr '\n' ' ' | tr -s ' '; }
# A section's bold labels ("Local AI", "AI automation"), one per line. Quoting a
# label names a category, not a topic, and runs 8 and 9 split on exactly that.
labels() { awk -v h="$1" '/^## / { on = (index($0, h) == 1); next } on' "$profile" | grep -o '\*\*[^*]*\*\*' | tr -d '*' | sed 's/[.:]*$//'; }

if [ "${1:-}" = "--left" ]; then
  done=$(rated_ids | sort -u | grep -c .)
  if [ "$done" -ge "$total" ]; then echo "All $total rated."; exit 0; fi
  next=$(printf '%s\n' "$table" | cut -f1 | grep -vxFf <(rated_ids; echo) | head -n 10 | tr '\n' ' ')
  echo "$done of $total rated. Next unrated: $next"
  exit 0
fi

if [ "${1:-}" = "--digest" ]; then
  done=$(rated_ids | sort -u | grep -c .)
  {
    echo "# News digest $date"
    echo
    echo "Rated $done of $total. Interest is rated against CASEY-INTERESTS.md. Size is the source's own numbers."
    for s in 5 4 3 2 1; do
      rows=$(awk -F'\t' -v s="$s" 'NR == FNR { order[$1] = FNR; next } $2 == s { print order[$1] "\t" $0 }' \
        <(printf '%s\n' "$table") "$ratings" | sort -n -k1,1)
      [ -z "$rows" ] && continue
      echo; echo "## Interest $s"; echo
      printf '%s\n' "$rows" | while IFS=$'\t' read -r _ id score match title url reason; do
        size=$(printf '%s\n' "$table" | awk -F'\t' -v id="$id" '$1 == id { print $4 }')
        echo "- [$title]($url) ($id)"
        echo "  - $match: $reason"
        echo "  - Size: ${size:-none}"
      done
    done
    unrated=$(awk -F'\t' 'NR == FNR { r[$1] = 1; next } !($1 in r)' "$ratings" <(printf '%s\n' "$table"))
    if [ "$done" -lt "$total" ]; then
      echo; echo "## Not rated"; echo
      printf '%s\n' "$unrated" | while IFS=$'\t' read -r id title url _; do echo "- [$title]($url) ($id)"; done
    fi
  } > "$digest"
  echo "WROTE: $digest ($done of $total rated)"
  [ "$done" -lt "$total" ] && exit 3
  exit 0
fi

if [ "${1:-}" = "--hf" ]; then
  added=0
  # cut, not read: read with a tab IFS merges the empty Kind of a model
  # with no pipeline tag into the next field.
  while IFS= read -r row; do
    id=$(printf '%s' "$row" | cut -f1)
    [[ $id == hf:* ]] || continue
    title=$(printf '%s' "$row" | cut -f2); url=$(printf '%s' "$row" | cut -f3)
    kind=$(printf '%s' "$row" | cut -f5); params=$(printf '%s' "$row" | cut -f6)
    rated_ids | grep -qxF -- "$id" && continue
    b=${params%B}
    case "$kind" in
      text-generation|image-text-to-text)
        if [ -z "$params" ]; then score=4; match=tier2; reason="script: $kind, size unknown"
        elif awk -v b="$b" -v min="$HF_MIN_B" 'BEGIN { exit !(b < min) }'; then
          score=4; match=tier2; reason="script: $kind, $params total, too small to be a general LLM (under ${HF_MIN_B}B)"
        elif awk -v b="$b" -v max="$HF_FIT_B" 'BEGIN { exit !(b <= max) }'; then
          score=5; match=tier1; reason="script: $kind, $params total, fits this machine (up to ${HF_FIT_B}B)"
        else score=4; match=tier2; reason="script: $kind, $params total, too large for this machine (over ${HF_FIT_B}B)"; fi ;;
      "") score=4; match=tier2; reason="script: no kind given, not rated as an LLM" ;;
      *) score=4; match=tier2; reason="script: $kind${params:+, $params}, not an LLM" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$score" "$match" "$title" "$url" "$reason" >> "$ratings"
    echo "ADDED: $id ($score, $match)"
    added=$((added + 1))
  done <<< "$table"
  echo "$added added by the script. $(rated_ids | sort -u | grep -c .) of $total rated."
  exit 0
fi

if [ ! -f "$profile" ]; then echo "ERROR: $profile is missing. Copy the profile in first. Nothing was added."; exit 1; fi
added=0; rejected=0; seen_line=0
reject() { echo "REJECTED: $1"; rejected=$((rejected + 1)); }
while IFS= read -r line; do
  [ -z "${line// }" ] && continue
  seen_line=1
  if [ "$(printf '%s' "$line" | tr -cd '|' | wc -c)" -lt 3 ]; then
    reject "$line: needs 4 fields, ID | SCORE | MATCH | REASON"; continue
  fi
  IFS='|' read -r id score match reason <<< "$line"
  id=$(echo "$id" | xargs); score=$(echo "$score" | xargs); match=$(echo "$match" | xargs)
  reason=$(printf '%s' "$reason" | tr '\t' ' ' | sed 's/^ *//; s/ *$//')
  row=$(printf '%s\n' "$table" | awk -F'\t' -v id="$id" '$1 == id')
  if [ -z "$row" ]; then reject "$id: not in $(basename "$cand")"; continue; fi
  if rated_ids | grep -qxF -- "$id"; then reject "$id: already rated"; continue; fi
  if [[ ! $score =~ ^[1-5]$ ]]; then reject "$id: score \"$score\" is not 1 to 5"; continue; fi
  case "$match" in
    machine) fits=5 ;; tier1) fits="5 4" ;; tier2) fits=4 ;; tier3) fits=3 ;; none) fits=2 ;; not-interested) fits=1 ;;
    *) reject "$id: MATCH \"$match\" is not machine, tier1, tier2, tier3, none or not-interested"; continue ;;
  esac
  if [[ " $fits " != *" $score "* ]]; then reject "$id: score $score does not fit $match (it takes $fits)"; continue; fi
  if [[ $id == arxiv:* && $score == 5 ]]; then
    reject "$id: an arXiv paper takes at most 4. Use tier1 or tier2 at 4"; continue
  fi
  if [ ${#reason} -lt 10 ] || [ ${#reason} -gt 200 ]; then reject "$id: the reason must be 10 to 200 characters, one line"; continue; fi
  case "$match" in
    machine) head="## Affects my machine"; label="Affects my machine" ;;
    tier1|tier2|tier3) head="## Tier ${match#tier}"; label="Tier ${match#tier}" ;;
    *) head="" ;;
  esac
  if [ -n "$head" ]; then
    quoted=$(printf '%s' "$reason" | sed -n 's/^[^"]*"\([^"]*\)".*/\1/p')
    if [ -z "$quoted" ]; then
      reject "$id: a $match rating quotes, in double quotes, a term from the $label section of CASEY-INTERESTS.md"; continue
    fi
    if [ ${#quoted} -lt 3 ] || [[ " models model release releases news local open new tools tool software update updates agents agent the and for with " == *" ${quoted,,} "* ]]; then
      reject "$id: \"$quoted\" is too generic to show what matched. Quote a specific term from the $label section"; continue
    fi
    if labels "$head" | grep -qixF -- "$(printf '%s' "$quoted" | sed 's/[.:]*$//')"; then
      reject "$id: \"$quoted\" is a heading in the $label section, not a topic. Quote the specific product, project or topic under it"; continue
    fi
    if ! section "$head" | grep -qiF -- "$quoted"; then
      reject "$id: \"$quoted\" is not in the $label section of CASEY-INTERESTS.md, so this is not $match. Pick the MATCH whose section names it"; continue
    fi
  fi
  if [ "$match" = tier1 ] && [ "$score" = 4 ] && [[ $id != arxiv:* ]] && ! printf '%s' "$reason" | grep -qi 'in passing'; then
    reject "$id: tier1 takes 5. Use 4 only when the item touches the topic in passing, and say \"in passing\" in the reason"; continue
  fi
  IFS=$'\t' read -r _ title url _ <<< "$row"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$score" "$match" "$title" "$url" "$reason" >> "$ratings"
  echo "ADDED: $id ($score, $match)"
  added=$((added + 1))
done
if [ "$seen_line" = 0 ]; then echo "ERROR: no rating lines on stdin. Nothing was added."; exit 1; fi
echo "$added added, $rejected rejected. $(rated_ids | sort -u | grep -c .) of $total rated."
[ "$rejected" -gt 0 ] && exit 3
exit 0
