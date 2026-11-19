#!/usr/bin/env python3
"""Tests for the aa_guard Hermes plugin. No Hermes, no network.

    python3 hermes-plugin/test_aa_guard.py

Written from the Phase 45 rules in IMPLEMENT.md before the plugin. A block
must carry a non-empty message, because Hermes v0.22.7 ignores one without.
"""
import contextlib
import importlib.util
import os
import socket
import time
import unittest
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))


def load_plugin():
    spec = importlib.util.spec_from_file_location("aa_guard", os.path.join(HERE, "aa_guard", "__init__.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeCtx:
    def __init__(self):
        self.hooks = {}
        self.tools = {}

    def register_hook(self, name, callback, **kw):
        self.hooks.setdefault(name, []).append(callback)

    def register_tool(self, *a, **kw):
        self.tools[kw.get("name")] = (a, kw)


class Base(unittest.TestCase):
    def setUp(self):
        self.p = load_plugin()

    def call(self, args, tool="cronjob"):
        return self.p.guard_cronjob(tool_name=tool, args=args, task_id="t1", session_id="s1")

    def assertBlocked(self, args, tool="cronjob"):
        r = self.call(args, tool)
        self.assertIsInstance(r, dict, f"not blocked: {args!r}")
        self.assertEqual(r.get("action"), "block")
        self.assertIsInstance(r.get("message"), str)
        self.assertTrue(r["message"].strip(), "a block needs a non-empty message")

    def assertAllowed(self, args, tool="cronjob"):
        self.assertIsNone(self.call(args, tool), f"blocked: {args!r}")


CREATE = {"action": "create", "schedule": "every day at 8am", "prompt": "Top llama.cpp news, with links."}


class TestRegister(Base):
    def test_register_adds_the_cron_guard_and_the_offline_reply_and_nothing_else(self):
        ctx = FakeCtx()
        self.p.register(ctx)
        self.assertEqual(sorted(ctx.hooks), ["pre_llm_call", "pre_tool_call"])
        self.assertEqual(ctx.hooks["pre_tool_call"], [self.p.guard_cronjob])
        self.assertEqual(ctx.hooks["pre_llm_call"], [self.p.offline_reply])
        self.assertEqual(ctx.tools, {})

    def test_plugin_yaml_declares_both_hooks(self):
        with open(os.path.join(HERE, "aa_guard", "plugin.yaml")) as f:
            lines = [line.strip() for line in f]
        self.assertIn("- pre_tool_call", lines)
        self.assertIn("- pre_llm_call", lines)


class TestToolsets(Base):
    def test_create_with_no_toolsets_allowed(self):
        self.assertAllowed(dict(CREATE))

    def test_toolsets_none_allowed(self):
        self.assertAllowed({**CREATE, "enabled_toolsets": None})

    def test_web_only_allowed(self):
        self.assertAllowed({**CREATE, "enabled_toolsets": ["web"]})

    def test_empty_list_allowed(self):
        self.assertAllowed({**CREATE, "enabled_toolsets": []})

    def test_web_and_terminal_blocked(self):
        self.assertBlocked({**CREATE, "enabled_toolsets": ["web", "terminal"]})

    def test_terminal_blocked(self):
        self.assertBlocked({**CREATE, "enabled_toolsets": ["terminal"]})

    def test_string_instead_of_list_blocked(self):
        self.assertBlocked({**CREATE, "enabled_toolsets": "web"})

    def test_case_variant_blocked(self):
        self.assertBlocked({**CREATE, "enabled_toolsets": ["Web"]})

    def test_update_adding_toolsets_blocked(self):
        self.assertBlocked({"action": "update", "job_id": "abc123", "enabled_toolsets": ["file"]})


class TestDelivery(Base):
    def test_origin_and_local_allowed(self):
        for v in ("origin", "local", "", None):
            self.assertAllowed({**CREATE, "deliver": v})
            self.assertAllowed({**CREATE, "failure_deliver": v})

    def test_other_targets_blocked(self):
        for v in ("all", "telegram:123:4", "origin,all", "bot-chat", "room:x", "discord"):
            self.assertBlocked({**CREATE, "deliver": v})
            self.assertBlocked({**CREATE, "failure_deliver": v})

    def test_non_string_deliver_blocked(self):
        self.assertBlocked({**CREATE, "deliver": ["origin"]})


class TestLocalExecution(Base):
    def test_risky_keys_set_blocked(self):
        for k, v in (("script", "x.py"), ("no_agent", True), ("monitor", "https://example.com"),
                     ("monitor_script", "m.py"), ("monitor_url", "https://example.com"),
                     ("workdir", "/home/hermes")):
            self.assertBlocked({**CREATE, k: v})

    def test_risky_keys_falsy_allowed(self):
        for k, v in (("script", ""), ("no_agent", False), ("monitor", None), ("monitor_script", ""),
                     ("monitor_url", None), ("workdir", "")):
            self.assertAllowed({**CREATE, k: v})


class TestUnknownAndShape(Base):
    def test_unknown_key_set_blocked(self):
        self.assertBlocked({**CREATE, "sandbox": False})

    def test_unknown_key_none_allowed(self):
        self.assertAllowed({**CREATE, "sandbox": None})

    def test_safe_fields_allowed(self):
        self.assertAllowed({**CREATE, "name": "news", "repeat": 3, "skills": ["research"], "catch_up": True,
                            "context_from": ["j1"], "continuity": True, "timezone": "America/New_York",
                            "attach_to_session": True, "paused": False, "pinned": False, "grace_minutes": 30})

    def test_list_and_remove_allowed(self):
        self.assertAllowed({"action": "list"})
        self.assertAllowed({"action": "remove", "job_id": "abc123"})

    def test_non_dict_args_blocked(self):
        self.assertBlocked(None)
        self.assertBlocked(["create"])

    def test_v0232_tool_name_is_guarded(self):
        """v0.23.2 registers the tool as cronjob_manage; the guard must not fail open on it."""
        self.assertBlocked({**CREATE, "enabled_toolsets": ["terminal"]}, tool="cronjob_manage")
        self.assertAllowed(dict(CREATE), tool="cronjob_manage")

    def test_wrap_response_allowed(self):
        """v0.23.2 adds wrap_response (header and footer on delivered output only)."""
        self.assertAllowed({**CREATE, "wrap_response": False})
        self.assertAllowed({**CREATE, "wrap_response": True}, tool="cronjob_manage")

    def test_other_tools_untouched(self):
        self.assertAllowed({"enabled_toolsets": ["terminal"], "script": "x"}, tool="web_search")
        self.assertAllowed(None, tool="memory")


ROUTER = "http://127.0.0.1:8080"


class TestOffline(Base):
    """pre_llm_call: with the router unreachable, the turn ends with fixed text and no model call.
    Written from IMPLEMENT.md Phase 4 (2026-11-19). Keyword arguments are the ones Hermes v0.23.2
    passes (agent/turn_context.py, _collect_pre_llm_call_context)."""

    def setUp(self):
        super().setUp()
        saved = os.environ.pop("AA_ROUTER_URL", None)
        self.addCleanup(lambda: os.environ.pop("AA_ROUTER_URL", None) if saved is None
                        else os.environ.__setitem__("AA_ROUTER_URL", saved))

    def hook(self, **kw):
        args = dict(session_id="s", task_id="t", turn_id="t1", user_message="hi", conversation_history=[],
                    is_first_turn=True, model="freedom", platform="telegram", parent_session_id="", sender_id="1")
        args.update(kw)
        return self.p.offline_reply(**args)

    def opener(self, outcome):
        seen = []

        def fake(url, timeout=None):
            seen.append((url, timeout))
            if isinstance(outcome, BaseException):
                raise outcome
            return contextlib.nullcontext(None)
        self.p._open = fake
        return seen

    def assertOffline(self, result):
        self.assertEqual(result, {"action": "block", "message": self.p.OFFLINE_TEXT})

    def test_text_is_the_agreed_one(self):
        self.assertEqual(self.p.OFFLINE_TEXT, "Not online right now. The PC is off. Try again later.")

    def test_router_up_lets_the_turn_through_after_one_health_check(self):
        os.environ["AA_ROUTER_URL"] = ROUTER
        seen = self.opener(None)
        self.assertIsNone(self.hook())
        self.assertEqual(seen, [(ROUTER + "/health", 2)])

    def test_connection_refused_blocks_with_the_text(self):
        os.environ["AA_ROUTER_URL"] = ROUTER
        self.opener(urllib.error.URLError(ConnectionRefusedError(111, "Connection refused")))
        self.assertOffline(self.hook())

    def test_timeout_blocks(self):
        os.environ["AA_ROUTER_URL"] = ROUTER
        self.opener(TimeoutError("timed out"))
        self.assertOffline(self.hook())

    def test_http_error_counts_as_up(self):
        """A 503 while the router swaps models is a busy router, not an absent one."""
        os.environ["AA_ROUTER_URL"] = ROUTER
        self.opener(urllib.error.HTTPError(ROUTER + "/health", 503, "Loading model", {}, None))
        self.assertIsNone(self.hook())

    def test_unset_or_blank_means_no_check_and_no_request(self):
        for value in (None, "", "   "):
            if value is not None:
                os.environ["AA_ROUTER_URL"] = value
            seen = self.opener(urllib.error.URLError("must not be asked"))
            self.assertIsNone(self.hook())
            self.assertEqual(seen, [])

    def test_v1_suffix_and_trailing_slash_are_stripped(self):
        for value in (ROUTER + "/v1", ROUTER + "/v1/", ROUTER + "/"):
            os.environ["AA_ROUTER_URL"] = value
            seen = self.opener(None)
            self.assertIsNone(self.hook())
            self.assertEqual(seen, [(ROUTER + "/health", 2)], value)

    def test_a_value_urllib_rejects_is_logged_and_skips_the_check(self):
        os.environ["AA_ROUTER_URL"] = "http://[not-an-address"
        self.opener(ValueError("Invalid IPv6 URL"))
        with self.assertLogs("aa_guard", level="WARNING") as logs:
            self.assertIsNone(self.hook())
        self.assertIn("AA_ROUTER_URL", logs.output[0])

    def test_real_values_that_are_not_urls_skip_the_check_and_never_read_as_offline(self):
        """No fake opener: "127.0.0.1:8080" makes urllib raise URLError, which would read as offline."""
        for value in ("127.0.0.1:8080", "localhost", "http://[not-an-address", "ftp://127.0.0.1:8080"):
            os.environ["AA_ROUTER_URL"] = value
            with self.assertLogs("aa_guard", level="WARNING") as logs:
                self.assertIsNone(self.hook(), value)
            self.assertIn("AA_ROUTER_URL", logs.output[0])

    def test_real_closed_port_is_offline_fast(self):
        with socket.socket() as sock:  # find a free port, then close it so nothing listens there
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        os.environ["AA_ROUTER_URL"] = f"http://127.0.0.1:{port}"
        start = time.monotonic()
        self.assertOffline(self.hook())
        self.assertLess(time.monotonic() - start, 2.5)

    def test_job_text_is_the_agreed_one(self):
        self.assertEqual(self.p.OFFLINE_JOB_TEXT, "Not online. The PC was off, so this run was skipped.")

    def test_scheduled_run_with_the_router_down_gets_the_job_text(self):
        """Hermes v0.23.2 builds the cron agent with platform="cron" (cron/scheduler.py) and delivers
        a blocked turn's message as the job's result, under its own header naming the job."""
        os.environ["AA_ROUTER_URL"] = ROUTER
        self.opener(urllib.error.URLError(ConnectionRefusedError(111, "Connection refused")))
        self.assertEqual(self.hook(platform="cron"), {"action": "block", "message": self.p.OFFLINE_JOB_TEXT})

    def test_scheduled_run_with_the_router_up_runs(self):
        os.environ["AA_ROUTER_URL"] = ROUTER
        seen = self.opener(None)
        self.assertIsNone(self.hook(platform="cron"))
        self.assertEqual(seen, [(ROUTER + "/health", 2)])

    def test_every_other_platform_keeps_the_chat_text(self):
        os.environ["AA_ROUTER_URL"] = ROUTER
        self.opener(TimeoutError("timed out"))
        for platform in ("telegram", "cli", "", None, "subagent", "cron2"):
            self.assertOffline(self.hook(platform=platform))

    def test_platform_missing_from_the_arguments_keeps_the_chat_text(self):
        os.environ["AA_ROUTER_URL"] = ROUTER
        self.opener(TimeoutError("timed out"))
        self.assertOffline(self.p.offline_reply(user_message="hi"))

    def test_scheduled_run_with_the_check_switched_off_runs(self):
        seen = self.opener(urllib.error.URLError("must not be asked"))
        self.assertIsNone(self.hook(platform="cron"))
        self.assertEqual(seen, [])

    def test_unknown_keyword_arguments_are_accepted(self):
        os.environ["AA_ROUTER_URL"] = ROUTER
        self.opener(None)
        self.assertIsNone(self.hook(something_a_later_hermes_adds=1))


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=1).result
    failed = len(result.failures) + len(result.errors)
    print(f"passed={result.testsRun - failed} failed={failed}")
    raise SystemExit(1 if failed else 0)
