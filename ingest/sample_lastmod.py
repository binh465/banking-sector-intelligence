"""Draw a stratified sample of sitemap entries and fetch each article's publish time.

Purpose: measure how far sitemap `lastmod` is from `article:published_time` before choosing
which timestamp feeds reaction_date_key. The comparison by trading session is done in SQL.

Sample:
- Population: sitemap entries with lastmod inside the window.
- Strata by lag = lastmod minus the timestamp in the URL ID (-188YYMMDDhhmmss...):
  A < 1 h, B 1-6 h, C 6-24 h, D >= 24 h, U = URL has no parseable timestamp.
- Fixed seed, so the same sample comes out on every run. Population size per stratum is kept
  in the output so results can be weighted back to the whole population.

Output:
- raw/news/articles/{article_id}.html  (never overwritten, written via .part)
- raw/news/lastmod_sample/sample.csv   (rewritten from the saved HTML on every run)

Run from the repository root:  python ingest/sample_lastmod.py
"""
import csv
import random
import re
import time
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import requests
import yaml
from bs4 import BeautifulSoup

SITEMAP_DIR = Path("raw/news/sitemaps")
ARTICLE_DIR = Path("raw/news/articles")
OUT_CSV = Path("raw/news/lastmod_sample/sample.csv")
SEED = 20260928
PER_STRATUM = {"A": 14, "B": 14, "C": 11, "D": 11, "U": 6}   # U was empty on the first check
SLEEP_SECONDS = 2
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; BSI-research-crawler/0.1; personal data project)"}

ENTRY_RE = re.compile(r"<url>\s*<loc>([^<]+)</loc>.*?<lastmod>([^<]+)</lastmod>", re.S)
ID_RE = re.compile(r"-(188\d+)\.chn$")


def url_timestamp(url: str):
    m = ID_RE.search(url)
    if not m:
        return None
    try:
        return datetime.strptime(m.group(1)[3:15], "%y%m%d%H%M%S")
    except ValueError:
        return None


def stratum(lastmod: datetime, url_ts):
    if url_ts is None:
        return "U"
    hours = (lastmod - url_ts).total_seconds() / 3600
    if hours < 1:
        return "A"
    if hours < 6:
        return "B"
    if hours < 24:
        return "C"
    return "D"


def load_population():
    with open("config/scope.yaml", encoding="utf-8") as f:
        w = yaml.safe_load(f)["window"]
    start, end = w["start_date"].isoformat(), w["end_date"].isoformat()
    latest = {}   # a URL can appear in two bucket files with different lastmod; keep the latest
    for path in sorted(SITEMAP_DIR.glob("sitemaps-*.xml")):
        for url, lm in ENTRY_RE.findall(path.read_text(encoding="utf-8")):
            url, lm = url.strip(), lm.strip()
            if start <= lm[:10] <= end and lm > latest.get(url, ""):
                latest[url] = lm
    strata = defaultdict(list)
    for url, lm in sorted(latest.items()):
        lastmod = datetime.fromisoformat(lm).replace(tzinfo=None)   # all values are +07:00
        strata[stratum(lastmod, url_timestamp(url))].append((url, lm))
    return strata


def draw_sample(strata):
    rng = random.Random(SEED)
    sample = []
    for s, n in PER_STRATUM.items():
        pop = strata.get(s, [])
        for url, lm in rng.sample(pop, min(n, len(pop))):
            sample.append({"stratum": s, "stratum_population": len(pop), "url": url, "lastmod": lm})
    return sample


def article_path(url: str) -> Path:
    return ARTICLE_DIR / (url.rstrip("/").rsplit("/", 1)[1])


def fetch(session, url: str, path: Path):
    resp = session.get(url, headers=HEADERS, timeout=60)
    resp.raise_for_status()
    part = path.with_name(path.name + ".part")
    part.write_bytes(resp.content)
    part.replace(path)


def published_time(html: str):
    meta = BeautifulSoup(html, "html.parser").find("meta", attrs={"property": "article:published_time"})
    return meta.get("content") if meta else None


def main():
    strata = load_population()
    print("population:", {s: len(v) for s, v in sorted(strata.items())})
    sample = draw_sample(strata)
    ARTICLE_DIR.mkdir(parents=True, exist_ok=True)
    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)

    with requests.Session() as session:
        for row in sample:
            path = article_path(row["url"])
            if not path.exists():
                fetch(session, row["url"], path)
                time.sleep(SLEEP_SECONDS)
            ts = url_timestamp(row["url"])
            row["url_timestamp"] = ts.isoformat() if ts else None
            row["published_time"] = published_time(path.read_text(encoding="utf-8"))
            row["file"] = path.as_posix()

    fields = ["stratum", "stratum_population", "url", "lastmod", "url_timestamp", "published_time", "file"]
    with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(sample)
    missing = sum(1 for r in sample if not r["published_time"])
    print(f"{len(sample)} articles sampled, {missing} without article:published_time -> {OUT_CSV}")


if __name__ == "__main__":
    main()
