USE BankingSectorIntelligence;

-- 1. raw -> stg_article reconciliation. Every distinct raw URL is either in staging, or dated
--    before or after the window by the same time rule the load uses (page time, else lastmod).
WITH u AS (
    SELECT a.[url],
           MIN(CAST(CAST(a.[lastmod] AS datetimeoffset(0)) AS datetime2(0))) AS lastmod_local
    FROM raw.raw_article a
    GROUP BY a.[url]
),
t AS (
    SELECT u.[url], CAST(COALESCE(CAST(p.[published_time] AS datetime2(0)), u.lastmod_local) AS date) AS pub_date
    FROM u LEFT JOIN raw.raw_article_page p ON p.[url] = u.[url]
)
SELECT COUNT(*)                                                                   AS raw_distinct_urls,
       SUM(CASE WHEN t.pub_date < s.start_date THEN 1 ELSE 0 END)                 AS before_window,
       SUM(CASE WHEN t.pub_date > s.end_date   THEN 1 ELSE 0 END)                 AS after_window,
       SUM(CASE WHEN t.pub_date BETWEEN s.start_date AND s.end_date THEN 1 ELSE 0 END) AS in_window,
       (SELECT COUNT(*) FROM stg.stg_article)                                     AS stg_rows
FROM t CROSS JOIN stg.stg_scope s;

-- 2. Time source, page fetched, and the date range.
SELECT time_source, page_fetched, COUNT(*) AS n,
       MIN(publish_time_local) AS first_time, MAX(publish_time_local) AS last_time
FROM stg.stg_article
GROUP BY time_source, page_fetched
ORDER BY time_source, page_fetched;

-- 3. URLs that were listed more than once in the sitemap, and those whose raw rows carry
--    different titles (the kept title is the one on the earliest lastmod row).
WITH f AS (
    SELECT a.sitemap_rows,
           CASE WHEN EXISTS (SELECT 1 FROM raw.raw_article r
                             WHERE r.[url] = a.url AND r.[title] <> a.sitemap_title) THEN 1 ELSE 0 END AS other_title_in_raw
    FROM stg.stg_article a
)
SELECT sitemap_rows, COUNT(*) AS urls, SUM(other_title_in_raw) AS other_title_in_raw
FROM f
GROUP BY sitemap_rows
ORDER BY sitemap_rows;

-- 4. article_id shared by more than one URL. Whole sitemap vs inside the window.
SELECT COUNT(DISTINCT article_id)                                                    AS shared_ids_in_stg,
       COUNT(*)                                                                      AS urls_with_shared_id_in_stg,
       (SELECT COUNT(*) FROM (SELECT DISTINCT article_id FROM stg.stg_article) d)    AS distinct_ids_in_stg
FROM stg.stg_article
WHERE id_url_count > 1;

-- 5. Page time vs lastmod on the pages that have both: how often they fall on different dates,
--    and the spread in hours (lastmod minus page time).
SELECT COUNT(*)                                                                                   AS pages_with_time,
       SUM(CASE WHEN CAST(lastmod_local AS date) <> CAST(page_published_local AS date) THEN 1 ELSE 0 END) AS different_date,
       SUM(CASE WHEN lastmod_local < page_published_local THEN 1 ELSE 0 END)                      AS lastmod_earlier,
       MIN(DATEDIFF(minute, page_published_local, lastmod_local)) / 60.0                          AS min_hours,
       MAX(DATEDIFF(minute, page_published_local, lastmod_local)) / 60.0                          AS max_hours
FROM stg.stg_article
WHERE time_source = 'page';

-- 5b. Same pages, lastmod minus page time in buckets. Page times carry no seconds (hh:mm:00), so a
--     lastmod a few seconds before the page time lands in the first negative bucket.
SELECT b.bucket, COUNT(*) AS pages,
       SUM(CASE WHEN CAST(a.lastmod_local AS date) <> CAST(a.page_published_local AS date) THEN 1 ELSE 0 END) AS different_date
FROM stg.stg_article a
CROSS APPLY (SELECT DATEDIFF(second, a.page_published_local, a.lastmod_local) AS diff_s) d
CROSS APPLY (SELECT CASE WHEN d.diff_s <  -3600  THEN N'1: lastmod > 1 h earlier'
                         WHEN d.diff_s <  -60    THEN N'2: lastmod 1 min to 1 h earlier'
                         WHEN d.diff_s <   0     THEN N'3: lastmod < 1 min earlier'
                         WHEN d.diff_s <   3600  THEN N'4: 0 to 1 h later'
                         WHEN d.diff_s <   86400 THEN N'5: 1 h to 24 h later'
                         ELSE                         N'6: 24 h or more later' END AS bucket) b
WHERE a.time_source = 'page'
GROUP BY b.bucket
ORDER BY b.bucket;

-- 5c. The 10 largest gaps in each direction.
SELECT TOP (10) N'lastmod earlier' AS side, url, page_published_local, lastmod_local,
       DATEDIFF(minute, page_published_local, lastmod_local) / 60.0 AS hours, sitemap_title
FROM stg.stg_article WHERE time_source = 'page'
ORDER BY DATEDIFF(minute, page_published_local, lastmod_local) ASC;
SELECT TOP (10) N'lastmod later' AS side, url, page_published_local, lastmod_local,
       DATEDIFF(minute, page_published_local, lastmod_local) / 60.0 AS hours, sitemap_title
FROM stg.stg_article WHERE time_source = 'page'
ORDER BY DATEDIFF(minute, page_published_local, lastmod_local) DESC;

-- 6. Titles with combining marks (not NFC). The database collation compares them as equal
--    (040_raw_article_checks.sql, query 7b); counted here so Phase 5 can re-test exactly these rows.
SELECT SUM(CASE WHEN sitemap_title COLLATE Latin1_General_BIN2 LIKE N'%[' + NCHAR(0x0300) + N'-' + NCHAR(0x036F) + N']%' THEN 1 ELSE 0 END) AS sitemap_title_not_nfc,
       SUM(CASE WHEN og_title      COLLATE Latin1_General_BIN2 LIKE N'%[' + NCHAR(0x0300) + N'-' + NCHAR(0x036F) + N']%' THEN 1 ELSE 0 END) AS og_title_not_nfc
FROM stg.stg_article;

-- 7. stg_ticker_news per ticker: articles, disclosures, date-only disclosures, date range.
SELECT ticker,
       SUM(CASE WHEN item_kind = 'article'    THEN 1 ELSE 0 END) AS articles,
       SUM(CASE WHEN item_kind = 'disclosure' THEN 1 ELSE 0 END) AS disclosures,
       SUM(CAST(is_date_only AS int))                            AS date_only,
       MIN(list_time_local) AS first_time, MAX(list_time_local) AS last_time
FROM stg.stg_ticker_news
GROUP BY ticker
ORDER BY ticker;

-- 8. raw -> stg_ticker_news reconciliation (items dated inside the window, tickers in the config).
SELECT (SELECT COUNT(*) FROM raw.raw_ticker_news n CROSS JOIN stg.stg_scope s
         WHERE CAST(CONVERT(datetime2(0), n.[time_text], 103) AS date) BETWEEN s.start_date AND s.end_date) AS raw_in_window,
       (SELECT COUNT(*) FROM stg.stg_ticker_news)                                                        AS stg_rows;

-- 9. Articles from the per-ticker list against stg_article: matched by URL, by article_id where
--    the id belongs to one URL only, or not matched. Counted per (ticker, url) row and per article.
WITH m AS (
    SELECT n.ticker, n.url, n.article_id,
           CASE WHEN EXISTS (SELECT 1 FROM stg.stg_article a WHERE a.url = n.url) THEN 'by_url'
                WHEN EXISTS (SELECT 1 FROM stg.stg_article a
                             WHERE a.article_id = n.article_id AND a.id_url_count = 1) THEN 'by_article_id'
                ELSE 'not_matched' END AS match_type
    FROM stg.stg_ticker_news n
    WHERE n.item_kind = 'article'
)
SELECT match_type, COUNT(*) AS ticker_rows, COUNT(DISTINCT article_id) AS articles
FROM m
GROUP BY match_type
ORDER BY match_type;

-- 9b. The not-matched rows.
SELECT n.ticker, n.list_time_local, n.article_id, n.url
FROM stg.stg_ticker_news n
WHERE n.item_kind = 'article'
  AND NOT EXISTS (SELECT 1 FROM stg.stg_article a WHERE a.url = n.url)
  AND NOT EXISTS (SELECT 1 FROM stg.stg_article a WHERE a.article_id = n.article_id AND a.id_url_count = 1)
ORDER BY n.list_time_local;
