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
- Rule 11: each `Timely: yes` idea lists a source ending "(published
  YYYY-MM-DD)" with a date before today and no more than 90 days old. A date
  of today, a date older than 90 days, or a partial date ("2026", "2026-08")
  does not count. If fewer than 60% of ideas are timely, the file says so in
  its Notes. No idea is deleted for that.
- A competitor URL appears in one idea only, and a dead one (404, 410, or no
  answer) is removed.

## Steps

1. Find today's date with `date +%F`, then check FILE exists. If `ls` reports
   no such file, stop and reply only "FILE missing: " and the path.

```bash
ls -l FILE LEFT
grep -c '^## [0-9]' FILE
```

2. Sweep the whole file before finishing. Run these six checks, in
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

   f. Timely. The command prints each idea's Timely value and whether it has
      a dated source inside the window (before today, at most 90 days old,
      the command works this out). Set any `Timely: yes` idea without one to
      `no` with the command after it. Never delete an idea for being
      untimely. If fewer than 60% of ideas are `Timely: yes` when the sweep
      is done, add one line to LEFT saying so (the last command below), so
      the Notes show the shortfall.

```bash
awk -v today="$(date +%F)" -v cut="$(date -d '90 days ago' +%F)" '/^## [0-9]+\. /{if (n != "") print "idea " n ": timely " t ", dated " (d ? "yes" : "no"); n = $2; sub(/\.$/, "", n); t = "no"; d = 0} /^- Timely: yes/{t = "yes"} match($0, /\(published [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)/){ds = substr($0, RSTART + 11, 10); if (ds >= cut && ds < today) d = 1} END{if (n != "") print "idea " n ": timely " t ", dated " (d ? "yes" : "no")}' FILE
```

```bash
awk -v n='N' '/^## [0-9]+\. /{cur = $2} cur == n "." && /^- Timely: yes/{$0 = "- Timely: no"} 1' FILE > FILE.tmp && mv FILE.tmp FILE
```

```bash
echo "Timely: $(grep -c '^- Timely: yes' FILE) of $(grep -c '^## [0-9]' FILE), below 60%" >> LEFT
```

   Run a to f again until none of them finds anything to fix.

3. Append the summary. IDEAS is `grep -c '^## [0-9]' FILE`:

```bash
{ printf '\n## Summary\n\n- Ideas: IDEAS\n\n## Notes\n\n'
  if [ -s LEFT ]; then cat LEFT; else echo 'None.'; fi
} >> FILE
```

4. Run these commands and put their exact output in your reply, then stop.
   Do not describe the file in your own words.

```bash
echo "file: FILE"; echo "ideas: $(grep -c '^## [0-9]' FILE)"; tail -n 4 FILE; echo "LEFT:"; cat LEFT
```

   The `tail` lines must show the `## Notes` section. If they do not, step 3
   has not run: run step 3, then this step again.
