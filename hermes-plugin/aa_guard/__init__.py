"""aa_guard: holds every cron job Hermes creates from chat to web tools and Casey's chat.

The cronjob tool forwards the model's own enabled_toolsets, script, workdir and
deliver, and those beat platform_toolsets.cron. Without this guard, qwen (or a
page it read) could schedule a job with terminal that reads ~/.hermes/.env.
Rules: Auto-Agent IMPLEMENT.md Phase 45 (Casey, 2026-11-17, allowlist).
Block format: Hermes v0.22.7 hermes_cli/plugins.py ignores a block without a
non-empty message, so every block carries one.
"""

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


def register(ctx):
    ctx.register_hook("pre_tool_call", guard_cronjob)
