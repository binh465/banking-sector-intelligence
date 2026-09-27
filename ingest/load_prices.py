"""Load the committed parquet snapshots into raw.raw_price_daily and raw.raw_calendar.

Every value is stored as text exactly as read; typing happens in the staging layer.
Full reload: each table is truncated and refilled inside one transaction, so a
failure leaves the tables unchanged and running the script twice gives the same result.

Run from the repository root:  python ingest/load_prices.py
"""
from pathlib import Path

import pandas as pd

from db import get_connection

SOURCE_COLS = ["symbol", "time", "open", "high", "low", "close", "volume",
               "source", "vnstock_version", "downloaded_at_utc"]
TARGETS = [("raw/prices", "raw.raw_price_daily"),
           ("raw/calendar", "raw.raw_calendar")]


def to_text(value):
    # NaN/NaT become NULL; astype(str) would silently turn them into the string 'nan'.
    return None if pd.isna(value) else str(value)


def read_folder(folder):
    rows, expected = [], {}
    for path in sorted(Path(folder).glob("*.parquet")):
        df = pd.read_parquet(path)
        cols = set(df.columns)
        if cols != set(SOURCE_COLS):
            raise SystemExit(f"{path}: columns differ from the raw table. "
                             f"Missing {sorted(set(SOURCE_COLS) - cols)}, unexpected {sorted(cols - set(SOURCE_COLS))}")
        file_key = path.as_posix()
        for rec in df[SOURCE_COLS].itertuples(index=False):
            rows.append([to_text(v) for v in rec] + [file_key])
        expected[file_key] = len(df)
    if not expected:
        raise SystemExit(f"No parquet files found in {folder}")
    return rows, expected


def main():
    col_list = ", ".join(f"[{c}]" for c in SOURCE_COLS + ["source_file"])
    placeholders = ", ".join("?" * (len(SOURCE_COLS) + 1))

    conn = get_connection()          # autocommit is off: everything below is one transaction
    try:
        cur = conn.cursor()
        cur.fast_executemany = True
        for folder, table in TARGETS:
            rows, expected = read_folder(folder)
            cur.execute(f"TRUNCATE TABLE {table};")
            cur.executemany(f"INSERT INTO {table} ({col_list}) VALUES ({placeholders});", rows)

            loaded = dict(cur.execute(
                f"SELECT source_file, COUNT(*) FROM {table} GROUP BY source_file;").fetchall())
            if loaded != expected:
                raise RuntimeError(f"{table}: row counts differ. files={expected} db={loaded}")
            print(f"{table}: {len(expected)} files, {sum(expected.values())} rows - counts match")
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()