"""Snapshot config/scope.yaml and config/tickers.yaml into the raw layer.

  raw.raw_scope                <- scope.yaml window block (one row)
  raw.raw_ticker_config        <- tickers.yaml, one row per ticker
  raw.raw_ticker_name_history  <- tickers.yaml name_history entries (only tickers that have one)

config/ stays the single source; SQL reads these tables instead of hard-coding dates.
Full reload in one transaction. Run again after any change to the two yaml files.

Run from the repository root:  python ingest/load_config.py
"""
import yaml

from db import get_connection

SCOPE_PATH = "config/scope.yaml"
TICKERS_PATH = "config/tickers.yaml"


def text(v):
    return None if v is None else str(v)


def main():
    with open(SCOPE_PATH, encoding="utf-8") as f:
        scope = yaml.safe_load(f)
    with open(TICKERS_PATH, encoding="utf-8") as f:
        tickers = yaml.safe_load(f)

    w = scope["window"]
    scope_rows = [[text(w["start_date"]), text(w["end_date"]), text(w["base_date"]), text(scope.get("locked_on")),
                   text(scope.get("price_source")), text(scope.get("news_source")), SCOPE_PATH]]
    ticker_rows, history_rows = [], []
    for t in tickers["tickers"]:
        ticker_rows.append([t["ticker"], t["full_name"], tickers.get("exchange"), TICKERS_PATH])
        for h in t.get("name_history", []):
            history_rows.append([t["ticker"], h["full_name"], text(h.get("valid_from")), text(h.get("valid_to")),
                                 text(t.get("name_change_source")), TICKERS_PATH])

    targets = [
        ("raw.raw_scope", ["start_date", "end_date", "base_date", "locked_on", "price_source", "news_source"], scope_rows),
        ("raw.raw_ticker_config", ["ticker", "full_name", "exchange"], ticker_rows),
        ("raw.raw_ticker_name_history", ["ticker", "full_name", "valid_from", "valid_to", "name_change_source"], history_rows),
    ]
    conn = get_connection()
    try:
        cur = conn.cursor()
        for table, cols, rows in targets:
            col_list = ", ".join(f"[{c}]" for c in cols + ["source_file"])
            placeholders = ", ".join("?" * (len(cols) + 1))
            cur.execute(f"TRUNCATE TABLE {table};")
            if rows:
                cur.executemany(f"INSERT INTO {table} ({col_list}) VALUES ({placeholders});", rows)
            n = cur.execute(f"SELECT COUNT(*) FROM {table};").fetchone()[0]
            if n != len(rows):
                raise RuntimeError(f"{table}: {n} rows in table, {len(rows)} from yaml")
            print(f"{table}: {n} rows")
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
