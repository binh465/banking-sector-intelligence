"""Snapshot docs/precision_sample.csv (hand-labelled precision sample) into raw.raw_precision_label.

Reads the file as Excel saves it ("CSV UTF-8"): a BOM may be present, and the separator may be ','
or ';' depending on the Windows list separator, so it is taken from the header line.
Values go in as text, unchanged; checking the labels is done in SQL (staging).
Full reload in one transaction, with a row count check. Run again after any change to the CSV.

Run from the repository root:  python ingest/load_precision_labels.py
"""
import csv
from pathlib import Path

from db import get_connection

CSV_PATH = Path("docs/precision_sample.csv")
COLUMNS = ["label_order", "stratum", "url", "ticker", "matched_term", "title",
           "publish_time_local", "stratum_pairs", "is_correct", "is_main_subject", "note"]


def main():
    with open(CSV_PATH, encoding="utf-8-sig", newline="") as f:
        header_line = f.readline()
        delimiter = ";" if header_line.count(";") > header_line.count(",") else ","
        f.seek(0)   # utf-8-sig skips the BOM again after a seek to the start
        reader = csv.DictReader(f, delimiter=delimiter)
        missing = [c for c in COLUMNS if c not in (reader.fieldnames or [])]
        if missing:
            raise SystemExit(f"{CSV_PATH}: columns missing: {missing} (separator read as {delimiter!r})")
        rows = [[(rec[c] if rec[c] != "" else None) for c in COLUMNS] for rec in reader]

    col_list = ", ".join(f"[{c}]" for c in COLUMNS + ["source_file"])
    placeholders = ", ".join("?" * (len(COLUMNS) + 1))
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute("TRUNCATE TABLE raw.raw_precision_label;")
        cur.executemany(f"INSERT INTO raw.raw_precision_label ({col_list}) VALUES ({placeholders});",
                        [r + [str(CSV_PATH)] for r in rows])
        n = cur.execute("SELECT COUNT(*) FROM raw.raw_precision_label;").fetchone()[0]
        if n != len(rows):
            raise RuntimeError(f"raw.raw_precision_label: {n} rows in table, {len(rows)} in file")
        conn.commit()
        print(f"raw.raw_precision_label: {n} rows (separator {delimiter!r})")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
