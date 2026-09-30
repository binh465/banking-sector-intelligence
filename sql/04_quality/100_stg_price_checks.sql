USE BankingSectorIntelligence;

-- 1. The window as loaded.
SELECT start_date, base_date, end_date FROM stg.stg_scope;

-- 2. Sessions per ticker next to the calendar, with first and last date.
SELECT p.ticker, COUNT(*) AS sessions, MIN(p.trade_date) AS first_date, MAX(p.trade_date) AS last_date,
       (SELECT COUNT(*) FROM stg.stg_calendar) AS calendar_sessions
FROM stg.stg_price_daily p
GROUP BY p.ticker
ORDER BY p.ticker;

-- 3. Day by day against the calendar, both directions.
--    3a. a ticker has a session the calendar doesn't have
SELECT p.ticker, p.trade_date
FROM stg.stg_price_daily p
WHERE NOT EXISTS (SELECT 1 FROM stg.stg_calendar c WHERE c.trade_date = p.trade_date);
--    3b. the calendar has a session a ticker is missing. Tickers come from the config, so a ticker
--        missing from staging entirely shows up here with every date.
SELECT t.ticker, c.trade_date
FROM stg.stg_calendar c
CROSS JOIN (SELECT DISTINCT [ticker] AS ticker FROM raw.raw_ticker_config) t
WHERE NOT EXISTS (SELECT 1 FROM stg.stg_price_daily p WHERE p.ticker = t.ticker AND p.trade_date = c.trade_date);

-- 4. raw -> stg reconciliation per ticker: rows inside the window, rows cut off before it, rows lost.
SELECT r.ticker,
       SUM(CASE WHEN r.trade_date BETWEEN s.start_date AND s.end_date THEN 1 ELSE 0 END) AS raw_in_window,
       SUM(CASE WHEN r.trade_date < s.start_date THEN 1 ELSE 0 END)                       AS raw_before_window,
       SUM(CASE WHEN r.trade_date > s.end_date THEN 1 ELSE 0 END)                         AS raw_after_window,
       (SELECT COUNT(*) FROM stg.stg_price_daily p WHERE p.ticker = r.ticker)            AS stg_rows
FROM (SELECT UPPER(LTRIM(RTRIM([symbol]))) AS ticker, CAST(CAST([time] AS datetime2(0)) AS date) AS trade_date
      FROM raw.raw_price_daily) r
CROSS JOIN stg.stg_scope s
GROUP BY r.ticker
ORDER BY r.ticker;

-- 5. Price sanity: non-positive prices, low/high not bracketing open/close, negative volume.
SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume
FROM stg.stg_price_daily
WHERE open_price <= 0 OR high_price <= 0 OR low_price <= 0 OR close_price <= 0
   OR low_price > high_price
   OR open_price  NOT BETWEEN low_price AND high_price
   OR close_price NOT BETWEEN low_price AND high_price
   OR volume < 0;

-- 6. Sessions with zero volume (a ticker listed on the calendar day but not traded).
SELECT ticker, COUNT(*) AS zero_volume_sessions
FROM stg.stg_price_daily
WHERE volume = 0
GROUP BY ticker;

-- 7. Repeated closes and repeated bars per ticker. same_bar = open, high, low, close and volume all
--    equal to the previous session. A repeated bar with volume points to a row copied forward by the
--    source rather than a real session. Consecutive rows are consecutive sessions (check 3).
WITH p AS (
    SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume,
           LAG(open_price)  OVER (PARTITION BY ticker ORDER BY trade_date) AS prev_open,
           LAG(high_price)  OVER (PARTITION BY ticker ORDER BY trade_date) AS prev_high,
           LAG(low_price)   OVER (PARTITION BY ticker ORDER BY trade_date) AS prev_low,
           LAG(close_price) OVER (PARTITION BY ticker ORDER BY trade_date) AS prev_close,
           LAG(volume)      OVER (PARTITION BY ticker ORDER BY trade_date) AS prev_volume
    FROM stg.stg_price_daily
)
SELECT ticker,
       SUM(CASE WHEN close_price = prev_close THEN 1 ELSE 0 END) AS same_close,
       SUM(CASE WHEN close_price = prev_close AND open_price = prev_open AND high_price = prev_high
                 AND low_price = prev_low AND volume = prev_volume THEN 1 ELSE 0 END) AS same_bar
FROM p
GROUP BY ticker
ORDER BY ticker;

-- 8. Runs of 3 or more consecutive sessions with the same close (gaps and islands).
--    Within a run both row numbers go up by 1 per row, so rn - rn_close stays constant; a later run
--    at the same price gets a different difference.
WITH p AS (
    SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume,
           ROW_NUMBER() OVER (PARTITION BY ticker ORDER BY trade_date)              AS rn,
           ROW_NUMBER() OVER (PARTITION BY ticker, close_price ORDER BY trade_date) AS rn_close
    FROM stg.stg_price_daily
)
SELECT ticker, close_price,
       MIN(trade_date)                                        AS run_start,
       MAX(trade_date)                                        AS run_end,
       COUNT(*)                                               AS sessions,
       COUNT(DISTINCT volume)                                 AS distinct_volumes,
       COUNT(DISTINCT CONCAT(open_price, '|', high_price, '|', low_price)) AS distinct_ohl,
       MIN(volume)                                            AS min_volume,
       MAX(volume)                                            AS max_volume
FROM p
GROUP BY ticker, close_price, rn - rn_close
HAVING COUNT(*) >= 3
ORDER BY ticker, run_start;
