# Topic scout sweep for everything4cats

Another session has just researched article ideas and appended them to a
file. Your job is to check that file against the rules below and fix it with
the commands shown, then finish it. You do no research: never add an idea,
never search, and never write a URL. You only remove, demote, or delete what
breaks a rule, and then append the summary.

FILE means `~/scout/topic-scout-DATE.md` and LEFT means
`~/scout/left-out-DATE.txt`, with DATE replaced by today's date. Use the
`terminal` tool for every step, running only the commands shown. Change FILE
and LEFT only with those commands.

## Rules the sweep enforces

- Rule 4: a competitor is an article, guide, or review, never a shop page. A
  URL whose path holds /shop/, /b/, /product/, /products/, /collections/,
  /pet-supplies/ or /category/, or whose site name ends in .store, is a shop
  page.
- Rule 5: every idea needs 3 to 5 competitor URLs. One with fewer is deleted
  and listed in LEFT.
- Rule 9: at most 3 `roundup` ideas.
- Rule 11: at least 60% of ideas are `Timely: yes` (tied to a named event or
  season, stated in "Why now"). If fewer are, the file says so in its Notes.
  No idea is deleted for that.
- An idea whose slug is already on the seen list (`~/jobs/topic-scout-seen.txt`)
  is deleted and listed in LEFT.
- A competitor URL appears in one idea only, and a dead one (404, 410, or no
  answer) is removed.

## Steps

1. Find today's date with `date +%F`, then check FILE exists. If `ls` reports
   no such file, stop and reply only "FILE missing: " and the path.

```bash
ls -l FILE LEFT
grep -c '^## [0-9]' FILE
```

2. Sweep the whole file before finishing. Run these seven checks, in
   this order, and act on what they print.

   a. Competitor URLs used more than once. For each URL printed, keep it in
      the first idea and remove it from the later ones with the command
      after it, with the printed URL in place of URL:

```bash
awk '/^- Competitors:/{c=1;next} /^- /{c=0} c && /^  - http/{print $2}' FILE | sort | uniq -d
```

```bash
awk -v u='URL' '/^- /{c=($0 ~ /^- Competitors:/)} {if (c && $1=="-" && $2==u && seen++) next; print}' FILE > FILE.tmp && mv FILE.tmp FILE
```

   b. Dead competitor URLs. For each line printed, remove that URL
      everywhere in FILE with the command after it:

```bash
awk '/^- Competitors:/{c=1;next} /^- /{c=0} c && /^  - http/{print $2}' FILE | sort -u | while read -r u; do
  code=$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 15 "$u")
  case "$code" in 404|410|000) echo "DEAD $code $u" ;; esac
  sleep 1
done
```

```bash
awk -v u='URL' '!($1=="-" && $2==u)' FILE > FILE.tmp && mv FILE.tmp FILE
```

   c. Shop pages (rule 4). For each URL printed, remove it with the command
      from b:

```bash
awk '/^- Competitors:/{c=1;next} /^- /{c=0} c && /^  - http/ && $2 ~ /^https?:\/\/[^\/]+\.store(\/|$)|\/(shop|b|product|products|collections|pet-supplies|category)\//{print $2}' FILE | sort -u
```

   d. Competitors per idea. For each idea with fewer than 3, delete the idea
      with the command after it (N is its number, digits only, for example
      4) and add it to LEFT:

```bash
awk '/^## [0-9]+\. /{n=$2; sub(/\.$/,"",n); o[++m]=n; k[n]=0} /^- Competitors:/{c=1;next} /^- /{c=0} c && /^  - http/{k[n]++} END{for(i=1;i<=m;i++) print "idea " o[i] ": " k[o[i]] " competitors"}' FILE
```

```bash
awk -v n='N' '/^## [0-9]+\. /{skip=($2==n".")} !skip' FILE > FILE.tmp && mv FILE.tmp FILE
echo 'Left out: working title (N competitors found)' >> LEFT
```

   e. Roundups. Rule 9 allows 3. The command prints every roundup in file
      order. Keep the first 3. Delete each one after that with the idea
      delete command from d (N is its idea number, digits only), and add it
      to LEFT with the reason:

```bash
awk '/^## [0-9]+\. /{n=$2; sub(/\.$/,"",n)} /^- Type: roundup/{r++; print "roundup " r ": idea " n}' FILE
```

```bash
echo 'Left out: working title (over the 3-roundup cap)' >> LEFT
```

   f. Timely. The command prints how many ideas are `Timely: yes`. If that is
      under 60% of the ideas, add the line it prints to LEFT with the second
      command, so the Notes show the shortfall. Never delete or change an idea
      for being untimely.

```bash
echo "Timely: $(grep -c '^- Timely: yes' FILE) of $(grep -c '^## [0-9]' FILE)"
```

```bash
echo "Timely: $(grep -c '^- Timely: yes' FILE) of $(grep -c '^## [0-9]' FILE), below 60%" >> LEFT
```

   g. Seen slugs. The command prints every idea whose slug is on the seen
      list. Delete each one with the delete command from d, and add it to
      LEFT:

```bash
awk 'FNR == NR {if ($0 !~ /^#/ && NF) s[$1] = 1; next} /^## [0-9]+\. /{n = $2; sub(/\.$/, "", n)} /^- Slug: /{g = $3; gsub(/`/, "", g); if (g in s) print "idea " n ": " g}' ~/jobs/topic-scout-seen.txt FILE
```

```bash
echo 'Left out: working title (already on the seen list)' >> LEFT
```

   Run a to g again until none of them finds anything to fix.

3. Append the summary with two commands, each run on its own. Hermes blocks
   a grouped `{ ... }` or `if` command here, so keep them exactly this plain.
   First the summary and the Notes heading:

```bash
IDEAS=$(grep -c '^## [0-9]' FILE) && printf '\n## Summary\n\n- Ideas: %s\n\n## Notes\n\n' "$IDEAS" >> FILE
```

   Then the notes. Run `ls -l LEFT`. If its size is 0, run the first command
   below. Otherwise run the second:

```bash
echo 'None.' >> FILE
```

```bash
cat LEFT >> FILE
```

4. Run these commands and put their exact output in your reply, then stop.
   Do not describe the file in your own words.

```bash
echo "file: FILE"; echo "ideas: $(grep -c '^## [0-9]' FILE)"; tail -n 4 FILE; echo "LEFT:"; cat LEFT
```

   The `tail` lines must show the `## Notes` section. If they do not, step 3
   has not run: run step 3, then this step again.
