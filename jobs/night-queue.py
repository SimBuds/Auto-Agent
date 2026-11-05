#!/usr/bin/env python3
"""Feed Casey's queued night tasks to the nightly Hermes cron job.

Runs inside the VM as the job's --script, from ~/.hermes/scripts/night-queue.py
(cron only runs scripts from that directory). Its stdout is injected into the
job's prompt, and an empty stdout makes Hermes skip the model call, so a night
with nothing queued costs nothing (cron/scheduler.py, v0.22.7).

Casey queues a task in Telegram ("Night task: ..."), and Hermes saves it with
its memory tool as an entry starting NIGHT:. This script reads those entries
from ~/.hermes/memories/MEMORY.md, prints up to MAX_TASKS that have not run,
and records each one's hash in ~/jobs/night-queue-done.txt before printing,
so a task runs at most once even if the job fails afterwards. The rule lives
here and not in the prompt because a rule that matters goes in a script
(PLAN.md, topic scout lessons).

Exit 0 on success (empty output means nothing to do). Exit 1, with the reason
on stderr, when the memory file cannot be read, so cron raises a failure.
"""
import hashlib
import os
import sys

# Hermes v0.22.7 ENTRY_DELIMITER (tools/memory_tool_store.py, read 2026-11-05).
ENTRY_DELIMITER = "\n§\n"
PREFIX = "night:"
# Three web tasks fit the cron inactivity budget (HERMES_CRON_TIMEOUT, 600 s
# by default) with room to spare. Phase 35 measures it.
MAX_TASKS = 3

HOME = os.path.expanduser("~")
MEMORY = os.path.join(os.environ.get("HERMES_HOME", os.path.join(HOME, ".hermes")), "memories", "MEMORY.md")
DONE = os.path.join(HOME, "jobs", "night-queue-done.txt")


def main():
    try:
        with open(MEMORY, encoding="utf-8") as f:
            text = f.read()
    except OSError as exc:
        print(f"night-queue: cannot read {MEMORY}: {exc}", file=sys.stderr)
        return 1

    done = set()
    if os.path.exists(DONE):
        with open(DONE, encoding="utf-8") as f:
            done = {line.strip() for line in f if line.strip() and not line.startswith("#")}

    pending = []
    for entry in text.split(ENTRY_DELIMITER):
        entry = entry.strip()
        if not entry.lower().startswith(PREFIX):
            continue
        digest = hashlib.sha256(entry.encode("utf-8")).hexdigest()
        if digest not in done:
            pending.append((digest, entry[len(PREFIX):].strip()))

    if not pending:
        return 0

    tonight, waiting = pending[:MAX_TASKS], len(pending) - MAX_TASKS
    os.makedirs(os.path.dirname(DONE), exist_ok=True)
    new_file = not os.path.exists(DONE)
    with open(DONE, "a", encoding="utf-8") as f:
        if new_file:
            f.write("# night-queue.py: sha256 of each NIGHT: memory entry already run. One per line.\n")
        for digest, _ in tonight:
            f.write(digest + "\n")

    header = f"Night tasks ({len(tonight)} tonight"
    header += f", {waiting} wait for the next run)" if waiting > 0 else ")"
    print(header + ":")
    for i, (_, task) in enumerate(tonight, 1):
        print(f"{i}. {task}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
