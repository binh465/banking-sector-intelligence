"""Download daily OHLCV for the 10 tickers and VNINDEX via vnstock.

Raw snapshot only: no cleaning, no filtering. Extra bars before the window
start are kept on purpose and filtered in the staging layer (Phase 2).

Behaviour measured on vnstock 4.0.9 (2026-09-27):
- `start` is ignored; `count` bars are taken backwards from `end`.
- `end` is respected and inclusive.
- Default source is 'kbs'; 'vci' and 'kbs' return different adjusted prices
  and slightly different session lists, so the source is always explicit.
- Prices are in thousand VND.

Run from the repository root:  python ingest/download_prices.py
"""
import time
from datetime import datetime, timezone
from importlib.metadata import version
from pathlib import Path

import yaml
from vnstock import Market

SOURCE = "vci"
COUNT = 600          # ~500 sessions in 2 years; the surplus is filtered in staging
SLEEP_SECONDS = 7    # guest tier: 20 requests/min; one ohlcv() call used ~2 requests
                     # (measured: 10 calls hit the 20/20 limit with a 4 s sleep)


def load_config():
    with open("config/tickers.yaml", encoding="utf-8") as f:
        tickers = [t["ticker"] for t in yaml.safe_load(f)["tickers"]]
    with open("config/scope.yaml", encoding="utf-8") as f:
        window = yaml.safe_load(f)["window"]
    return tickers, window


def main():
    tickers, window = load_config()
    end = window["end_date"].isoformat()
    downloaded_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    market = Market()

    jobs = [("equity", t, Path("raw/prices")) for t in tickers]
    jobs.append(("index", "VNINDEX", Path("raw/calendar")))

    print(f"source={SOURCE} end={end} count={COUNT} vnstock={version('vnstock')}")
    for kind, symbol, out_dir in jobs:
        # Never overwrite: an existing file is the committed snapshot (VCI adjusts
        # history retroactively, so a re-download would not be identical).
        # Missing files are downloaded, so an interrupted run can be resumed;
        # downloaded_at_utc records when each file was taken.
        if (out_dir / f"{symbol}.parquet").exists():
            print(f"{symbol:8} skipped (file exists)")
            continue
        handle = market.equity(symbol) if kind == "equity" else market.index(symbol)
        df = handle.ohlcv(end=end, count=COUNT, interval="1D", source=SOURCE)

        df["symbol"] = symbol
        df["source"] = SOURCE
        df["vnstock_version"] = version("vnstock")
        df["downloaded_at_utc"] = downloaded_at

        out = out_dir / f"{symbol}.parquet"
        df.to_parquet(out, index=False)
        print(f"{symbol:8} {len(df):4} rows  {df['time'].min().date()} -> {df['time'].max().date()}")
        time.sleep(SLEEP_SECONDS)


if __name__ == "__main__":
    main()
