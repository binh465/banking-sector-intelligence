"""Write the precision sample (view stg.v_precision_sample) to docs/precision_sample.csv for labelling.

Run once. The CSV is the frozen sample and will hold hand-made labels, so the script refuses to
overwrite an existing file. Label columns are left empty:
  is_correct       1 / 0
  is_main_subject  1 / 0
  note             free text
UTF-8 with a BOM so Excel shows Vietnamese text correctly. No other processing.

Run from the repository root:  python ingest/export_precision_sample.py
"""
import csv
from pathlib import Path

from db import get_connection

OUT_PATH = Path("docs/precision_sample.csv")
COLUMNS = ["label_order", "stratum", "url", "ticker", "matched_term", "title",
           "publish_time_local", "stratum_pairs"]
LABEL_COLUMNS = ["is_correct", "is_main_subject", "note"]


def main():
    if OUT_PATH.exists():
        raise SystemExit(f"{OUT_PATH} exists and may hold labels - not overwritten. "
                         "Rename or move it first if a new export is really wanted.")

    conn = get_connection()
    try:
        rows = conn.cursor().execute(
            f"SELECT {', '.join(COLUMNS)} FROM stg.v_precision_sample ORDER BY label_order;"
        ).fetchall()
    finally:
        conn.close()

    with open(OUT_PATH, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(COLUMNS + LABEL_COLUMNS)
        for r in rows:
            values = list(r)
            values[6] = values[6].strftime("%Y-%m-%d %H:%M")   # publish_time_local
            w.writerow(values + [""] * len(LABEL_COLUMNS))

    counts = {}
    for r in rows:
        counts[r[1]] = counts.get(r[1], 0) + 1
    print(f"{OUT_PATH}: {len(rows)} rows")
    for k in sorted(counts):
        print(f"  {k}: {counts[k]}")


if __name__ == "__main__":
    main()
