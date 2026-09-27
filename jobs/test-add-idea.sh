#!/bin/bash
# Tests for add-idea.sh. Run on the host from the repo: bash jobs/test-add-idea.sh
# It runs the script with HOME pointed at a temp dir and a fixed seen list, so
# changes to the live seen list cannot move the results. Never copied into the VM.
# Kept in the repo because the scratch copy was lost three times (2026-09-26 and 27).
SCRIPT="$(cd "$(dirname "$0")" && pwd)/add-idea.sh"
T=$(mktemp -d)
mkdir -p "$T/scout" "$T/jobs"
cat > "$T/jobs/topic-scout-seen.txt" <<'EOF'
# Fixture seen list

best-cat-food-storage-containers-canada
how-to-keep-cats-warm-winter-indoor
holiday-plants-safe-toxic-cats-canada
how-to-keep-cats-calm-safe-during-holidays
best-interactive-cat-toys-indoor-cats-canada
best-cat-toys-for-senior-cats-canada
best-cat-travel-carrier-canada
best-cat-trees-for-large-cats
best-cat-bed-cold-canadian-winters-guide
how-to-choose-cat-sweater-winter-coat-guide
cat-water-fountain
halloween-safety-guide-for-cats-canada
safe-halloween-cat-costume-canada
best-automatic-cat-feeders-with-cameras
EOF
F="$T/scout/topic-scout-$(date +%F).md"
MONTH=$(LC_ALL=C date +%B)
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail+1)); }

idea() {  # $1 title, $2 slug, $3 type, $4 timely, $5 why now
cat <<EOF

## $1

- Slug: \`$2\`
- Type: ${3:-guide}
- YMYL: no
- Timely: ${4:-yes}
- Why now: ${5:-Test for $MONTH.}
- Suggested keywords:
  - one
  - two
  - three
- Competitors:
  - https://example.ca/a
  - https://example.com/b
  - https://example.ca/c
- Sources:
  - https://example.ca/s (test)
EOF
}
run() { HOME="$T" bash "$SCRIPT" "$@"; }
same() { [ "$(md5sum < "$F")" = "$1" ]; }

# --- errors, numbering, repeats (round 16) ---
out=$(idea "X" "cat-microchip-registration-canada" | run 2>&1); rc=$?
[ $rc -eq 1 ] && [[ $out == *ERROR* ]] && ok "FILE missing exits 1" || bad "FILE missing" "rc=$rc out=$out"

printf '# Topic scout test\n' > "$F"
out=$(idea "Cat microchip registration in Canada" "cat-microchip-registration-canada" | run 2>&1); rc=$?
[ $rc -eq 0 ] && grep -qx '## 1. Cat microchip registration in Canada' "$F" && ok "new slug added as 1" || bad "new slug" "rc=$rc out=$out"

before=$(md5sum < "$F")
out=$(idea "Again" "cat-microchip-registration-canada" | run 2>&1); rc=$?
[ $rc -eq 2 ] && [[ $out == *TAKEN* ]] && same "$before" && ok "slug in FILE taken, FILE unchanged" || bad "slug in FILE" "rc=$rc out=$out"

printf '# Topic scout test\n\n## 1. a\n\n## 2. b\n\n## 3. c\n\n## 6. d\n' > "$F"
out=$(idea "Cat dental care guide" "cat-dental-care-guide-canada" | run 2>&1); rc=$?
[ $rc -eq 0 ] && grep -qx '## 7. Cat dental care guide' "$F" && ok "numbered 7 after 6" || bad "gap numbering" "rc=$rc out=$out"

for s in how-to-keep-cats-warm-canadian-winter-guide holiday-plants-toxic-to-cats-christmas-guide; do
  before=$(md5sum < "$F")
  out=$(idea "Repeat" "$s" | run 2>&1); rc=$?
  [ $rc -eq 2 ] && [[ $out == *TAKEN* ]] && same "$before" && ok "repeat $s taken" || bad "repeat $s" "rc=$rc out=$out"
done

out=$(idea "NYE fireworks" "how-to-keep-cats-safe-new-years-eve-fireworks-guide" | run 2>&1); rc=$?
[ $rc -eq 0 ] && [[ $out == *ADDED* ]] && ok "keep/safe overlap only is added" || bad "keep/safe" "rc=$rc out=$out"

out=$(run --check best-cat-food-storage-containers-canada 2>&1); rc=$?
[ $rc -eq 2 ] && [[ $out == *TAKEN* ]] && ok "--check exact seen slug taken" || bad "--check exact" "rc=$rc out=$out"

out=$(run --check cat-nail-grinder-vs-clipper-guide 2>&1); rc=$?
[ $rc -eq 0 ] && [[ $out == OK* ]] && ok "--check new slug OK" || bad "--check new" "rc=$rc out=$out"

out=$(run --check best-toys-for-bored-indoor-cats-canada 2>&1); rc=$?
[ $rc -eq 2 ] && ok "--check toys repeat taken" || bad "--check toys" "rc=$rc out=$out"

before=$(md5sum < "$F")
out=$(idea "No slug" "x" | grep -v '^- Slug' | run 2>&1); rc=$?
[ $rc -eq 1 ] && same "$before" && ok "no slug exits 1" || bad "no slug" "rc=$rc out=$out"
out=$(idea "T" "cat-grooming-brush-guide" | grep -v '^## ' | run 2>&1); rc=$?
[ $rc -eq 1 ] && same "$before" && ok "no title exits 1" || bad "no title" "rc=$rc out=$out"

grep -B1 -x '## 7. Cat dental care guide' "$F" | head -1 | grep -qx '' && grep -q '^- Slug: `cat-dental-care-guide-canada`' "$F" && ok "block shape" || bad "block shape" "$(tail -25 "$F")"

# --- A: plurals and one-word topics (round 17, run 16's repeats) ---
for s in best-cat-carriers-travel-canada best-cat-trees-guide-canada best-cat-beds-winter-warmth-canada best-cat-winter-coats-sweaters-guide-canada best-cat-water-fountains-canada; do
  out=$(run --check "$s" 2>&1); rc=$?
  [ $rc -eq 2 ] && [[ $out == *TAKEN* ]] && ok "A: $s taken" || bad "A: $s" "rc=$rc out=$out"
done
out=$(run --check best-cat-toys-for-kittens-canada 2>&1); rc=$?
[ $rc -eq 0 ] && ok "A: toys kittens, one shared word of two, OK" || bad "A: toys kittens" "rc=$rc out=$out"
out=$(run --check best-cat-harnesses-canada 2>&1); rc=$?
[ $rc -eq 0 ] && ok "A: one-word new topic OK" || bad "A: harnesses" "rc=$rc out=$out"
out=$(run --check how-to-choose-cat-camera-with-treat-dispenser-canada 2>&1); rc=$?
[ $rc -eq 0 ] && ok "A: 'with' is not a topic word" || bad "A: with" "rc=$rc out=$out"

# --- B: Best titles are roundups, cap 3 (round 17) ---
printf '# Topic scout test\n' > "$F"
before=$(md5sum < "$F")
out=$(idea "Best cat grooming brushes in Canada" "best-cat-grooming-brushes-canada" guide | run 2>&1); rc=$?
[ $rc -eq 3 ] && [[ $out == *REJECTED* ]] && same "$before" && ok "B: Best title typed guide rejected" || bad "B: Best guide" "rc=$rc out=$out"
out=$(idea "Best cat grooming brush types explained" "cat-grooming-brush-types-guide" guide | run 2>&1); rc=$?
[ $rc -eq 0 ] && ok "B: Best ... types guide added" || bad "B: types" "rc=$rc out=$out"
for s in best-cat-nail-grinders-canada best-cat-harnesses-canada best-cat-laser-pointers-canada; do
  out=$(idea "Best $s" "$s" roundup | run 2>&1); rc=$?
  [ $rc -eq 0 ] || bad "B: roundup $s" "rc=$rc out=$out"
done
[ "$(grep -c '^- Type: roundup' "$F")" -eq 3 ] && ok "B: 3 roundups added" || bad "B: 3 roundups" "$(grep -c '^- Type: roundup' "$F")"
before=$(md5sum < "$F")
out=$(idea "Best cat window hammocks" "best-cat-window-hammocks-canada" roundup | run 2>&1); rc=$?
[ $rc -eq 3 ] && [[ $out == *REJECTED* ]] && same "$before" && ok "B: 4th roundup rejected" || bad "B: 4th roundup" "rc=$rc out=$out"

# --- C: a timely idea names a month inside the window (round 17) ---
before=$(md5sum < "$F")
out=$(idea "Cat fireworks prep for Canada Day" "cat-fireworks-prep-canada-day" guide yes "Canada Day is July 1. Publish in June." | run 2>&1); rc=$?
[ $rc -eq 3 ] && [[ $out == *REJECTED* ]] && same "$before" && ok "C: timely naming only July rejected" || bad "C: July" "rc=$rc out=$out"
out=$(idea "Cat safe decorations" "cat-safe-holiday-decorations-guide" guide yes "Holiday decorations go up soon." | run 2>&1); rc=$?
[ $rc -eq 3 ] && same "$before" && ok "C: 'decorations' is not December" || bad "C: decorations" "rc=$rc out=$out"
NEXT=$(LC_ALL=C date -d "$(date +%Y-%m-15) +2 month" +%B)
out=$(idea "Cat microchip week" "cat-microchip-registration-guide" guide yes "Registration drives run in ${NEXT:0:3}." | run 2>&1); rc=$?
[ $rc -eq 0 ] && ok "C: 3-letter window month ($NEXT) added" || bad "C: window month" "rc=$rc out=$out"
out=$(idea "Cat dental home care" "cat-dental-home-care-guide" guide no "Evergreen." | run 2>&1); rc=$?
[ $rc -eq 0 ] && ok "C: Timely no without a month added" || bad "C: timely no" "rc=$rc out=$out"

# --- D: a best- slug is a roundup too (Phase 6, run 21 idea 10) ---
printf '# Topic scout test\n' > "$F"
before=$(md5sum < "$F")
out=$(idea "How to Choose the Best Low-Dust Cat Litter" "best-low-dust-cat-litter-guide" guide | run 2>&1); rc=$?
[ $rc -eq 3 ] && [[ $out == *REJECTED* ]] && same "$before" && ok "D: best- slug typed guide rejected" || bad "D: best- guide" "rc=$rc out=$out"
out=$(idea "How to choose low-dust cat litter" "best-low-dust-cat-litter-guide" how-to | run 2>&1); rc=$?
[ $rc -eq 3 ] && same "$before" && ok "D: best- slug typed how-to rejected" || bad "D: best- how-to" "rc=$rc out=$out"
out=$(idea "Cat litter types explained" "best-cat-litter-types-guide" guide | run 2>&1); rc=$?
[ $rc -eq 0 ] && ok "D: best-...-types slug typed guide added" || bad "D: types slug" "rc=$rc out=$out"
out=$(idea "Top cat scratcher picks" "best-cat-scratchers-canada" roundup | run 2>&1); rc=$?
[ $rc -eq 0 ] && ok "D: best- slug typed roundup added" || bad "D: best- roundup" "rc=$rc out=$out"
out=$(idea "How to choose a cat scratcher" "how-to-choose-cat-scratcher-canada" guide | run 2>&1); rc=$?
[ $rc -eq 0 ] && ok "D: non-best slug typed guide added" || bad "D: non-best" "rc=$rc out=$out"

echo "passed=$pass failed=$fail"
rm -rf "$T"
[ $fail -eq 0 ]
