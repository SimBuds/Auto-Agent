#!/usr/bin/env python3
"""Tests for news-collect.py. Run on the host: python3 jobs/test-news-collect.py

No network: the collector reads jobs/fixtures/news/ through --fixtures, and the
HTTP path is tested with a fake fetch. The fixtures are hand-written in the
field shape the live APIs returned on 2026-09-27, with boundary items added.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True  # importing the collector must not leave jobs/__pycache__/
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "news-collect.py")
FIXTURES = os.path.join(HERE, "fixtures", "news")
NOW = "2026-09-27T12:00:00Z"

passed = failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"PASS {name}")
    else:
        failed += 1
        print(f"FAIL {name}: {detail}")


def run(tmp, fixtures=FIXTURES, extra_env=None, use_fixtures=True):
    env = {k: v for k, v in os.environ.items() if not k.startswith("NEWS_")}
    env.update({"NEWS_NOW": NOW, "NEWS_OUT": os.path.join(tmp, "out")})
    env.update(extra_env or {})
    args = [sys.executable, SCRIPT] + (["--fixtures", fixtures] if use_fixtures else [])
    p = subprocess.run(args, env=env, capture_output=True, text=True, timeout=60)
    path = os.path.join(tmp, "out", "candidates-2026-09-27.json")
    data = json.load(open(path)) if os.path.exists(path) else None
    return p, data


def ids(data, source):
    return [i["id"] for i in data["items"] if i["source"] == source]


def copy_fixtures(tmp, **replace):
    d = os.path.join(tmp, "fx")
    shutil.copytree(FIXTURES, d)
    for name, text in replace.items():
        with open(os.path.join(d, name.replace("_", ".")), "w") as f:
            f.write(text)
    return d


# --- happy path and boundaries, through the command line ---
with tempfile.TemporaryDirectory() as tmp:
    p, data = run(tmp)
    check("happy: exit 0", p.returncode == 0, f"rc={p.returncode} err={p.stderr[-400:]}")
    if data:
        counts = {s: v["count"] for s, v in data["sources"].items()}
        check("happy: counts hn 4, hf 2, arxiv 2", counts == {"hn": 4, "hf": 2, "arxiv": 2}, counts)
        need = {"source", "id", "title", "url", "published", "size"}
        check("happy: every item has the fields", all(need <= set(i) for i in data["items"]),
              [sorted(need - set(i)) for i in data["items"]])
        check("hn: sorted by points", ids(data, "hn") == ["hn:49857899", "hn:49858513", "hn:49860001", "hn:49862000"], ids(data, "hn"))
        ask = [i for i in data["items"] if i["id"] == "hn:49860001"]
        check("hn: Ask HN without url links to its HN page",
              ask and ask[0]["url"] == "https://news.ycombinator.com/item?id=49860001", ask)
        check("hn: older than 24 hours dropped", "hn:49850000" not in ids(data, "hn"))
        check("hn: under 50 points dropped", "hn:49861000" not in ids(data, "hn"))
        check("dedupe: a URL in HN and HF appears once, as HN",
              "hf:Qwen/Qwen-Image-2.1" not in ids(data, "hf") and "hn:49862000" in ids(data, "hn"), ids(data, "hf"))
        ax = [i for i in data["items"] if i["source"] == "arxiv"]
        check("arxiv: id without version, https abs url, title on one line",
              ax and ax[0]["id"] == "arxiv:2609.30266"
              and ax[0]["url"] == "https://arxiv.org/abs/2609.30266"
              and ax[0]["title"] == "LLM Agents Can Easily Tamper With Their Own Traces", ax[:1])
        md = os.path.join(tmp, "out", "candidates-2026-09-27.md")
        text = open(md).read() if os.path.exists(md) else ""
        check("markdown: lists every item id and title",
              text and all(i["id"] in text and i["title"] in text for i in data["items"]))
        check("markdown: an HF model's total parameters, from the API or its name",
              "### hf:convaiinnovations/laya" in text and "- Params: 0.4B" in text
              and "- Params: 35.0B" in text, text[-900:])
        check("markdown: only HF items get a Params line",
              text.count("- Params: ") == 2, text.count("- Params: "))
    else:
        check("happy: candidates JSON written", False, p.stderr[-400:])

with tempfile.TemporaryDirectory() as tmp:
    p, data = run(tmp, extra_env={"NEWS_HN_LIMIT": "2"})
    check("limit: NEWS_HN_LIMIT=2 keeps the top 2",
          data is not None and ids(data, "hn") == ["hn:49857899", "hn:49858513"], data and ids(data, "hn"))

with tempfile.TemporaryDirectory() as tmp:
    p, data = run(tmp, fixtures=copy_fixtures(tmp, hf_json="[]"))
    check("zero items: exit 0, hf listed with 0, file written",
          p.returncode == 0 and data is not None and data["sources"]["hf"]["count"] == 0
          and data["sources"]["hf"]["status"] == "ok", (p.returncode, data and data["sources"]))

with tempfile.TemporaryDirectory() as tmp:
    p, data = run(tmp, fixtures=copy_fixtures(tmp, hn_json="<html>502 Bad Gateway</html>"))
    ok = (p.returncode == 3 and data is not None
          and data["sources"]["hn"]["status"].startswith("FAILED")
          and data["sources"]["hf"]["count"] == 3 and data["sources"]["arxiv"]["count"] == 2)
    check("failed source: exit 3, named FAILED, others still collected", ok,
          (p.returncode, data and data["sources"]))
    md = os.path.join(tmp, "out", "candidates-2026-09-27.md")
    check("failed source: FAILED shown in the markdown",
          os.path.exists(md) and "FAILED" in open(md).read())

with tempfile.TemporaryDirectory() as tmp:
    p, data = run(tmp, use_fixtures=False)
    check("NEWS_CONTACT unset: exit 1 before any request",
          p.returncode == 1 and "NEWS_CONTACT" in p.stderr and not os.path.exists(os.path.join(tmp, "out")),
          (p.returncode, p.stderr[-300:]))

# --- the HTTP path, with a fake fetch ---
with tempfile.TemporaryDirectory() as tmp:
    os.environ["NEWS_OUT"] = os.path.join(tmp, "out")
    spec = importlib.util.spec_from_file_location("news_collect", SCRIPT)
    nc = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(nc)
    except FileNotFoundError as e:
        nc = None
        check("module loads", False, e)
    if nc:
        nc.sleep = lambda s: None

        def fake(responses):
            calls = []

            def fetch(url):
                calls.append(url)
                return responses[min(len(calls), len(responses)) - 1]
            return fetch, calls

        fetch, calls = fake([(200, b"body")])
        first = nc.get("https://example.com/a", fetch)
        second = nc.get("https://example.com/a", fetch)
        check("cache: a second get within the TTL makes no request",
              first == second == b"body" and len(calls) == 1, calls)

        fetch, calls = fake([(503, b""), (503, b""), (200, b"late")])
        check("backoff: 503, 503, then 200 returns the body after 3 tries",
              nc.get("https://example.com/b", fetch) == b"late" and len(calls) == 3, calls)

        fetch, calls = fake([(429, b"")])
        try:
            nc.get("https://example.com/c", fetch)
            check("backoff: 429 every time fails after 3 tries", False, "no error")
        except nc.SourceError as e:
            check("backoff: 429 every time fails after 3 tries", len(calls) == 3 and "429" in str(e), (calls, e))

        fetch, calls = fake([(404, b"")])
        try:
            nc.get("https://example.com/d", fetch)
            check("404: fails at once", False, "no error")
        except nc.SourceError as e:
            check("404: fails at once", len(calls) == 1 and "404" in str(e), (calls, e))

        # The HN url carries the window's start. Found live 2026-09-27: to the
        # second, it changed every run, so HN was never read from the cache.
        from datetime import datetime, timezone
        urls = []

        def record(url):
            urls.append(url)
            return b'{"hits": []}'
        nc.fetch_hn(record, datetime(2026, 9, 27, 12, 5, 10, tzinfo=timezone.utc))
        nc.fetch_hn(record, datetime(2026, 9, 27, 12, 40, 55, tzinfo=timezone.utc))
        check("hn: the request url is the same within one hour, so the cache can hit",
              len(urls) == 2 and urls[0] == urls[1], urls)

        # Total parameters, so the rating script can tell an LLM that fits this
        # machine from one that does not. Shapes from the live API, 2026-09-30.
        def pb(m):
            try:
                v = nc.params_b(m)
            except Exception as e:
                return f"raised {e!r}"
            return None if v is None else round(v, 1)
        for name, model, want in [
            ("safetensors total only", {"id": "Qwen/Qwen3.8", "safetensors": {"total": 27781427952}}, 27.8),
            ("gguf total only", {"id": "a/b-gguf", "gguf": {"total": 26895998464}}, 26.9),
            ("both, the larger wins", {"id": "a/b", "safetensors": {"total": 6770790400}, "gguf": {"total": 26895998464}}, 26.9),
            ("name only", {"id": "XiaomiMiMo/MiMo-V2.6-Distill-Qwen-9B"}, 9.0),
            ("no count anywhere", {"id": "Altworld/Hemmingway-1"}, None),
            ("packed quant: the name's 27B beats 6.77B", {"id": "orcarouter/OrcaSAQ-2-27B", "safetensors": {"total": 6770790400}}, 27.0),
            ("29B-A4B gives 29, not the active 4", {"id": "XingChen-AGI/Xing4.0-29B-A4B"}, 29.0),
            ("Qwen3.8-27B gives 27, not 3.8", {"id": "Qwen/Qwen3.8-27B"}, 27.0),
            ("an active size alone is not a total", {"id": "a/Mixer-A4B"}, None),
            ("malformed values are ignored", {"id": "a/b", "safetensors": "oops", "gguf": {"total": "n/a"}}, None),
            ("under 1B", {"id": "convaiinnovations/laya", "safetensors": {"total": 421293830}}, 0.4),
        ]:
            got = pb(model)
            check(f"params: {name}", got == want, f"got {got}, want {want}")

        urls = []
        nc.fetch_hf(lambda url: urls.append(url) or b"[]", datetime(2026, 9, 30, 12, tzinfo=timezone.utc))
        need = ["safetensors", "gguf", "likes", "downloads", "createdAt", "trendingScore", "pipeline_tag"]
        check("hf: the request expands every field it reads (expand replaces the defaults)",
              urls and all(f"expand%5B%5D={f}" in urls[0] for f in need), urls)

        waits = []
        nc.sleep = waits.append
        nc._last_request.clear()
        fetch, calls = fake([(200, b"x")])
        nc.get("https://export.arxiv.org/api/query?a=1", fetch)
        nc.get("https://export.arxiv.org/api/query?a=2", fetch)
        check("arxiv: a second request waits about 3 seconds (its API terms)",
              len(calls) == 2 and waits and waits[-1] > 2.9, waits)
        nc.sleep = lambda s: None

        seen_ua = []

        class FakeResponse:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return b"ok"
        real_urlopen = nc.urllib.request.urlopen
        nc.urllib.request.urlopen = lambda req, timeout: seen_ua.append(req.get_header("User-agent")) or FakeResponse()
        try:
            nc.http_fetch("https://example.com/ua", "someone@example.com")
        finally:
            nc.urllib.request.urlopen = real_urlopen
        check("user agent: names the tool and carries NEWS_CONTACT",
              seen_ua and "news-collect" in seen_ua[0] and "someone@example.com" in seen_ua[0], seen_ua)

print(f"passed={passed} failed={failed}")
sys.exit(1 if failed else 0)
