USE BankingSectorIntelligence;

-- 1. Items and pages per ticker, with the date range as text.
SELECT [ticker], COUNT(*) AS items, COUNT(DISTINCT [page]) AS pages,
       MIN(TRY_CONVERT(date, [time_text], 103)) AS oldest, MAX(TRY_CONVERT(date, [time_text], 103)) AS newest
FROM raw.raw_ticker_news GROUP BY [ticker] ORDER BY [ticker];

-- 2. Time text that does not parse as dd/mm/yyyy (style 103).
SELECT [ticker], [page], [item_position], [time_text]
FROM raw.raw_ticker_news
WHERE TRY_CONVERT(date, LEFT([time_text], 10), 103) IS NULL;

-- 3. Same link listed twice for the same ticker.
SELECT [ticker], [href], COUNT(*) AS n
FROM raw.raw_ticker_news GROUP BY [ticker], [href] HAVING COUNT(*) > 1;

-- 4. Missing title or link, or no fetch time.
SELECT COUNT(*) AS bad_rows
FROM raw.raw_ticker_news
WHERE [title] IS NULL OR [title] = N'' OR [href] IS NULL OR [fetched_at_utc] IS NULL;

-- 5. Item kinds and date-only items (time 00:00) per ticker.
--    Kind comes from the URL path: disclosures live under /du-lieu/. A LIKE on '-188' is not enough,
--    a disclosure slug can contain it (e.g. 'shb-1882025-ngay-gdkhq-...').
SELECT [ticker],
       SUM(CASE WHEN [href] NOT LIKE N'%/du-lieu/%' THEN 1 ELSE 0 END)   AS articles,
       SUM(CASE WHEN [href] LIKE N'%/du-lieu/%' THEN 1 ELSE 0 END)       AS disclosures,
       SUM(CASE WHEN RIGHT([time_text], 5) = N'00:00' THEN 1 ELSE 0 END) AS date_only
FROM raw.raw_ticker_news GROUP BY [ticker] ORDER BY [ticker];

-- 6. Non-disclosure links that don't look like a CafeF article URL (-188 followed by at least 12 digits).
SELECT [ticker], [page], [item_position], [href]
FROM raw.raw_ticker_news
WHERE [href] NOT LIKE N'%/du-lieu/%'
  AND [href] NOT LIKE N'%-188[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%.chn%';
