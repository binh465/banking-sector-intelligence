"""Parse the saved per-ticker list pages and load them into raw.raw_ticker_news.

One row per list item, every value as text. No filtering by date and no cleaning of URLs;
that happens in staging. Full reload in one transaction, with a per-file row-count check
against what was parsed, like load_prices.py.

Run from the repository root:  python ingest/load_ticker_news.py
"""
import csv
import re
from pathlib import Path

from bs4 import BeautifulSoup

IN_DIR = Path("raw/news/ticker")
LOG_PATH = IN_DIR / "_fetch_log.csv"
FILE_RE = re.compile(r"^(?P<ticker>[A-Z]+)_p(?P<page>\d+)\.html$")
COLS = ["ticker", "page", "item_position", "time_text", "title", "href", "fetched_at_utc"]
TABLE = "raw.raw_ticker_news"


def fetch_times() -> dict:
    # Last successful fetch per file. Pages read back from disk on a rerun have no new log row.
    times = {}
    with open(LOG_PATH, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["status"] == "200":
                times[Path(row["file"]).name] = row["fetched_at_utc"]
    return times


def parse_file(path: Path) -> list[list]:
    m = FILE_RE.match(path.name)
    if not m:
        raise SystemExit(f"Unexpected file name: {path}")
    soup = BeautifulSoup(path.read_text(encoding="utf-8"), "html.parser")
    rows = []
    for pos, li in enumerate(soup.select("ul.News_Title_Link > li"), start=1):
        time_el, a = li.select_one("span.timeTitle"), li.find("a")
        if time_el is None or a is None:
            raise SystemExit(f"{path}: item {pos} has no time or no link - page layout changed?")
        title = a.get("title") or a.get_text()
        rows.append([m["ticker"], m["page"], str(pos), time_el.get_text(strip=True),
                     title.strip(), a.get("href")])
    return rows


def read_all():
    times = fetch_times()
    rows, expected = [], {}
    for path in sorted(IN_DIR.glob("*.html")):
        items = parse_file(path)
        fetched = times.get(path.name)
        key = path.as_posix()
        rows += [r + [fetched, key] for r in items]
        expected[key] = len(items)
    if not expected:
        raise SystemExit(f"No html files in {IN_DIR}")
    return rows, expected


def main():
    from db import get_connection   # imported here so the parser can be tested without pyodbc

    rows, expected = read_all()
    col_list = ", ".join(f"[{c}]" for c in COLS + ["source_file"])
    placeholders = ", ".join("?" * (len(COLS) + 1))

    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.fast_executemany = True
        cur.execute(f"TRUNCATE TABLE {TABLE};")
        cur.executemany(f"INSERT INTO {TABLE} ({col_list}) VALUES ({placeholders});", rows)
        loaded = dict(cur.execute(f"SELECT source_file, COUNT(*) FROM {TABLE} GROUP BY source_file;").fetchall())
        if loaded != expected:
            raise RuntimeError(f"Row counts differ between parsed files and {TABLE}")
        conn.commit()
        print(f"{TABLE}: {len(expected)} files, {len(rows)} rows - counts match")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
