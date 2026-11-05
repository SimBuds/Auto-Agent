#!/usr/bin/env python3
"""Tests for night-queue.py. Run on the host: python3 jobs/test-night-queue.py

Each case runs the feeder with HOME pointed at a temp dir holding a fixture
MEMORY.md, so the VM's real memory and done list are never read or written.
The separator is Hermes v0.22.7's ENTRY_DELIMITER, "\\n§\\n"
(tools/memory_tool_store.py, read 2026-11-05).
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "night-queue.py")
SEP = "\n§\n"

passed = failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"PASS {name}")
    else:
        failed += 1
        print(f"FAIL {name}: {detail}")


def setup(entries=None):
    home = tempfile.mkdtemp()
    if entries is not None:
        os.makedirs(os.path.join(home, ".hermes", "memories"))
        with open(os.path.join(home, ".hermes", "memories", "MEMORY.md"), "w") as f:
            f.write(SEP.join(entries))
    return home


def run(home):
    env = {k: v for k, v in os.environ.items() if k not in ("HERMES_HOME",)}
    env["HOME"] = home
    p = subprocess.run([sys.executable, SCRIPT], env=env, capture_output=True, text=True, timeout=30)
    return p.returncode, p.stdout, p.stderr


def done_lines(home):
    path = os.path.join(home, "jobs", "night-queue-done.txt")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return [l for l in f.read().splitlines() if l and not l.startswith("#")]


# One new entry: printed once, recorded, then the next run prints nothing.
h = setup(["NIGHT: test task, find todays top Hacker News story"])
rc, out, err = run(h)
check("one entry printed", rc == 0 and "find todays top Hacker News story" in out, f"rc={rc} out={out!r} err={err!r}")
check("one entry recorded", done_lines(h) is not None and len(done_lines(h)) == 1, f"done={done_lines(h)}")
rc, out, err = run(h)
check("second run prints nothing", rc == 0 and out == "", f"rc={rc} out={out!r} err={err!r}")
check("second run records nothing new", done_lines(h) is not None and len(done_lines(h)) == 1, f"done={done_lines(h)}")
shutil.rmtree(h)

# No NIGHT entries, and an empty memory file: nothing printed, exit 0.
h = setup(["Casey prefers short answers", "The VM runs qwen"])
rc, out, err = run(h)
check("no night entries prints nothing", rc == 0 and out == "", f"rc={rc} out={out!r} err={err!r}")
shutil.rmtree(h)
h = setup([])
rc, out, err = run(h)
check("empty memory prints nothing", rc == 0 and out == "", f"rc={rc} out={out!r} err={err!r}")
shutil.rmtree(h)

# Memory file missing: loud error, nonzero exit, done list untouched.
h = setup(None)
rc, out, err = run(h)
check("missing memory fails loudly", rc != 0 and "MEMORY.md" in err and out == "", f"rc={rc} out={out!r} err={err!r}")
check("missing memory leaves no done list", done_lines(h) is None, f"done={done_lines(h)}")
shutil.rmtree(h)

# Five new entries: first 3 tonight, the other 2 next run.
h = setup([f"NIGHT: task {i}" for i in range(1, 6)])
rc, out, err = run(h)
check("cap prints first 3", rc == 0 and all(f"task {i}" in out for i in (1, 2, 3)), f"out={out!r}")
check("cap holds back 4 and 5", "task 4" not in out and "task 5" not in out, f"out={out!r}")
check("cap says 2 wait", "2 wait" in out, f"out={out!r}")
rc, out, err = run(h)
check("next run prints 4 and 5", rc == 0 and "task 4" in out and "task 5" in out and "task 1" not in out, f"out={out!r}")
check("all 5 recorded", done_lines(h) is not None and len(done_lines(h)) == 5, f"done={done_lines(h)}")
shutil.rmtree(h)

# Shell metacharacters are printed verbatim and never run.
h = setup(['NIGHT: say "hi" $(touch PWNED) `touch PWNED2` $HOME'])
rc, out, err = run(h)
check("metacharacters verbatim", rc == 0 and '"hi" $(touch PWNED) `touch PWNED2` $HOME' in out, f"out={out!r}")
check("metacharacters not run", not os.path.exists(os.path.join(h, "PWNED")) and not os.path.exists("PWNED"), "a file was created")
shutil.rmtree(h)

# Other memory entries are never printed, and only a leading NIGHT: counts.
h = setup(["Casey lives in Toronto", "NIGHT: real task", "Remember: NIGHT: is the queue prefix"])
rc, out, err = run(h)
check("other entries hidden", rc == 0 and "Toronto" not in out and "queue prefix" not in out and "real task" in out, f"out={out!r}")
shutil.rmtree(h)

# The prefix is matched case-insensitively, since Hermes rewords entries.
h = setup(["Night: lower case task"])
rc, out, err = run(h)
check("prefix case-insensitive", rc == 0 and "lower case task" in out, f"out={out!r}")
shutil.rmtree(h)

# Missing done list (and missing ~/jobs) is created on the first run.
h = setup(["NIGHT: first ever"])
rc, out, err = run(h)
check("done list created", rc == 0 and done_lines(h) is not None, f"rc={rc} err={err!r}")
shutil.rmtree(h)

print(f"passed={passed} failed={failed}")
sys.exit(1 if failed else 0)
