USE BankingSectorIntelligence;

-- 1. Grain: one row per ticker per session. Grouped by the durable ticker, not ticker_key:
--    two overlapping versions of one ticker would give two rows for the same session and still
--    pass the primary key.
SELECT t.ticker, f.date_key, COUNT(*) AS n
FROM dw.fact_price_daily f
JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
GROUP BY t.ticker, f.date_key
HAVING COUNT(*) > 1;

-- 2. Rows per ticker vs trading days in dim_date (not a fixed number).
SELECT t.ticker,
       COUNT(*)                                                         AS fact_rows,
       (SELECT COUNT(*) FROM dw.dim_date WHERE is_trading_day = 1)      AS trading_days
FROM dw.fact_price_daily f
JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
GROUP BY t.ticker
ORDER BY t.ticker;

-- 3. Every row falls on a trading day.
SELECT COUNT(*) AS rows_on_non_trading_days
FROM dw.fact_price_daily f
JOIN dw.dim_date d ON d.date_key = f.date_key
WHERE d.is_trading_day = 0;

-- 4. Every row carries the ticker version valid on its date.
SELECT t.ticker, d.full_date, t.valid_from, t.valid_to
FROM dw.fact_price_daily f
JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
JOIN dw.dim_date   d ON d.date_key   = f.date_key
WHERE d.full_date NOT BETWEEN t.valid_from AND t.valid_to;

-- 5. Values match staging, both directions (EXCEPT compares whole rows, NULL-safe).
SELECT N'stg not in fact' AS side, COUNT(*) AS n
FROM (SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume FROM stg.stg_price_daily
      EXCEPT
      SELECT t.ticker, d.full_date, f.open_price, f.high_price, f.low_price, f.close_price, f.volume
      FROM dw.fact_price_daily f
      JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
      JOIN dw.dim_date   d ON d.date_key   = f.date_key) x
UNION ALL
SELECT N'fact not in stg', COUNT(*)
FROM (SELECT t.ticker, d.full_date, f.open_price, f.high_price, f.low_price, f.close_price, f.volume
      FROM dw.fact_price_daily f
      JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
      JOIN dw.dim_date   d ON d.date_key   = f.date_key
      EXCEPT
      SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume FROM stg.stg_price_daily) y;

-- 6. Rows per ticker_key: STB split across its two versions.
SELECT f.ticker_key, t.ticker, t.full_name, COUNT(*) AS rows_n,
       MIN(d.full_date) AS first_date, MAX(d.full_date) AS last_date
FROM dw.fact_price_daily f
JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
JOIN dw.dim_date   d ON d.date_key   = f.date_key
GROUP BY f.ticker_key, t.ticker, t.full_name
ORDER BY f.ticker_key;
