-- Load stg_article and stg_ticker_news from the raw layer.
-- Full reload in one transaction: any error rolls back everything (XACT_ABORT).
-- Needs stg.stg_scope (loaded by 100_load_stg_price.sql).
-- CAST/CONVERT, not TRY_: a value that doesn't convert stops the load instead of becoming NULL.
USE BankingSectorIntelligence;
GO
SET XACT_ABORT ON;

IF (SELECT COUNT(*) FROM stg.stg_scope) <> 1
    THROW 50019, N'stg.stg_scope must hold exactly one row - run 100_load_stg_price.sql first', 1;

-- Casting lastmod to datetime2 drops the offset and keeps the clock time. That is Vietnam time
-- only if every offset is +07:00.
IF EXISTS (SELECT 1 FROM raw.raw_article WHERE RIGHT([lastmod], 6) <> N'+07:00')
    THROW 50020, N'raw.raw_article has a lastmod offset other than +07:00', 1;

-- URL goes into VARCHAR(400). A cast that doesn't fit would cut or change characters without an
-- error, so stop first. The article_id must be digits only.
IF EXISTS (
    SELECT 1
    FROM raw.raw_article a
    CROSS APPLY (SELECT CASE WHEN a.[url] LIKE N'%.chn' THEN LEFT(a.[url], LEN(a.[url]) - 4) END AS stem) x
    CROSS APPLY (SELECT RIGHT(x.stem, NULLIF(CHARINDEX(N'-', REVERSE(x.stem)), 0) - 1) AS article_id) i
    WHERE LEN(a.[url]) > 400
       OR a.[url] COLLATE Latin1_General_BIN2 LIKE N'%[^ -~]%'
       OR i.article_id IS NULL OR i.article_id = N'' OR i.article_id LIKE N'%[^0-9]%' OR LEN(i.article_id) > 20)
    THROW 50021, N'raw.raw_article has a URL that is too long, not ASCII, or without a numeric article id', 1;

IF EXISTS (SELECT [url] FROM raw.raw_article_page GROUP BY [url] HAVING COUNT(*) > 1)
    THROW 50022, N'raw.raw_article_page has the same URL twice', 1;

IF EXISTS (SELECT 1 FROM raw.raw_ticker_news WHERE TRY_CONVERT(datetime2(0), [time_text], 103) IS NULL)
    THROW 50023, N'raw.raw_ticker_news has a time_text that is not dd/mm/yyyy HH:MM', 1;

IF EXISTS (
    SELECT 1 FROM raw.raw_ticker_news
    WHERE [href] NOT LIKE N'/%'
       OR [href] COLLATE Latin1_General_BIN2 LIKE N'%[^ -~]%'
       OR LEN(N'https://cafef.vn' + LEFT([href], CHARINDEX(N'?', [href] + N'?') - 1)) > 400)
    THROW 50024, N'raw.raw_ticker_news has a link that is not relative, not ASCII, or too long', 1;

BEGIN TRANSACTION;

TRUNCATE TABLE stg.stg_article;
TRUNCATE TABLE stg.stg_ticker_news;

-- stg_article.
-- r: every sitemap row, numbered per URL by lastmod (then raw_id). The kept row (rn = 1) gives
--    lastmod, title and source file together; columns are never mixed across rows.
-- u: one row per URL for the whole sitemap, so id_url_count counts all URLs sharing an id,
--    not only those inside the window. The window function runs after WHERE rn = 1.
WITH r AS (
    SELECT a.raw_id, a.[url], a.[title], a.source_file,
           CAST(CAST(a.[lastmod] AS datetimeoffset(0)) AS datetime2(0))                        AS lastmod_local,
           ROW_NUMBER() OVER (PARTITION BY a.[url]
                              ORDER BY CAST(a.[lastmod] AS datetimeoffset(0)), a.raw_id)       AS rn,
           COUNT(*)     OVER (PARTITION BY a.[url])                                            AS sitemap_rows
    FROM raw.raw_article a
),
u AS (
    SELECT r.[url], r.[title], r.source_file, r.lastmod_local, r.sitemap_rows, i.article_id,
           COUNT(*) OVER (PARTITION BY i.article_id) AS id_url_count
    FROM r
    CROSS APPLY (SELECT LEFT(r.[url], LEN(r.[url]) - 4) AS stem) x
    CROSS APPLY (SELECT RIGHT(x.stem, NULLIF(CHARINDEX(N'-', REVERSE(x.stem)), 0) - 1) AS article_id) i
    WHERE r.rn = 1
)
INSERT INTO stg.stg_article (url, article_id, id_url_count, sitemap_title, og_title, lastmod_local,
                             page_published_local, publish_time_local, time_source, page_fetched,
                             sitemap_rows, source_file, page_fetched_at_utc)
SELECT CAST(u.[url] AS varchar(400)),
       CAST(u.article_id AS varchar(20)),
       CAST(u.id_url_count AS smallint),
       LTRIM(RTRIM(u.[title])),
       NULLIF(LTRIM(RTRIM(p.[og_title])), N''),
       u.lastmod_local,
       pt.page_published_local,
       COALESCE(pt.page_published_local, u.lastmod_local),
       CASE WHEN pt.page_published_local IS NOT NULL THEN 'page' ELSE 'lastmod' END,
       CASE WHEN p.[url] IS NOT NULL THEN 1 ELSE 0 END,
       CAST(u.sitemap_rows AS tinyint),
       u.source_file,
       CAST(CAST(p.[fetched_at_utc] AS datetimeoffset(0)) AS datetime2(0))
FROM u
LEFT JOIN raw.raw_article_page p ON p.[url] = u.[url]
CROSS APPLY (SELECT CAST(NULLIF(p.[published_time], N'') AS datetime2(0)) AS page_published_local) pt  -- '' would cast to 1900-01-01
CROSS JOIN stg.stg_scope s
WHERE CAST(COALESCE(pt.page_published_local, u.lastmod_local) AS date) BETWEEN s.start_date AND s.end_date;

-- stg_ticker_news. Only tickers in the config; items dated inside the window.
INSERT INTO stg.stg_ticker_news (ticker, url, item_kind, article_id, list_time_local, is_date_only,
                                 title, page_no, item_position, fetched_at_utc, source_file)
SELECT d.ticker,
       CAST(d.url_norm AS varchar(400)),
       d.item_kind,
       CAST(i.article_id AS varchar(20)),
       d.list_time_local,
       CASE WHEN d.item_kind = 'disclosure' AND CAST(d.list_time_local AS time(0)) = '00:00:00' THEN 1 ELSE 0 END,
       LTRIM(RTRIM(n.[title])),
       CAST(n.[page] AS smallint),
       CAST(n.[item_position] AS smallint),
       CAST(CAST(n.[fetched_at_utc] AS datetimeoffset(0)) AS datetime2(0)),
       n.source_file
FROM raw.raw_ticker_news n
CROSS APPLY (SELECT UPPER(LTRIM(RTRIM(n.[ticker])))                                              AS ticker,
                    N'https://cafef.vn' + LEFT(n.[href], CHARINDEX(N'?', n.[href] + N'?') - 1)   AS url_norm,
                    CASE WHEN n.[href] LIKE N'%/du-lieu/%' THEN 'disclosure' ELSE 'article' END  AS item_kind,
                    CONVERT(datetime2(0), n.[time_text], 103)                                    AS list_time_local) d
CROSS APPLY (SELECT CASE WHEN d.item_kind = 'article' AND d.url_norm LIKE N'%.chn'
                         THEN LEFT(d.url_norm, LEN(d.url_norm) - 4) END AS stem) x
CROSS APPLY (SELECT CASE WHEN x.stem IS NOT NULL
                         THEN RIGHT(x.stem, NULLIF(CHARINDEX(N'-', REVERSE(x.stem)), 0) - 1) END AS article_id) i
JOIN raw.raw_ticker_config c ON c.[ticker] = d.ticker
CROSS JOIN stg.stg_scope s
WHERE CAST(d.list_time_local AS date) BETWEEN s.start_date AND s.end_date;

COMMIT TRANSACTION;

SELECT N'stg_article' AS tbl, COUNT(*) AS n FROM stg.stg_article
UNION ALL SELECT N'stg_ticker_news', COUNT(*) FROM stg.stg_ticker_news;
GO
