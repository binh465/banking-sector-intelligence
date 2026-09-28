"""Load raw/news/lastmod_sample/sample.csv into raw.raw_lastmod_sample.

Values as text, full reload in one transaction, row count checked before commit.

Run from the repository root:  python ingest/load_lastmod_sample.py
"""
import csv
from pathlib import Path

from db import get_connection

CSV_PATH = Path("raw/news/lastmod_sample/sample.csv")
TABLE = "raw.raw_lastmod_sample"
COLS = ["stratum", "stratum_population", "url", "lastmod", "url_timestamp", "published_time", "file"]


def main():
    with open(CSV_PATH, encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != COLS:
            raise SystemExit(f"{CSV_PATH}: columns {reader.fieldnames} differ from {COLS}")
        rows = [[r[c] or None for c in COLS] + [CSV_PATH.as_posix()] for r in reader]

    col_list = ", ".join(f"[{c}]" for c in COLS + ["source_file"])
    placeholders = ", ".join("?" * (len(COLS) + 1))
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute(f"TRUNCATE TABLE {TABLE};")
        cur.executemany(f"INSERT INTO {TABLE} ({col_list}) VALUES ({placeholders});", rows)
        loaded = cur.execute(f"SELECT COUNT(*) FROM {TABLE};").fetchone()[0]
        if loaded != len(rows):
            raise RuntimeError(f"{TABLE}: {loaded} rows in table, {len(rows)} in the csv")
        conn.commit()
        print(f"{TABLE}: {loaded} rows - count matches the csv")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
