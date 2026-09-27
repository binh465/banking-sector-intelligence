"""Crawl CafeF's per-ticker news list for the 10 tickers.

Saves each page as-is to raw/news/ticker/{TICKER}_p{NN}.html. No parsing into the database here;
that is a separate step, so the parse logic can change without crawling again.

- Never overwrites a saved page. Pages already on disk are read instead of fetched, so an
  interrupted run can be restarted.
- Stops for a ticker when a page's oldest item is before the window start (that page is kept),
  when a page has no items, or at MAX_PAGES.
- Every request is appended to raw/news/ticker/_fetch_log.csv.

Run from the repository root:  python ingest/crawl_ticker_news.py
"""
import csv
import re
import time
from datetime import date, datetime, timezone
from pathlib import Path

import requests
import yaml

ENDPOINT = "https://cafef.vn/du-lieu/Ajax/Events_RelatedNews_New.aspx"
PAGE_SIZE = 30
MAX_PAGES = 60          # safety cap per ticker; CTG's page 1 only reaches back ~3 months
SLEEP_SECONDS = 2
OUT_DIR = Path("raw/news/ticker")
LOG_PATH = OUT_DIR / "_fetch_log.csv"
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; BSI-research-crawler/0.1; personal data project)"}

TIME_RE = re.compile(r'<span class="timeTitle">\s*(\d{2}/\d{2}/\d{4})')


def load_config():
    with open("config/tickers.yaml", encoding="utf-8") as f:
        tickers = [t["ticker"] for t in yaml.safe_load(f)["tickers"]]
    with open("config/scope.yaml", encoding="utf-8") as f:
        start = yaml.safe_load(f)["window"]["start_date"]
    return tickers, start


def item_dates(html: str) -> list[date]:
    return [datetime.strptime(d, "%d/%m/%Y").date() for d in TIME_RE.findall(html)]


def log_request(row: dict):
    new_file = not LOG_PATH.exists()
    with open(LOG_PATH, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["fetched_at_utc", "ticker", "page", "status", "bytes", "file"])
        if new_file:
            w.writeheader()
        w.writerow(row)


def get_page(session, ticker: str, page: int) -> str:
    path = OUT_DIR / f"{ticker}_p{page:02d}.html"
    if path.exists():
        return path.read_text(encoding="utf-8")

    params = {"symbol": ticker, "floorID": 0, "configID": 0,
              "PageIndex": page, "PageSize": PAGE_SIZE, "Type": 2}
    resp = session.get(ENDPOINT, params=params, headers=HEADERS, timeout=30)
    log_request({"fetched_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                 "ticker": ticker, "page": page, "status": resp.status_code,
                 "bytes": len(resp.content), "file": path.as_posix()})
    resp.raise_for_status()
    resp.encoding = "utf-8"
    path.write_text(resp.text, encoding="utf-8")
    time.sleep(SLEEP_SECONDS)
    return resp.text


def main():
    tickers, start = load_config()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with requests.Session() as session:
        for ticker in tickers:
            for page in range(1, MAX_PAGES + 1):
                dates = item_dates(get_page(session, ticker, page))
                if not dates:
                    print(f"{ticker}: page {page} has no items - stop")
                    break
                if min(dates) < start:
                    print(f"{ticker}: {page} pages, oldest item {min(dates)} (window starts {start})")
                    break
            else:
                print(f"{ticker}: hit MAX_PAGES={MAX_PAGES} before reaching {start} - check this ticker")


if __name__ == "__main__":
    main()
