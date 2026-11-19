"""aa_guard: holds every cron job Hermes creates from chat to web tools and Casey's chat.

The cronjob tool forwards the model's own enabled_toolsets, script, workdir and
deliver, and those beat platform_toolsets.cron. Without this guard, qwen (or a
page it read) could schedule a job with terminal that reads ~/.hermes/.env.
Rules: Auto-Agent IMPLEMENT.md Phase 45 (Casey, 2026-11-17, allowlist).
Block format: Hermes v0.22.7 hermes_cli/plugins.py ignores a block without a
non-empty message, so every block carries one.

It also answers "not online" when the router cannot be reached (offline_reply,
IMPLEMENT.md Phase 4, Casey 2026-11-19).
"""
import logging
import os
import urllib.error
import urllib.request

log = logging.getLogger("aa_guard")

# v0.22.7 registered "cronjob"; v0.23.2 registers "cronjob_manage" (toolset "cronjob").
# Both stay guarded, so a rename either way cannot silently turn the guard off.
TOOLS = frozenset({"cronjob", "cronjob_manage"})

# Arguments with no reach beyond the job's own prompt, schedule and bookkeeping.
SAFE = frozenset({
    "action", "job_id", "prompt", "schedule", "name", "repeat", "skills", "skill", "catch_up",
    "context_from", "continuity", "timezone", "attach_to_session", "paused", "paused_reason",
    "pinned", "reason", "include_disabled", "grace_minutes", "wrap_response",
})
ALLOWED_TOOLSETS = (None, [], ["web"])
DELIVERY_KEYS = ("deliver", "failure_deliver")
ALLOWED_DELIVERY = (None, "", "origin", "local")
# Run or read local files. Allowed only when falsy (the model often sends defaults).
LOCAL_KEYS = ("script", "no_agent", "monitor", "monitor_script", "monitor_url", "workdir")
KNOWN = SAFE | {"enabled_toolsets"} | set(DELIVERY_KEYS) | set(LOCAL_KEYS)


def _block(reason):
    return {"action": "block", "message": f"Scheduling blocked by aa_guard: {reason}"}


def guard_cronjob(tool_name="", args=None, **kwargs):
    """pre_tool_call: None to let the call run, a block directive otherwise."""
    del kwargs
    if tool_name not in TOOLS:
        return None
    if not isinstance(args, dict):
        return _block("the arguments were not an object.")
    toolsets = args.get("enabled_toolsets")
    if toolsets not in ALLOWED_TOOLSETS or (toolsets is not None and not isinstance(toolsets, list)):
        return _block("scheduled jobs may only use the web tools. Leave enabled_toolsets unset.")
    for key in DELIVERY_KEYS:
        if args.get(key) not in ALLOWED_DELIVERY:
            return _block(f"{key} must be left unset, so results come back to this chat.")
    for key in LOCAL_KEYS:
        if args.get(key):
            return _block(f"{key} runs or reads local files, which scheduled jobs may not do.")
    for key, value in args.items():
        if key not in KNOWN and value is not None:
            return _block(f"the argument {key!r} is not on the reviewed list.")
    return None


# Offline reply: on the ZBOX the model is reached through a tunnel the PC opens, so the router
# is gone whenever the PC is off. Before each model call, a quick look at the router's /health.
# When nothing answers, the turn ends with fixed text and no model call (pre_llm_call "block",
# Hermes v0.23.2 agent/turn_context.py). Adapted from Friends-Hermes friends_odds, on the ZBOX
# since 2026-11-15.
OFFLINE_TEXT = "Not online right now. The PC is off. Try again later."
# A scheduled run (platform "cron", Hermes v0.23.2 cron/scheduler.py) gets its own wording. Hermes
# delivers a blocked run's message as the job's result under its own header, which names the job.
# The block also pre-empts Hermes's 5, 15 and 30 minute re-runs (cron/unreachable_retry.py): the
# job waits for its next scheduled time (Casey, 2026-11-19).
OFFLINE_JOB_TEXT = "Not online. The PC was off, so this run was skipped."
HEALTH_TIMEOUT = 2
_open = urllib.request.urlopen


def router_reachable(base):
    """False only when the connection fails or times out. Any HTTP answer, even a 503 while the
    router loads a model, means it is there."""
    try:
        with _open(base + "/health", timeout=HEALTH_TIMEOUT):
            return True
    except urllib.error.HTTPError:
        return True
    except (urllib.error.URLError, OSError):
        return False


def offline_reply(platform="", **kwargs):
    """pre_llm_call: block the turn with fixed text when AA_ROUTER_URL is set and unreachable.
    Unset means no check (the VM reaches the router directly)."""
    del kwargs
    url = os.environ.get("AA_ROUTER_URL", "").strip().rstrip("/")
    if not url:
        return None
    base = url[:-3].rstrip("/") if url.endswith("/v1") else url
    # Checked here because urllib reports "127.0.0.1:8080" (no scheme) as a failed connection,
    # and a typo would then read as offline for good.
    if not base.startswith(("http://", "https://")):
        log.warning("AA_ROUTER_URL %r does not start with http:// or https://. Offline check skipped.", url)
        return None
    try:
        up = router_reachable(base)
    except ValueError as e:
        log.warning("AA_ROUTER_URL %r is not a URL (%s). Offline check skipped.", url, e)
        return None
    if up:
        return None
    return {"action": "block", "message": OFFLINE_JOB_TEXT if platform == "cron" else OFFLINE_TEXT}


def register(ctx):
    ctx.register_hook("pre_tool_call", guard_cronjob)
    ctx.register_hook("pre_llm_call", offline_reply)
