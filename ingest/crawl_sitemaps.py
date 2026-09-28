"""Download CafeF's 5-day archive sitemaps that cover the analysis window.

Saves each file as-is to raw/news/sitemaps/. Parsing into the database is a separate step.

- Bucket files are picked from the sitemap index, not guessed: every file named
  sitemaps-{year}-{month}-{d1}-{d2}.xml whose date range overlaps the window, plus one extra
  bucket on each side (the file name doesn't always match the lastmod dates inside).
- Never overwrites a saved file. A download goes to a .part file first and is renamed only
  after it is complete, so an interrupted run never leaves a half file that looks finished.
- A file without a closing </urlset> tag is treated as truncated and not saved.
- Every request is appended to raw/news/sitemaps/_fetch_log.csv.

Run from the repository root:  python ingest/crawl_sitemaps.py
"""
import csv
import re
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import requests
import yaml

INDEX_URL = "https://cafef.vn/sitemap.xml"
OUT_DIR = Path("raw/news/sitemaps")
LOG_PATH = OUT_DIR / "_fetch_log.csv"
SLEEP_SECONDS = 2
EXTRA_BUCKETS = 1
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; BSI-research-crawler/0.1; personal data project)"}

BUCKET_RE = re.compile(r"/sitemaps-(\d{4})-(\d{1,2})-(\d{1,2})-(\d{1,2})\.xml$")
LOC_RE = re.compile(r"<loc>\s*([^<\s]+)\s*</loc>")


def load_window():
    with open("config/scope.yaml", encoding="utf-8") as f:
        w = yaml.safe_load(f)["window"]
    return w["start_date"], w["end_date"]


def log_request(url, status, size, file):
    new_file = not LOG_PATH.exists()
    with open(LOG_PATH, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["fetched_at_utc", "url", "status", "bytes", "file"])
        if new_file:
            w.writeheader()
        w.writerow({"fetched_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                    "url": url, "status": status, "bytes": size, "file": file})


def fetch_to_file(session, url: str, path: Path) -> None:
    resp = session.get(url, headers=HEADERS, timeout=120)
    log_request(url, resp.status_code, len(resp.content), path.as_posix())
    resp.raise_for_status()
    if path.suffix == ".xml" and b"</urlset>" not in resp.content and b"</sitemapindex>" not in resp.content:
        raise RuntimeError(f"{url}: no closing tag, response looks truncated")
    part = path.with_name(path.name + ".part")
    part.write_bytes(resp.content)
    part.replace(path)          # rename only after the whole file is on disk


def select_buckets(index_xml: str, start: date, end: date) -> list[tuple[date, date, str]]:
    buckets = []
    for url in LOC_RE.findall(index_xml):
        m = BUCKET_RE.search(url)
        if m:
            y, mo, d1, d2 = map(int, m.groups())
            buckets.append((date(y, mo, d1), date(y, mo, d2), url))
    buckets.sort()
    inside = [i for i, (b1, b2, _) in enumerate(buckets) if b1 <= end and b2 >= start]
    if not inside:
        raise SystemExit("No bucket overlaps the window - check the index file")
    lo = max(inside[0] - EXTRA_BUCKETS, 0)
    hi = min(inside[-1] + EXTRA_BUCKETS, len(buckets) - 1)
    chosen = buckets[lo:hi + 1]
    # Buckets must follow each other with no gap, otherwise the index is missing a file.
    for (a1, a2, _), (b1, b2, _) in zip(chosen, chosen[1:]):
        if b1 != a2 + timedelta(days=1):
            raise SystemExit(f"Gap in bucket list between {a2} and {b1}")
    return chosen


def main():
    start, end = load_window()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with requests.Session() as session:
        # Keep one snapshot of the index; the index itself changes every day.
        index_path = OUT_DIR / "_sitemap_index.xml"
        if not index_path.exists():
            fetch_to_file(session, INDEX_URL, index_path)
            time.sleep(SLEEP_SECONDS)
        chosen = select_buckets(index_path.read_text(encoding="utf-8"), start, end)
        print(f"{len(chosen)} bucket files, {chosen[0][0]} -> {chosen[-1][1]}")

        done = skipped = 0
        for _, _, url in chosen:
            path = OUT_DIR / url.rsplit("/", 1)[1]
            if path.exists():
                skipped += 1
                continue
            fetch_to_file(session, url, path)
            done += 1
            print(f"{path.name:32} {path.stat().st_size:>10,} bytes")
            time.sleep(SLEEP_SECONDS)
        print(f"downloaded {done}, already on disk {skipped}")


if __name__ == "__main__":
    main()
