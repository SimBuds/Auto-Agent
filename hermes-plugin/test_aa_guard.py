#!/usr/bin/env python3
"""Tests for the aa_guard Hermes plugin. No Hermes, no network.

    python3 hermes-plugin/test_aa_guard.py

Written from the Phase 45 rules in IMPLEMENT.md before the plugin. A block
must carry a non-empty message, because Hermes v0.22.7 ignores one without.
"""
import importlib.util
import os
import unittest

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
    def test_register_adds_only_the_pre_tool_call_hook(self):
        ctx = FakeCtx()
        self.p.register(ctx)
        self.assertEqual(list(ctx.hooks), ["pre_tool_call"])
        self.assertEqual(ctx.hooks["pre_tool_call"], [self.p.guard_cronjob])
        self.assertEqual(ctx.tools, {})


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


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=1).result
    failed = len(result.failures) + len(result.errors)
    print(f"passed={result.testsRun - failed} failed={failed}")
    raise SystemExit(1 if failed else 0)
