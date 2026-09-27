#!/usr/bin/env python3
"""Collect recent AI, tech and programming items for the news digest.

Runs on the host, never in the VM:
    NEWS_CONTACT='you@example.com' python3 jobs/news-collect.py

Writes out/news/candidates-DATE.json (kept as history for trends) and
candidates-DATE.md (what Hermes rates). Sources are public, keyless APIs
whose terms allow this use, checked 2026-09-27 (PLAN.md, Good fits #6):
Hacker News through Algolia, Hugging Face trending models, and arXiv.
Lobsters is left out: its robots.txt disallows all clients and declares
ai-input=no.

Each item keeps its source's own numbers. Nothing is blended into a score.
Exit 0 when every source worked, 3 when any failed (it is named FAILED in
the file and the rest are still written), 1 when NEWS_CONTACT is unset.
"""
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone


def env_int(name, default):
    return int(os.environ.get(name, default))


OUT_DIR = os.environ.get("NEWS_OUT", "out/news")
CACHE_DIR = os.path.join(OUT_DIR, "cache")
CACHE_TTL = env_int("NEWS_CACHE_TTL", 3600)
HN_HOURS = env_int("NEWS_HN_HOURS", 24)
HN_MIN_POINTS = env_int("NEWS_HN_MIN_POINTS", 50)
HN_LIMIT = env_int("NEWS_HN_LIMIT", 40)
HF_LIMIT = env_int("NEWS_HF_LIMIT", 15)
ARXIV_LIMIT = env_int("NEWS_ARXIV_LIMIT", 20)
ARXIV_CATS = os.environ.get("NEWS_ARXIV_CATS", "cs.AI cs.CL cs.LG cs.SE").split()
# arXiv's API terms: no more than one request every three seconds.
HOST_DELAY = {"export.arxiv.org": 3.0}
DEFAULT_DELAY = 1.0
RETRIES = 3
TIMEOUT = 20
USER_AGENT = "Auto-Agent news-collect/1 (personal digest; contact: {contact})"

sleep = time.sleep
_last_request = {}


class SourceError(Exception):
    """A source could not be read. Its name and the reason go in the file."""


def log(msg):
    print(f"{time.time():.1f} {msg}", file=sys.stderr)


def http_fetch(url, contact):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT.format(contact=contact)})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b""
    except (urllib.error.URLError, TimeoutError) as e:
        raise SourceError(f"{urllib.parse.urlsplit(url).hostname}: {e}") from e


def get(url, fetch):
    """The one HTTP path: cache, per-host spacing, backoff on 429 and 5xx."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    cached = os.path.join(CACHE_DIR, hashlib.sha256(url.encode()).hexdigest())
    if os.path.exists(cached) and time.time() - os.path.getmtime(cached) < CACHE_TTL:
        log(f"cache {url}")
        with open(cached, "rb") as f:
            return f.read()
    host = urllib.parse.urlsplit(url).hostname
    status = None
    for attempt in range(1, RETRIES + 1):
        wait = HOST_DELAY.get(host, DEFAULT_DELAY) - (time.monotonic() - _last_request.get(host, -1e9))
        if wait > 0:
            sleep(wait)
        _last_request[host] = time.monotonic()
        log(f"GET {url} (try {attempt})")
        status, body = fetch(url)
        if status == 200:
            with open(cached, "wb") as f:
                f.write(body)
            return body
        if status == 429 or status >= 500:
            log(f"{host} answered {status}")
            if attempt < RETRIES:
                sleep(2 ** attempt)
            continue
        raise SourceError(f"{host} answered HTTP {status}")
    raise SourceError(f"{host} still answered HTTP {status} after {RETRIES} tries")


def parse_time(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def fetch_hn(read, now):
    # Rounded down to the hour so the request url, and so the cache key, holds
    # for a whole cache period. To the second, every run missed the cache.
    since = (now - timedelta(hours=HN_HOURS)).replace(minute=0, second=0, microsecond=0)
    query = urllib.parse.urlencode({
        "tags": "story",
        "numericFilters": f"created_at_i>{int(since.timestamp())},points>={HN_MIN_POINTS}",
        "hitsPerPage": 100,
    })
    try:
        hits = json.loads(read("https://hn.algolia.com/api/v1/search?" + query))["hits"]
    except (ValueError, KeyError, TypeError) as e:
        raise SourceError(f"hn.algolia.com: unreadable response ({e})") from e
    items = []
    for h in hits:
        published = parse_time(h["created_at"])
        points = h.get("points") or 0
        if published < since or points < HN_MIN_POINTS:
            continue
        page = f"https://news.ycombinator.com/item?id={h['objectID']}"
        items.append({
            "source": "hn", "id": f"hn:{h['objectID']}", "title": h["title"],
            "url": h.get("url") or page, "discussion": page,
            "published": published.isoformat(),
            "size": {"points": points, "comments": h.get("num_comments") or 0},
        })
    items.sort(key=lambda i: i["size"]["points"], reverse=True)
    return items[:HN_LIMIT]


def fetch_hf(read, now):
    query = urllib.parse.urlencode({"sort": "trendingScore", "limit": HF_LIMIT})
    try:
        models = json.loads(read("https://huggingface.co/api/models?" + query))
        return [{
            "source": "hf", "id": f"hf:{m['id']}", "title": m["id"],
            "url": f"https://huggingface.co/{m['id']}",
            "published": m.get("createdAt", ""), "kind": m.get("pipeline_tag") or "",
            "size": {"trending": m.get("trendingScore") or 0, "likes": m.get("likes") or 0,
                     "downloads": m.get("downloads") or 0},
        } for m in models][:HF_LIMIT]
    except (ValueError, KeyError, TypeError) as e:
        raise SourceError(f"huggingface.co: unreadable response ({e})") from e


def fetch_arxiv(read, now):
    query = urllib.parse.urlencode({
        "search_query": " OR ".join(f"cat:{c}" for c in ARXIV_CATS),
        "sortBy": "submittedDate", "sortOrder": "descending", "max_results": ARXIV_LIMIT,
    })
    ns = {"a": "http://www.w3.org/2005/Atom", "arxiv": "http://arxiv.org/schemas/atom"}
    try:
        root = ET.fromstring(read("https://export.arxiv.org/api/query?" + query))
        items = []
        for e in root.findall("a:entry", ns):
            abs_id = e.find("a:id", ns).text.rsplit("/abs/", 1)[1].split("v")[0]
            cat = e.find("arxiv:primary_category", ns)
            items.append({
                "source": "arxiv", "id": f"arxiv:{abs_id}",
                "title": " ".join(e.find("a:title", ns).text.split()),
                "url": f"https://arxiv.org/abs/{abs_id}",
                "published": e.find("a:published", ns).text,
                "kind": cat.get("term") if cat is not None else "", "size": {},
            })
        return items[:ARXIV_LIMIT]
    except (ET.ParseError, AttributeError, IndexError) as e:
        raise SourceError(f"export.arxiv.org: unreadable response ({e})") from e


SOURCES = [("hn", fetch_hn, "hn.json"), ("hf", fetch_hf, "hf.json"), ("arxiv", fetch_arxiv, "arxiv.xml")]


def url_key(url):
    return url.replace("http://", "https://", 1).rstrip("/")


def write_candidates(now, sources, items):
    os.makedirs(OUT_DIR, exist_ok=True)
    stem = os.path.join(OUT_DIR, f"candidates-{now:%Y-%m-%d}")
    with open(stem + ".json", "w") as f:
        json.dump({"generated": now.isoformat(), "sources": sources, "items": items}, f, indent=1)
    lines = [f"# News candidates {now:%Y-%m-%d}", "", "## Sources", ""]
    lines += [f"- {name}: {s['count']} items" if s["status"] == "ok" else f"- {name}: {s['status']}"
              for name, s in sources.items()]
    lines += ["", "## Items"]
    for i in items:
        size = ", ".join(f"{k} {v}" for k, v in i["size"].items()) or "none"
        lines += ["", f"### {i['id']}", "", f"- Title: {i['title']}", f"- URL: {i['url']}"]
        if i.get("discussion") and i["discussion"] != i["url"]:
            lines.append(f"- Discussion: {i['discussion']}")
        if i.get("kind"):
            lines.append(f"- Kind: {i['kind']}")
        lines += [f"- Published: {i['published']}", f"- Size: {size}"]
    with open(stem + ".md", "w") as f:
        f.write("\n".join(lines) + "\n")
    return stem


def main(argv):
    fixtures = argv[argv.index("--fixtures") + 1] if "--fixtures" in argv else None
    contact = os.environ.get("NEWS_CONTACT", "").strip()
    if not fixtures and not contact:
        print("ERROR: set NEWS_CONTACT to a contact address for the User-Agent. "
              "Nothing was fetched.", file=sys.stderr)
        return 1
    now = parse_time(os.environ["NEWS_NOW"]) if os.environ.get("NEWS_NOW") else datetime.now(timezone.utc)
    sources, items, seen = {}, [], set()
    for name, fetch_source, fixture in SOURCES:
        if fixtures:
            def read(url, path=os.path.join(fixtures, fixture)):
                with open(path, "rb") as f:
                    return f.read()
        else:
            def read(url):
                return get(url, lambda u: http_fetch(u, contact))
        try:
            found = [i for i in fetch_source(read, now) if url_key(i["url"]) not in seen]
        except SourceError as e:
            log(f"FAILED {name}: {e}")
            sources[name] = {"count": 0, "status": f"FAILED: {e}"}
            continue
        seen.update(url_key(i["url"]) for i in found)
        items += found
        sources[name] = {"count": len(found), "status": "ok"}
    stem = write_candidates(now, sources, items)
    print(f"{stem}.md: " + ", ".join(f"{n} {s['count'] if s['status'] == 'ok' else 'FAILED'}"
                                     for n, s in sources.items()))
    return 3 if any(s["status"] != "ok" for s in sources.values()) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
