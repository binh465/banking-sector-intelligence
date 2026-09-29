-- Price adjustment checks on staging.
--
-- Tick grid: HOSE quotes shares in steps of 10 VND below 10,000, 50 VND from 10,000 to 49,950 and
-- 100 VND from 50,000 (TCBS summary of HOSE rules after KRX). In thousand VND: 0.01 / 0.05 / 0.1.
-- A price that was never multiplied by an adjustment factor sits on that grid. When VCI adjusts
-- history for a corporate action, the older prices get multiplied and mostly fall off the grid.
-- So: off-grid prices point to an adjustment, and the last off-grid date points to roughly when
-- the latest adjustment happened. A ticker with 0% off grid most likely had no corporate action
-- in the window; that doesn't mean its data is wrong.
-- The step is picked from the price itself. For adjusted prices close to 10 or 50 the step can be
-- picked wrong, so a handful of off-grid rows near those levels is not evidence on its own.
USE BankingSectorIntelligence;

-- 1. Share of closes off the grid per ticker, and the last date with an off-grid close.
WITH g AS (
    SELECT ticker, trade_date, close_price,
           CASE WHEN close_price < 10 THEN 0.01 WHEN close_price < 50 THEN 0.05 ELSE 0.1 END AS tick
    FROM stg.stg_price_daily
)
SELECT ticker,
       COUNT(*)                                                         AS sessions,
       SUM(CASE WHEN close_price % tick <> 0 THEN 1 ELSE 0 END)         AS off_grid,
       CAST(100.0 * SUM(CASE WHEN close_price % tick <> 0 THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,1)) AS off_grid_pct,
       MIN(CASE WHEN close_price % tick <> 0 THEN trade_date END)       AS first_off_grid,
       MAX(CASE WHEN close_price % tick <> 0 THEN trade_date END)       AS last_off_grid
FROM g
GROUP BY ticker
ORDER BY ticker;

-- 2. Same, by month, to see where each ticker switches from off grid to on grid.
WITH g AS (
    SELECT ticker, trade_date, close_price,
           CASE WHEN close_price < 10 THEN 0.01 WHEN close_price < 50 THEN 0.05 ELSE 0.1 END AS tick
    FROM stg.stg_price_daily
)
SELECT ticker,
       DATEFROMPARTS(YEAR(trade_date), MONTH(trade_date), 1)            AS month_start,
       COUNT(*)                                                         AS sessions,
       SUM(CASE WHEN close_price % tick <> 0 THEN 1 ELSE 0 END)         AS off_grid
FROM g
GROUP BY ticker, DATEFROMPARTS(YEAR(trade_date), MONTH(trade_date), 1)
ORDER BY ticker, month_start;

-- 3. Cash dividend: VCB and CTG went ex-dividend on 2026-07-23 (450 VND per share, from the
--    CafeF per-ticker lists). If VCI adjusts for cash dividends, closes before that date should
--    fall off the grid and closes from it on should sit on the grid. The other 8 tickers are
--    shown next to them for comparison. Period: 2026-06-01 to the end of the window.
WITH g AS (
    SELECT ticker, trade_date, close_price,
           CASE WHEN close_price < 10 THEN 0.01 WHEN close_price < 50 THEN 0.05 ELSE 0.1 END AS tick
    FROM stg.stg_price_daily
    WHERE trade_date >= '2026-06-01'
)
SELECT ticker,
       SUM(CASE WHEN trade_date <  '2026-07-23' THEN 1 ELSE 0 END)                               AS sessions_before,
       SUM(CASE WHEN trade_date <  '2026-07-23' AND close_price % tick <> 0 THEN 1 ELSE 0 END)   AS off_grid_before,
       SUM(CASE WHEN trade_date >= '2026-07-23' THEN 1 ELSE 0 END)                               AS sessions_from,
       SUM(CASE WHEN trade_date >= '2026-07-23' AND close_price % tick <> 0 THEN 1 ELSE 0 END)   AS off_grid_from
FROM g
GROUP BY ticker
ORDER BY CASE WHEN ticker IN (N'VCB', N'CTG') THEN 0 ELSE 1 END, ticker;

-- 4. Daily moves beyond the HOSE +-7% band.
--    Up to 7.5% is treated as ceiling/floor rounding (valid data); beyond that points to a
--    corporate action VCI didn't adjust for. Returns come from consecutive rows per ticker;
--    staging holds only trading days, all aligned with the calendar (check 3 in 100_stg_price_checks).
WITH r AS (
    SELECT ticker, trade_date, close_price,
           LAG(close_price) OVER (PARTITION BY ticker ORDER BY trade_date) AS prev_close
    FROM stg.stg_price_daily
)
SELECT ticker, trade_date, prev_close, close_price,
       CAST(100.0 * (close_price / prev_close - 1) AS decimal(7,2)) AS return_pct,
       CASE WHEN ABS(close_price / prev_close - 1) <= 0.075 THEN N'within 0.5 pt (rounding)'
            ELSE N'beyond 7.5%' END                                   AS band_class
FROM r
WHERE prev_close IS NOT NULL
  AND ABS(close_price / prev_close - 1) > 0.07
ORDER BY ticker, trade_date;

-- 5. Count of 4 per ticker, including tickers with none.
WITH r AS (
    SELECT ticker, close_price,
           LAG(close_price) OVER (PARTITION BY ticker ORDER BY trade_date) AS prev_close
    FROM stg.stg_price_daily
)
SELECT t.ticker,
       SUM(CASE WHEN ABS(r.close_price / r.prev_close - 1) >  0.07
                 AND ABS(r.close_price / r.prev_close - 1) <= 0.075 THEN 1 ELSE 0 END) AS within_tolerance,
       SUM(CASE WHEN ABS(r.close_price / r.prev_close - 1) >  0.075 THEN 1 ELSE 0 END) AS beyond_tolerance
FROM (SELECT DISTINCT [ticker] AS ticker FROM raw.raw_ticker_config) t
LEFT JOIN r ON r.ticker = t.ticker AND r.prev_close IS NOT NULL
GROUP BY t.ticker
ORDER BY t.ticker;
