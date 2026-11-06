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

It then removes every NIGHT: entry whose hash is in the done list from
MEMORY.md, so memory (2,200 characters in all) does not fill with tasks that
already ran, and the cron model never sees them. The whole run holds Hermes's
own lock (an exclusive flock on MEMORY.md.lock) and writes the file the way
Hermes does (entries joined by ENTRY_DELIMITER, temp file and rename). Hermes
re-reads the file under that lock before every change, so neither side loses
the other's entries (tools/memory_tool_store.py, v0.22.7, read 2026-11-06).

Exit 0 on success (empty output means nothing to do). Exit 1, with the reason
on stderr, when the memory file cannot be read or the lock stays busy, so cron
raises a failure. Nothing is recorded or changed in that case, so the tasks
run on the next night.
"""
import fcntl
import hashlib
import os
import sys
import tempfile
import time

# Hermes v0.22.7 ENTRY_DELIMITER (tools/memory_tool_store.py, read 2026-11-05).
ENTRY_DELIMITER = "\n§\n"
PREFIX = "night:"
# Three web tasks fit the cron inactivity budget (HERMES_CRON_TIMEOUT, 600 s
# by default) with room to spare. Phase 35 measures it.
MAX_TASKS = 3
# Hermes holds the lock only for one memory write, well under a second.
LOCK_WAIT_SECONDS = 10

HOME = os.path.expanduser("~")
MEMORY = os.path.join(os.environ.get("HERMES_HOME", os.path.join(HOME, ".hermes")), "memories", "MEMORY.md")
DONE = os.path.join(HOME, "jobs", "night-queue-done.txt")
LOCK = MEMORY + ".lock"


def lock_memory():
    """Open and take Hermes's memory lock as Hermes does, or return None after LOCK_WAIT_SECONDS."""
    fd = os.open(LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(fd)
                return None
            time.sleep(0.2)


def write_memory(entries):
    """Replace MEMORY.md atomically, owner-only, in Hermes's own format."""
    fd, tmp = tempfile.mkstemp(prefix=".mem_", dir=os.path.dirname(MEMORY))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(ENTRY_DELIMITER.join(entries))
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, MEMORY)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main():
    if not os.path.isfile(MEMORY):
        print(f"night-queue: cannot read {MEMORY}: no such file", file=sys.stderr)
        return 1
    lock = lock_memory()
    if lock is None:
        print(f"night-queue: {LOCK} still busy after {LOCK_WAIT_SECONDS} s. Nothing recorded, tasks wait for the next run.",
              file=sys.stderr)
        return 1
    try:
        return run_locked()
    finally:
        os.close(lock)


def run_locked():
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

    entries = [e for e in (x.strip() for x in text.split(ENTRY_DELIMITER)) if e]
    pending = []
    for entry in entries:
        if not entry.lower().startswith(PREFIX):
            continue
        digest = hashlib.sha256(entry.encode("utf-8")).hexdigest()
        if digest not in done:
            pending.append((digest, entry[len(PREFIX):].strip()))

    tonight, waiting = pending[:MAX_TASKS], len(pending) - MAX_TASKS
    if tonight:
        os.makedirs(os.path.dirname(DONE), exist_ok=True)
        new_file = not os.path.exists(DONE)
        with open(DONE, "a", encoding="utf-8") as f:
            if new_file:
                f.write("# night-queue.py: sha256 of each NIGHT: memory entry already run. One per line.\n")
            for digest, _ in tonight:
                f.write(digest + "\n")
                done.add(digest)

    kept = [e for e in entries
            if not (e.lower().startswith(PREFIX) and hashlib.sha256(e.encode("utf-8")).hexdigest() in done)]
    if len(kept) != len(entries):
        write_memory(kept)

    if not tonight:
        return 0

    header = f"Night tasks ({len(tonight)} tonight"
    header += f", {waiting} wait for the next run)" if waiting > 0 else ")"
    print(header + ":")
    for i, (_, task) in enumerate(tonight, 1):
        print(f"{i}. {task}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
