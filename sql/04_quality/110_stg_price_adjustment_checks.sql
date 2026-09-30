-- Price adjustment checks on staging.
--
-- Tick grid: HOSE quotes shares in steps of 10 VND below 10,000, 50 VND from 10,000 to 49,950 and
-- 100 VND from 50,000 (TCBS summary of HOSE rules after KRX). In thousand VND: 0.01 / 0.05 / 0.1.
-- A price that was never multiplied by an adjustment factor sits on that grid. When VCI adjusts
-- history for a corporate action, the older prices get multiplied and mostly fall off the grid.
-- So: off-grid prices point to an adjustment, and the last off-grid date points to roughly when
-- the latest adjustment happened. A ticker with 0% off grid most likely had no corporate action
-- in the window; that doesn't mean its data is wrong.
-- Prices are stored in thousand VND with 2 decimals, so below 10 (tick 0.01) every price is on the
-- grid whether adjusted or not: the test says nothing for those sessions (sessions_below_10 in query 1).
-- An adjusted price still lands on the grid by chance about 1 time in 5 (tick 0.05) or 1 in 10 (tick 0.1).
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
       MAX(CASE WHEN close_price % tick <> 0 THEN trade_date END)       AS last_off_grid,
       MIN(close_price)                                                 AS min_close,
       MAX(close_price)                                                 AS max_close,
       SUM(CASE WHEN close_price < 10 THEN 1 ELSE 0 END)                AS sessions_below_10,
       MAX(CASE WHEN close_price < 10 THEN trade_date END)              AS last_below_10
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

-- 6. Ex-rights dates (ngày GDKHQ) from the CafeF disclosures in raw.raw_ticker_news.
--    Every GDKHQ title has the form 'VCB: 23.7.2026, ngày GDKHQ ...'; the date is read from the title.
--    SUBSTRING takes a fixed 10 characters so a title without ': ' gives NULL instead of an error.
--    price_event = 1 for dividends (cash or shares), bonus shares, share issues and rights offerings;
--    0 for meetings and shareholder votes. The collation is accent sensitive, so 'thưởng' (bonus)
--    does not match 'thường niên' (annual meeting).
WITH ev AS (
    SELECT DISTINCT n.[ticker], d.ex_date, n.[title],
           CASE WHEN n.[title] LIKE N'%cổ tức%' OR n.[title] LIKE N'%ưu đãi%'
                  OR n.[title] LIKE N'%thưởng%' OR n.[title] LIKE N'%phát hành%' THEN 1 ELSE 0 END AS price_event
    FROM raw.raw_ticker_news n
    CROSS APPLY (SELECT SUBSTRING(n.[title], CHARINDEX(N': ', n.[title]) + 2, 10) AS s) a
    CROSS APPLY (SELECT TRY_CONVERT(date, REPLACE(LEFT(a.s, CHARINDEX(N',', a.s + N',') - 1), N'.', N'/'), 103) AS ex_date) d
    WHERE n.[href] LIKE N'%/du-lieu/%'
      AND n.[title] LIKE N'%ngày GDKHQ%'
)
SELECT e.[ticker], e.ex_date, e.price_event, e.[title],
       CASE WHEN e.ex_date IS NULL THEN N'date not parsed'
            WHEN e.ex_date BETWEEN s.start_date AND s.end_date THEN N'in window'
            ELSE N'outside window' END AS window_status
FROM ev e CROSS JOIN stg.stg_scope s
ORDER BY e.[ticker], e.ex_date;

-- 7. Latest price event in the window per ticker vs the last off-grid close.
--    Every new event re-adjusts all earlier prices, so only the latest event leaves an on-grid tail.
--    The adjustment matches the event when last_off_grid falls just before last_ex_date and
--    off_grid_from_ex is 0. on_grid_gap counts the sessions between the two dates.
WITH ev AS (
    SELECT DISTINCT n.[ticker], d.ex_date
    FROM raw.raw_ticker_news n
    CROSS APPLY (SELECT SUBSTRING(n.[title], CHARINDEX(N': ', n.[title]) + 2, 10) AS s) a
    CROSS APPLY (SELECT TRY_CONVERT(date, REPLACE(LEFT(a.s, CHARINDEX(N',', a.s + N',') - 1), N'.', N'/'), 103) AS ex_date) d
    WHERE n.[href] LIKE N'%/du-lieu/%'
      AND n.[title] LIKE N'%ngày GDKHQ%'
      AND (n.[title] LIKE N'%cổ tức%' OR n.[title] LIKE N'%ưu đãi%'
           OR n.[title] LIKE N'%thưởng%' OR n.[title] LIKE N'%phát hành%')
),
last_ev AS (
    SELECT e.[ticker], MAX(e.ex_date) AS last_ex_date
    FROM ev e CROSS JOIN stg.stg_scope s
    WHERE e.ex_date BETWEEN s.start_date AND s.end_date
    GROUP BY e.[ticker]
),
g AS (
    SELECT ticker, trade_date,
           CASE WHEN close_price % CASE WHEN close_price < 10 THEN 0.01 WHEN close_price < 50 THEN 0.05 ELSE 0.1 END <> 0
                THEN 1 ELSE 0 END AS off_grid
    FROM stg.stg_price_daily
),
lo AS (
    SELECT ticker, MAX(CASE WHEN off_grid = 1 THEN trade_date END) AS last_off_grid
    FROM g GROUP BY ticker
)
SELECT t.ticker,
       le.last_ex_date,
       (SELECT MAX(c.trade_date) FROM stg.stg_calendar c WHERE c.trade_date < le.last_ex_date)       AS session_before_ex,
       lo.last_off_grid,
       (SELECT COUNT(*) FROM stg.stg_calendar c
         WHERE c.trade_date > lo.last_off_grid AND c.trade_date < le.last_ex_date)                  AS on_grid_gap,
       (SELECT SUM(g.off_grid) FROM g WHERE g.ticker = t.ticker AND g.trade_date >= le.last_ex_date) AS off_grid_from_ex
FROM (SELECT DISTINCT [ticker] AS ticker FROM raw.raw_ticker_config) t
LEFT JOIN last_ev le ON le.[ticker] = t.ticker
LEFT JOIN lo         ON lo.ticker   = t.ticker
ORDER BY t.ticker;

-- 8. The 5 closes before each ticker's latest ex-date, with the grid flag and the distance from the
--    last close before the ex-date. For a cash dividend D the adjusted close is about
--    close * (1 - D / last close before ex). A close near that last close shifts by almost exactly D,
--    so when D is a multiple of the tick it can stay on the grid.
WITH ev AS (
    SELECT DISTINCT n.[ticker], d.ex_date
    FROM raw.raw_ticker_news n
    CROSS APPLY (SELECT SUBSTRING(n.[title], CHARINDEX(N': ', n.[title]) + 2, 10) AS s) a
    CROSS APPLY (SELECT TRY_CONVERT(date, REPLACE(LEFT(a.s, CHARINDEX(N',', a.s + N',') - 1), N'.', N'/'), 103) AS ex_date) d
    WHERE n.[href] LIKE N'%/du-lieu/%'
      AND n.[title] LIKE N'%ngày GDKHQ%'
      AND (n.[title] LIKE N'%cổ tức%' OR n.[title] LIKE N'%ưu đãi%'
           OR n.[title] LIKE N'%thưởng%' OR n.[title] LIKE N'%phát hành%')
),
last_ev AS (
    SELECT e.[ticker], MAX(e.ex_date) AS last_ex_date
    FROM ev e CROSS JOIN stg.stg_scope s
    WHERE e.ex_date BETWEEN s.start_date AND s.end_date
    GROUP BY e.[ticker]
),
b AS (
    SELECT p.ticker, p.trade_date, p.close_price, le.last_ex_date,
           CASE WHEN p.close_price < 10 THEN 0.01 WHEN p.close_price < 50 THEN 0.05 ELSE 0.1 END AS tick,
           ROW_NUMBER() OVER (PARTITION BY p.ticker ORDER BY p.trade_date DESC) AS n_before
    FROM stg.stg_price_daily p
    JOIN last_ev le ON le.[ticker] = p.ticker AND p.trade_date < le.last_ex_date
)
SELECT ticker, last_ex_date, trade_date, n_before, close_price, tick,
       CASE WHEN close_price % tick <> 0 THEN 1 ELSE 0 END AS off_grid,
       CAST(100.0 * (close_price / FIRST_VALUE(close_price) OVER (PARTITION BY ticker ORDER BY n_before) - 1)
            AS decimal(6,2)) AS pct_from_close_before_ex
FROM b
WHERE n_before <= 5
ORDER BY ticker, trade_date;
