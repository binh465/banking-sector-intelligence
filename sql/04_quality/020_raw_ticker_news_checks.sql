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

-- 7. Per-ticker list links vs sitemap URLs. The list uses relative links with a utm query string;
--    the sitemap uses https://cafef.vn/... without one. Normalised: cut at '?', prefix the host.
WITH t AS (
    SELECT [ticker],
           CASE WHEN [href] LIKE N'%/du-lieu/%' THEN N'disclosure' ELSE N'article' END AS kind,
           N'https://cafef.vn' + LEFT([href], CHARINDEX(N'?', [href] + N'?') - 1)       AS url_norm,
           TRY_CONVERT(date, LEFT([time_text], 10), 103)                                AS list_date
    FROM raw.raw_ticker_news
),
f AS (
    SELECT t.kind,
           CASE WHEN EXISTS (SELECT 1 FROM raw.raw_article a      WHERE a.[url] = t.url_norm) THEN 1 ELSE 0 END AS in_sitemap,
           CASE WHEN EXISTS (SELECT 1 FROM raw.raw_article_page p WHERE p.[url] = t.url_norm) THEN 1 ELSE 0 END AS page_fetched
    FROM t
    CROSS JOIN stg.stg_scope s
    WHERE t.list_date BETWEEN s.start_date AND s.end_date
)
SELECT kind,
       COUNT(*)          AS items_in_window,
       SUM(in_sitemap)   AS in_sitemap,
       SUM(page_fetched) AS page_fetched
FROM f
GROUP BY kind;

-- 8. Articles from the per-ticker list that are not in the sitemap under the same URL.
--    Does the article ID (the digits between the last '-' and '.chn') appear in the sitemap under
--    another URL, e.g. a slug changed after the title was edited?
--    NULLIF turns "no '-' found" into a NULL length, so RIGHT returns NULL instead of failing.
WITH t AS (
    SELECT [ticker],
           N'https://cafef.vn' + LEFT([href], CHARINDEX(N'?', [href] + N'?') - 1) AS url_norm,
           TRY_CONVERT(date, LEFT([time_text], 10), 103)                          AS list_date
    FROM raw.raw_ticker_news
    WHERE [href] NOT LIKE N'%/du-lieu/%'
),
miss AS (
    SELECT t.*
    FROM t CROSS JOIN stg.stg_scope s
    WHERE t.list_date BETWEEN s.start_date AND s.end_date
      AND NOT EXISTS (SELECT 1 FROM raw.raw_article a WHERE a.[url] = t.url_norm)
),
miss_id AS (
    SELECT m.*, RIGHT(x.stem, NULLIF(CHARINDEX(N'-', REVERSE(x.stem)), 0) - 1) AS article_id
    FROM miss m
    CROSS APPLY (SELECT LEFT(m.url_norm, LEN(m.url_norm) - 4) AS stem) x
),
sitemap_id AS (
    SELECT DISTINCT a.[url], RIGHT(x.stem, NULLIF(CHARINDEX(N'-', REVERSE(x.stem)), 0) - 1) AS article_id
    FROM raw.raw_article a
    CROSS APPLY (SELECT LEFT(a.[url], LEN(a.[url]) - 4) AS stem) x
)
SELECT m.[ticker], m.list_date, m.article_id, m.url_norm, s.[url] AS sitemap_url_same_id
FROM miss_id m
LEFT JOIN sitemap_id s ON s.article_id = m.article_id
ORDER BY CASE WHEN s.[url] IS NULL THEN 1 ELSE 0 END, m.list_date;
