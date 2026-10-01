#!/bin/bash
# Tests for add-rating.sh. Run on the host from the repo: bash jobs/test-add-rating.sh
# It runs the script with HOME pointed at a temp dir and fixture candidates.
# Never copied into the VM.
SCRIPT="$(cd "$(dirname "$0")" && pwd)/add-rating.sh"
T=$(mktemp -d)
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail+1)); }
run() { HOME="$T" bash "$SCRIPT" "$@"; }
R="$T/news/ratings-2026-09-27.txt"
D="$T/news/digest-2026-09-27.md"

# --- no candidates yet ---
mkdir -p "$T/news"
out=$(echo 'hn:1 | 5 | machine | llama.cpp is what runs my models' | run 2>&1); rc=$?
[ $rc -eq 1 ] && [[ $out == *ERROR* ]] && ok "no candidates file: exit 1" || bad "no candidates" "rc=$rc out=$out"

# A made-up profile in the real one's section layout. The real profile is
# personal and never goes into a test.
cat > "$T/news/CASEY-INTERESTS.md" <<'EOF'
# CASEY-INTERESTS.md (test fixture)

## How to use this for scoring

Rate each item from 1 to 5.

## Affects my machine

- **Local AI:** llama.cpp `llama-server` in router mode, GGUF models.
- **OS:** Arch Linux, KDE Plasma 6 on Wayland.

## Tier 1: core (career and daily work)

- **Local and frontier AI.** Open-weight models, speculative decoding and MTP.
- **CMS and full-stack development.** WordPress, Shopify (Liquid).
- **Technical SEO.** Search Console changes, Core Web
  Vitals, structured data.

## Tier 2: strong interest

- **Hardware for local inference and gaming.** GPUs and VRAM.

## Tier 3: casual

- Cats and cat products, pet e-commerce.

## Not interested

## Tuning notes
EOF

# An older file whose only item must not be rateable: the newest file is used.
cat > "$T/news/candidates-2026-09-20.md" <<'EOF'
# News candidates 2026-09-20

## Items

### hn:999

- Title: An old story
- URL: https://example.com/old
- Size: points 100, comments 10
EOF
cat > "$T/news/candidates-2026-09-27.md" <<'EOF'
# News candidates 2026-09-27

## Sources

- hn: 3 items
- hf: 1 items
- arxiv: 1 items

## Items

### hn:1

- Title: llama.cpp adds MTP for Qwen MoE models
- URL: https://example.com/llama
- Discussion: https://news.ycombinator.com/item?id=1
- Published: 2026-09-27T01:00:00+00:00
- Size: points 300, comments 50

### hf:org/model

- Title: org/model
- URL: https://huggingface.co/org/model
- Kind: text-generation
- Published: 2026-09-20T00:00:00.000Z
- Size: trending 10, likes 5, downloads 0

### arxiv:2609.00001

- Title: Speculative decoding for agents
- URL: https://arxiv.org/abs/2609.00001
- Kind: cs.CL
- Published: 2026-09-24T17:00:00Z
- Size: none

### hn:2

- Title: A viral sports clip
- URL: https://example.com/clip
- Published: 2026-09-26T16:00:00+00:00
- Size: points 500, comments 200

### hn:3

- Title: A new JavaScript bundler
- URL: https://example.com/bundler
- Published: 2026-09-26T18:00:00+00:00
- Size: points 80, comments 30
EOF

out=$(printf '\n\n' | run 2>&1); rc=$?
[ $rc -eq 1 ] && [[ $out == *ERROR* ]] && ok "empty input: exit 1" || bad "empty input" "rc=$rc out=$out"

out=$(run --left 2>&1); rc=$?
[ $rc -eq 0 ] && [[ $out == *"0 of 5 rated"* ]] && ok "--left: none rated" || bad "--left none" "rc=$rc out=$out"

# --- happy batch (rated out of candidate order, so the digest must sort) ---
out=$(run 2>&1 <<'EOF'
hn:1 | 5 | machine | "llama.cpp" runs every model on this machine
arxiv:2609.00001 | 4 | tier1 | "speculative decoding", mentioned only in passing here
hf:org/model | 4 | tier2 | open-weight text model sized for "VRAM" on a 10 GB card
EOF
); rc=$?
[ $rc -eq 0 ] && [ "$(grep -c . "$R" 2>/dev/null)" = 3 ] && ok "happy: 3 lines added, exit 0" || bad "happy" "rc=$rc out=$out"
grep -q $'^hn:1\t5\tmachine\tllama.cpp adds MTP for Qwen MoE models\thttps://example.com/llama\t' "$R" 2>/dev/null \
  && ok "happy: record carries the title and URL from the candidates" || bad "record shape" "$(head -1 "$R" 2>/dev/null)"

# --- line errors: each rejected on its own, the good line still added ---
before=$(grep -c . "$R")
out=$(run 2>&1 <<'EOF'
hn:2 | 1 | not-interested | sports, nothing in the profile touches it
hn:2 | 1 | not-interested | the same id twice in one batch
hn:999 | 3 | tier3 | an id from the older candidates file
hn:1 | 5 | machine | "llama.cpp" rating an id that is already rated
hn:3 | 7 | tier1 | a score outside one to five
hn:3 | 3 | tier9 | a MATCH that is not in the list
hn:3 | 5 | tier3 | a score that does not fit its MATCH
hn:3 | 2 | none | short
hn:3 | 2 | none
EOF
); rc=$?
[ $rc -eq 3 ] && ok "errors: exit 3 when any line is rejected" || bad "errors exit" "rc=$rc out=$out"
[ "$(grep -c . "$R")" = $((before + 1)) ] && grep -q $'^hn:2\t1\t' "$R" && ok "errors: the good line was added, no bad one" || bad "errors added" "$(cat "$R")"
[ "$(printf '%s\n' "$out" | grep -c '^REJECTED')" = 8 ] && ok "errors: 8 lines REJECTED" || bad "errors count" "$out"
for want in "already rated" "not in" "already rated" "score" "MATCH" "fit" "reason" "fields"; do
  printf '%s\n' "$out" | grep '^REJECTED' | grep -qi -- "$want" || bad "errors: a REJECTED line says '$want'" "$out"
done
[ "$(printf '%s\n' "$out" | grep '^REJECTED' | sed -n 2p | grep -c 'not in')" = 1 ] && ok "errors: an id only in the older file is 'not in' today's candidates" || bad "newest file" "$out"
printf '%s\n' "$out" | grep -q '^REJECTED: hn:3.*fit' && printf '%s\n' "$out" | grep -q '^REJECTED: hn:3.*reason' \
  && printf '%s\n' "$out" | grep -q '^REJECTED.*fields' && ok "errors: each reason names its problem" || bad "reasons" "$out"

out=$(run --left 2>&1); rc=$?
[ $rc -eq 0 ] && [[ $out == *"4 of 5 rated"* ]] && [[ $out == *"hn:3"* ]] && ok "--left: some rated, names the next unrated" || bad "--left some" "rc=$rc out=$out"

# --- digest with one unrated ---
out=$(run --digest 2>&1); rc=$?
[ $rc -eq 3 ] && [ -f "$D" ] && grep -q 'Rated 4 of 5' "$D" && sed -n '/^## Not rated/,$p' "$D" | grep -q 'hn:3' \
  && ok "--digest with one unrated: written, says so, exit 3" || bad "--digest unrated" "rc=$rc out=$out $(cat "$D" 2>/dev/null)"

out=$(echo 'hn:3 | 2 | none | a JavaScript bundler, programming but no tier names it' | run 2>&1); rc=$?
out=$(run --left 2>&1)
[[ $out == *"All 5 rated"* ]] && ok "--left: all rated" || bad "--left all" "$out"

# --- digest with all rated ---
out=$(run --digest 2>&1); rc=$?
order=$(grep -o '(hn:[0-9]*)\|(hf:[^)]*)\|(arxiv:[^)]*)' "$D" 2>/dev/null | tr -d '()' | tr '\n' ' ')
[ $rc -eq 0 ] && [ "$order" = "hn:1 hf:org/model arxiv:2609.00001 hn:3 hn:2 " ] \
  && ok "--digest: exit 0, highest score first, then candidate order" || bad "--digest order" "rc=$rc order=$order"
grep -q 'points 300, comments 50' "$D" 2>/dev/null && grep -q 'machine: "llama.cpp" runs every model on this machine' "$D" \
  && ! grep -q '^## Not rated' "$D" && ok "--digest: shows size, MATCH and reason, no Not rated section" || bad "--digest body" "$(cat "$D" 2>/dev/null)"

# --- round 1: the MATCH must be backed by a quoted term from its own profile section ---
T2=$(mktemp -d); mkdir -p "$T2/news"
cp "$T/news/CASEY-INTERESTS.md" "$T2/news/"
{ echo "# News candidates 2026-09-28"; echo; echo "## Items"
  for n in 11 12 13 14 15 16 17 18 19 20; do printf '\n### hn:%s\n\n- Title: Story %s\n- URL: https://example.com/%s\n- Size: points 60, comments 5\n' $n $n $n; done
  for n in 1 2 3 4; do printf '\n### arxiv:2609.9000%s\n\n- Title: Paper %s\n- URL: https://arxiv.org/abs/2609.9000%s\n- Size: none\n' $n $n $n; done
} > "$T2/news/candidates-2026-09-28.md"
run2() { HOME="$T2" bash "$SCRIPT" "$@"; }
R2="$T2/news/ratings-2026-09-28.txt"
q() {  # $1 name, $2 line, $3 expected ADDED or REJECTED, $4 text the REJECTED reason must hold
  out=$(printf '%s\n' "$2" | run2 2>&1)
  if [ "$3" = ADDED ]; then [[ $out == ADDED:* ]] && ok "quote: $1" || bad "quote: $1" "$out"
  else [[ $out == REJECTED:* ]] && printf '%s' "$out" | head -1 | grep -qi -- "$4" && ok "quote: $1" || bad "quote: $1" "$out"; fi
}
q "machine with no quoted term is rejected"         'hn:11 | 5 | machine | runs on this workstation somehow'                 REJECTED "in double quotes"
q "machine quoting a Tier 1-only term is rejected"  'hn:11 | 5 | machine | "WordPress" plugin release for my sites'           REJECTED "Affects my machine"
q "tier3 quoting a Tier 1 term is rejected"         'hn:11 | 3 | tier3 | "speculative decoding" paper, casual AI interest'   REJECTED "Tier 3"
q "a generic quoted word is rejected"               'hn:11 | 5 | machine | "models" for local inference on this GPU'          REJECTED generic
q "agents alone is generic (run 2 Drawgent)"        'hn:20 | 5 | machine | coding "agents" drawing on a canvas'               REJECTED generic
q "tier1 at 4 without in passing is rejected"       'hn:11 | 4 | tier1 | "WordPress" core release, useful for client sites'  REJECTED "in passing"
q "tier1 at 4 with in passing is added"             'hn:12 | 4 | tier1 | "Shopify" named in passing in a payments story'     ADDED
q "tier1 at 5 with a Tier 1 term is added"          'hn:13 | 5 | tier1 | "WordPress" 7.0 release, CMS work for clients'     ADDED
q "machine quoting a machine term is added"         'hn:14 | 5 | machine | "KDE Plasma" 6.5 release, the desktop here'        ADDED
q "the quote matches regardless of case"            'hn:15 | 4 | tier2 | new "vram" pricing for consumer GPUs'              ADDED
q "tier3 quoting a Tier 3 term is added"            'hn:16 | 3 | tier3 | "pet e-commerce" platform raises prices'           ADDED
q "none needs no quote"                             'hn:17 | 2 | none | a Go concurrency article, no tier names it'         ADDED
q "not-interested needs no quote"                   'hn:18 | 1 | not-interested | a sports story, not tech news at all'  ADDED
q "a term wrapped across two lines still matches"  'hn:11 | 5 | tier1 | "Core Web Vitals" update changes site rankings'    ADDED
# round 3: an arXiv paper takes at most 4 unless machine
q "arxiv tier1 5 is rejected"                       'arxiv:2609.90001 | 5 | tier1 | "speculative decoding" method for faster decoding'  REJECTED arXiv
q "arxiv tier1 4 needs no in passing"               'arxiv:2609.90001 | 4 | tier1 | "speculative decoding" method for faster decoding'  ADDED
q "arxiv machine 5 is added"                        'arxiv:2609.90002 | 5 | machine | "llama.cpp" kernel change measured on consumer GPUs' ADDED
q "arxiv tier2 4 is added"                          'arxiv:2609.90003 | 4 | tier2 | "VRAM" use of long-context inference'              ADDED
# round 4: a section's bold label is a heading, not a topic (runs 8 and 9 split on "AI automation")
q "machine quoting its label is rejected"           'hn:19 | 5 | machine | "Local AI" change on this workstation'              REJECTED heading
q "tier1 quoting its label is rejected"             'hn:19 | 5 | tier1 | "Technical SEO" story about rankings'               REJECTED heading
q "a label in another case is rejected"             'hn:19 | 5 | tier1 | "local and frontier ai" agents misbehaving'         REJECTED heading
q "a label with its colon is rejected"              'hn:19 | 5 | machine | "OS:" news for this desktop'                       REJECTED heading
q "tier2 quoting its label is rejected"             'hn:19 | 4 | tier2 | "Hardware for local inference and gaming" story'   REJECTED heading
[ "$(grep -c . "$R2")" = 11 ] && ok "quote: only the 11 good lines were recorded" || bad "quote: recorded" "$(cat "$R2")"
rm "$T2/news/CASEY-INTERESTS.md"
out=$(echo 'hn:19 | 2 | none | a Go concurrency article, no tier names it' | run2 2>&1); rc=$?
[ $rc -eq 1 ] && [[ $out == *ERROR* ]] && [[ $out == *CASEY-INTERESTS.md* ]] && ok "profile missing: batch mode exits 1" || bad "profile missing" "rc=$rc out=$out"
out=$(run2 --left 2>&1); rc=$?
[ $rc -eq 0 ] && [[ $out == *"11 of 14 rated"* ]] && ok "profile missing: --left still works" || bad "profile missing --left" "rc=$rc out=$out"
rm -rf "$T2"

# --- --hf: the script rates Hugging Face items from Kind and Params (Phase 10) ---
T3=$(mktemp -d); mkdir -p "$T3/news"
hfitem() { printf '\n### hf:%s\n\n- Title: %s\n- URL: https://huggingface.co/%s\n' "$1" "$1" "$1"
  [ -n "$2" ] && printf -- '- Kind: %s\n' "$2"; [ -n "$3" ] && printf -- '- Params: %s\n' "$3"
  printf -- '- Published: 2026-09-20T00:00:00.000Z\n- Size: trending 10, likes 5, downloads 0\n'; }
{ echo "# News candidates 2026-09-29"; echo; echo "## Items"
  printf '\n### hn:31\n\n- Title: Story 31\n- URL: https://example.com/31\n- Size: points 60, comments 5\n'
  hfitem a/llm-9b text-generation 9.0B
  hfitem a/llm-35b text-generation 35.0B
  hfitem a/llm-big text-generation 35.1B
  hfitem a/llm-nosize text-generation ""
  hfitem a/vlm-27b image-text-to-text 27.8B
  hfitem a/image text-to-image 7.1B
  hfitem a/nokind "" 1.0B
} > "$T3/news/candidates-2026-09-29.md"
run3() { HOME="$T3" bash "$SCRIPT" "$@"; }
R3="$T3/news/ratings-2026-09-29.txt"
out=$(run3 --hf 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(grep -c . "$R3" 2>/dev/null)" = 7 ] && ok "--hf: all 7 hf items rated, exit 0, no profile needed" || bad "--hf run" "rc=$rc out=$out"
hf() {  # $1 name, $2 id, $3 score, $4 match, $5 text the reason must hold
  line=$(awk -F'\t' -v id="hf:a/$2" '$1 == id' "$R3" 2>/dev/null)
  IFS=$'\t' read -r _ sc ma _ _ re <<< "$line"
  [ "$sc" = "$3" ] && [ "$ma" = "$4" ] && [[ $re == script:* ]] && [[ ${re,,} == *"${5,,}"* ]] && ok "--hf: $1" || bad "--hf: $1" "$line"
}
hf "a 9B LLM fits, tier1 5"                    llm-9b     5 tier1 "fits this machine"
hf "exactly 35B still fits"                    llm-35b    5 tier1 "fits this machine"
hf "35.1B is too large, tier2 4"               llm-big    4 tier2 "too large"
hf "an LLM with no Params is tier2 4"          llm-nosize 4 tier2 "size unknown"
hf "an image-text-to-text LLM at 27.8B fits"   vlm-27b    5 tier1 "fits this machine"
hf "a text-to-image model is tier2 4"          image      4 tier2 "not an LLM"
hf "no Kind is tier2 4"                        nokind     4 tier2 "no kind"
out=$(run3 --left 2>&1)
[[ $out == *"7 of 8 rated"* ]] && [[ $out == *"hn:31"* ]] && ok "--hf: HN left for Hermes" || bad "--hf left" "$out"
out=$(run3 --hf 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(grep -c . "$R3")" = 7 ] && ok "--hf: a second run adds nothing" || bad "--hf twice" "rc=$rc out=$out"
cp "$T/news/CASEY-INTERESTS.md" "$T3/news/"
out=$(echo 'hf:a/image | 5 | tier1 | "Open-weight models" image model' | run3 2>&1)
[[ $out == REJECTED:*"already rated"* ]] && ok "--hf: a later Hermes line for an hf item is refused" || bad "--hf then Hermes" "$out"
rm -rf "$T3"
T4=$(mktemp -d); mkdir -p "$T4/news"
printf '# News candidates 2026-09-29\n\n## Items\n\n### hn:41\n\n- Title: Story\n- URL: https://example.com/41\n- Size: none\n' > "$T4/news/candidates-2026-09-29.md"
out=$(HOME="$T4" bash "$SCRIPT" --hf 2>&1); rc=$?
[ $rc -eq 0 ] && [[ $out == *"0 added"* ]] && ok "--hf: no hf items, 0 added, exit 0" || bad "--hf none" "rc=$rc out=$out"
rm -rf "$T4"

echo "passed=$pass failed=$fail"
rm -rf "$T"
[ $fail -eq 0 ]
