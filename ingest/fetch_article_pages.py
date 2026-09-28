"""Fetch the article pages of bank-related sitemap entries, to get their real publish time.

Why: sitemap lastmod is not the publish time (see docs/news_source_survey.md). The page's
article:published_time is. Only articles whose title passes config/news_prefilter.yaml are
fetched (~11k), not all ~246k.

- Candidates: every entry in the downloaded sitemap buckets (the extra bucket on each side is
  included, since lastmod can fall outside the window), title matched against a ticker (whole
  word), a bank name, or a context word. The list is written to _candidates.csv on every run.
- Pages are saved gzip-compressed as raw/news/article_pages/{slug}.html.gz, never overwritten,
  written via a .part file. Parsing publish times is a separate step.
- 404/410 are logged and not retried on the next run. Other errors are retried 3 times with a
  pause, then logged, and the run moves on.
- Every request goes to _fetch_log.csv. Stop any time with Ctrl+C and rerun to continue.

Run from the repository root:
  python ingest/fetch_article_pages.py --dry-run     # only build and count candidates
  python ingest/fetch_article_pages.py --limit 20    # try a few first
  python ingest/fetch_article_pages.py               # everything that is left
"""
import argparse
import csv
import gzip
import html
import re
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml

SITEMAP_DIR = Path("raw/news/sitemaps")
OUT_DIR = Path("raw/news/article_pages")
CANDIDATES = OUT_DIR / "_candidates.csv"
LOG_PATH = OUT_DIR / "_fetch_log.csv"
SLEEP_SECONDS = 2
RETRY_PAUSES = [10, 30, 60]
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; BSI-research-crawler/0.1; personal data project)"}

ENTRY_RE = re.compile(
    r"<url>\s*<loc>([^<]+)</loc>.*?<lastmod>([^<]+)</lastmod>.*?<image:title>(.*?)</image:title>", re.S)


def clean_title(raw: str) -> str:
    t = html.unescape(raw).strip()
    if t.startswith("<![CDATA[") and t.endswith("]]>"):
        t = t[9:-3]
    return t.strip()


def build_matchers():
    with open("config/tickers.yaml", encoding="utf-8") as f:
        tickers = [t["ticker"] for t in yaml.safe_load(f)["tickers"]]
    with open("config/news_prefilter.yaml", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    ticker_re = re.compile(r"\b(" + "|".join(tickers) + r")\b")
    name_re = re.compile("|".join(re.escape(n) for n in cfg["names"]), re.I)
    context_re = re.compile("|".join(re.escape(w) for w in cfg["context_words"]), re.I)
    return ticker_re, name_re, context_re


def build_candidates():
    latest = {}   # url -> (lastmod, title); a URL can sit in two bucket files, keep the latest lastmod
    for path in sorted(SITEMAP_DIR.glob("sitemaps-*.xml")):
        for url, lm, title in ENTRY_RE.findall(path.read_text(encoding="utf-8")):
            url, lm = url.strip(), lm.strip()
            if lm > latest.get(url, ("",))[0]:
                latest[url] = (lm, clean_title(title))

    ticker_re, name_re, context_re = build_matchers()
    rows = []
    for url, (lm, title) in sorted(latest.items()):
        matched = [label for label, rx in (("ticker", ticker_re), ("name", name_re), ("context", context_re))
                   if rx.search(title)]
        if matched:
            rows.append({"url": url, "lastmod": lm, "title": title, "matched_by": "+".join(matched)})
    return len(latest), rows


def page_path(url: str) -> Path:
    return OUT_DIR / (url.rstrip("/").rsplit("/", 1)[1] + ".gz")


def log(url, status, size, file, error=""):
    new_file = not LOG_PATH.exists()
    with open(LOG_PATH, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["fetched_at_utc", "url", "status", "bytes", "file", "error"])
        if new_file:
            w.writeheader()
        w.writerow({"fetched_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                    "url": url, "status": status, "bytes": size, "file": file, "error": error})


def gone_urls() -> set:
    if not LOG_PATH.exists():
        return set()
    with open(LOG_PATH, encoding="utf-8") as f:
        return {r["url"] for r in csv.DictReader(f) if r["status"] in ("404", "410")}


def fetch_one(session, url: str, path: Path) -> str:
    for attempt, pause in enumerate([0] + RETRY_PAUSES):
        if pause:
            time.sleep(pause)
        try:
            resp = session.get(url, headers=HEADERS, timeout=60)
        except requests.RequestException as e:
            log(url, "error", 0, path.as_posix(), repr(e)[:200])
            continue
        log(url, resp.status_code, len(resp.content), path.as_posix())
        if resp.status_code in (404, 410):
            return "gone"
        if resp.status_code == 200:
            part = path.with_name(path.name + ".part")
            part.write_bytes(gzip.compress(resp.content))
            part.replace(path)
            return "saved"
    return "failed"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=None, help="fetch at most N pages this run")
    ap.add_argument("--dry-run", action="store_true", help="build the candidate list only")
    args = ap.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    total, rows = build_candidates()
    with open(CANDIDATES, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["url", "lastmod", "title", "matched_by"])
        w.writeheader()
        w.writerows(rows)

    gone = gone_urls()
    todo = [r for r in rows if not page_path(r["url"]).exists() and r["url"] not in gone]
    print(f"sitemap urls {total}, candidates {len(rows)}, on disk {len(rows) - len(todo) - len(gone & {r['url'] for r in rows})}, "
          f"gone {len(gone)}, to fetch {len(todo)}")
    if args.dry_run:
        return
    if args.limit is not None:
        todo = todo[:args.limit]

    counts = {"saved": 0, "gone": 0, "failed": 0}
    started = time.time()
    with requests.Session() as session:
        for i, r in enumerate(todo, start=1):
            counts[fetch_one(session, r["url"], page_path(r["url"]))] += 1
            if i % 100 == 0 or i == len(todo):
                mins = (time.time() - started) / 60
                print(f"{i}/{len(todo)}  saved {counts['saved']}  gone {counts['gone']}  "
                      f"failed {counts['failed']}  {mins:.0f} min")
            time.sleep(SLEEP_SECONDS)


if __name__ == "__main__":
    main()
