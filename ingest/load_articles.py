"""Load CafeF article data into the raw layer.

  raw.raw_article       <- every entry of raw/news/sitemaps/sitemaps-*.xml
  raw.raw_article_page  <- every saved page in raw/news/article_pages/*.gz (publish time, og:title)

Values as text. Each table is truncated and refilled in one transaction, with a per-file row
count check before commit. Pages that are missing the meta tags still get a row (NULL values),
so the checks in SQL can count them.

Run from the repository root:  python ingest/load_articles.py
Can be run while fetch_article_pages.py is still going; it loads whatever pages are on disk.
Prints progress messages for each major stage and every 1,000 parsed pages; parsing saved
article pages may take several minutes.
"""
import csv
import gzip
import html
import re
from pathlib import Path

from bs4 import BeautifulSoup

SITEMAP_DIR = Path("raw/news/sitemaps")
PAGE_DIR = Path("raw/news/article_pages")
BATCH_SIZE = 5000
ENTRY_RE = re.compile(
    r"<url>\s*<loc>([^<]+)</loc>.*?<lastmod>([^<]+)</lastmod>.*?<image:title>(.*?)</image:title>", re.S)


def clean_title(raw: str) -> str:
    t = html.unescape(raw).strip()
    if t.startswith("<![CDATA[") and t.endswith("]]>"):
        # CafeF puts HTML entities inside the CDATA ("Lynk &amp; Co"), so decode the inner text once more.
        t = html.unescape(t[9:-3])
    return t.strip()


def read_sitemaps():
    rows, expected = [], {}
    for path in sorted(SITEMAP_DIR.glob("sitemaps-*.xml")):
        text = path.read_text(encoding="utf-8")
        entries = ENTRY_RE.findall(text)
        if len(entries) != text.count("<url>"):
            raise SystemExit(f"{path}: {text.count('<url>')} <url> blocks but {len(entries)} parsed - layout changed?")
        key = path.as_posix()
        rows += [[u.strip(), lm.strip(), clean_title(t), key] for u, lm, t in entries]
        expected[key] = len(entries)
    return rows, expected


def read_pages():
    url_by_file, fetched_by_file = {}, {}
    # The fetcher may be appending to the log right now; a half-written last line is skipped.
    with open(PAGE_DIR / "_fetch_log.csv", encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            if r.get("status") == "200" and r.get("file") and r.get("url") and r.get("fetched_at_utc"):
                name = Path(r["file"]).name
                url_by_file[name], fetched_by_file[name] = r["url"], r["fetched_at_utc"]
    rows, expected = [], {}
    for i, path in enumerate(sorted(PAGE_DIR.glob("*.gz")), start=1):
        soup = BeautifulSoup(gzip.decompress(path.read_bytes()).decode("utf-8", errors="replace"), "html.parser")
        pub = soup.find("meta", attrs={"property": "article:published_time"})
        og = soup.find("meta", attrs={"property": "og:title"})
        key = path.as_posix()
        rows.append([url_by_file.get(path.name), pub.get("content") if pub else None,
                     og.get("content") if og else None, fetched_by_file.get(path.name), key])
        expected[key] = 1
        if i % 1000 == 0:
            print(f"  {i} pages", flush=True)
    return rows, expected


def load(conn, table, cols, rows, expected):
    col_list = ", ".join(f"[{c}]" for c in cols + ["source_file"])
    placeholders = ", ".join("?" * (len(cols) + 1))
    cur = conn.cursor()
    cur.fast_executemany = True
    cur.execute(f"TRUNCATE TABLE {table};")
    # Insert in batches: with fast_executemany pyodbc allocates a buffer for every row it is given
    # (NVARCHAR(1000) columns = ~2 KB per value), so one call with 250k rows can take gigabytes.
    for i in range(0, len(rows), BATCH_SIZE):
        cur.executemany(f"INSERT INTO {table} ({col_list}) VALUES ({placeholders});", rows[i:i + BATCH_SIZE])
    loaded = dict(cur.execute(f"SELECT source_file, COUNT(*) FROM {table} GROUP BY source_file;").fetchall())
    if loaded != expected:
        raise RuntimeError(f"{table}: row counts differ between files and table")
    print(f"{table}: {len(expected)} files, {len(rows)} rows - counts match")


def main():
    from db import get_connection

    sitemap_rows, sitemap_expected = read_sitemaps()
    print(f"sitemaps read: {len(sitemap_expected)} files, {len(sitemap_rows)} rows", flush=True)

    print("parsing saved article pages (may take several minutes)...", flush=True)
    page_rows, page_expected = read_pages()
    print(f"pages parsed: {len(page_rows)}", flush=True)

    conn = get_connection()
    try:
        print("loading into SQL Server, one transaction...", flush=True)
        load(conn, "raw.raw_article", ["url", "lastmod", "title"], sitemap_rows, sitemap_expected)
        load(conn, "raw.raw_article_page", ["url", "published_time", "og_title", "fetched_at_utc"],
             page_rows, page_expected)
        conn.commit()
        print("committed", flush=True)
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
