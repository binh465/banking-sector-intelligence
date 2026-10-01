USE BankingSectorIntelligence;

-- 1. Rows per source vs staging.
SELECT (SELECT COUNT(*) FROM dw.dim_article WHERE item_type = 'article')                        AS dim_articles,
       (SELECT COUNT(*) FROM stg.stg_article)                                                   AS stg_articles,
       (SELECT COUNT(*) FROM dw.dim_article WHERE item_type = 'disclosure')                     AS dim_disclosures,
       (SELECT COUNT(DISTINCT url) FROM stg.stg_ticker_news WHERE item_kind = 'disclosure')     AS stg_disclosure_urls,
       (SELECT COUNT(*) FROM stg.stg_ticker_news WHERE item_kind = 'disclosure')                AS stg_disclosure_rows;

-- 2. Disclosure URLs listed under more than one ticker.
SELECT url, COUNT(*) AS tickers, MIN(ticker) AS ticker_a, MAX(ticker) AS ticker_b, MIN(title) AS title
FROM stg.stg_ticker_news
WHERE item_kind = 'disclosure'
GROUP BY url
HAVING COUNT(*) > 1;

-- 3. Every staging URL is in dim_article, and nothing else is.
SELECT N'stg_article not in dim' AS issue, COUNT(*) AS n
FROM stg.stg_article a WHERE NOT EXISTS (SELECT 1 FROM dw.dim_article d WHERE d.url = a.url)
UNION ALL
SELECT N'stg disclosure not in dim', COUNT(*)
FROM (SELECT DISTINCT url FROM stg.stg_ticker_news WHERE item_kind = 'disclosure') n
WHERE NOT EXISTS (SELECT 1 FROM dw.dim_article d WHERE d.url = n.url)
UNION ALL
SELECT N'dim row with no staging source', COUNT(*)
FROM dw.dim_article d
WHERE NOT EXISTS (SELECT 1 FROM stg.stg_article a WHERE a.url = d.url)
  AND NOT EXISTS (SELECT 1 FROM stg.stg_ticker_news n WHERE n.url = d.url AND n.item_kind = 'disclosure');

-- 4. Time source and date-only items per type, with the time range.
SELECT item_type, time_source, has_time, COUNT(*) AS n,
       MIN(publish_time_local) AS first_time, MAX(publish_time_local) AS last_time
FROM dw.dim_article
GROUP BY item_type, time_source, has_time
ORDER BY item_type, time_source, has_time;

-- 5. Every item falls on a date in dim_date.
SELECT COUNT(*) AS items_outside_dim_date
FROM dw.dim_article a
WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date d WHERE d.full_date = CAST(a.publish_time_local AS date));
