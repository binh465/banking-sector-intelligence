USE BankingSectorIntelligence;

-- 1. Versions per ticker, and tickers in the config without any version.
SELECT c.[ticker],
       COUNT(t.ticker_key)                              AS versions,
       SUM(CAST(t.is_current AS int))                   AS current_versions
FROM (SELECT DISTINCT [ticker] FROM raw.raw_ticker_config) c
LEFT JOIN dw.dim_ticker t ON t.ticker = c.[ticker]
GROUP BY c.[ticker]
ORDER BY c.[ticker];

-- 2. Versions of one ticker must follow each other with no gap and no overlap:
--    next valid_from - 1 day = this valid_to. The day is subtracted from next_from, not added to
--    valid_to: 9999-12-31 + 1 day is out of range for DATE.
WITH v AS (
    SELECT ticker, valid_from, valid_to,
           LEAD(valid_from) OVER (PARTITION BY ticker ORDER BY valid_from) AS next_from
    FROM dw.dim_ticker
)
SELECT ticker, valid_from, valid_to, next_from
FROM v
WHERE next_from IS NOT NULL AND DATEADD(day, -1, next_from) <> valid_to;

-- 3. First version starts on 1900-01-01, last ends on 9999-12-31 (every date has a version).
SELECT ticker, MIN(valid_from) AS first_from, MAX(valid_to) AS last_to
FROM dw.dim_ticker
GROUP BY ticker
HAVING MIN(valid_from) <> '19000101' OR MAX(valid_to) <> '99991231';

-- 4. Every (ticker, trading day) in staging finds exactly one version.
SELECT p.ticker, p.trade_date, COUNT(t.ticker_key) AS matching_versions
FROM stg.stg_price_daily p
LEFT JOIN dw.dim_ticker t
       ON t.ticker = p.ticker AND p.trade_date BETWEEN t.valid_from AND t.valid_to
GROUP BY p.ticker, p.trade_date
HAVING COUNT(t.ticker_key) <> 1;

-- 5. Sessions per version: how the STB rename splits its sessions.
SELECT t.ticker_key, t.ticker, t.full_name, t.valid_from, t.valid_to,
       COUNT(p.trade_date) AS sessions, MIN(p.trade_date) AS first_session, MAX(p.trade_date) AS last_session
FROM dw.dim_ticker t
LEFT JOIN stg.stg_price_daily p
       ON p.ticker = t.ticker AND p.trade_date BETWEEN t.valid_from AND t.valid_to
GROUP BY t.ticker_key, t.ticker, t.full_name, t.valid_from, t.valid_to
ORDER BY t.ticker, t.valid_from;
