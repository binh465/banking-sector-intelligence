-- Superseded by dw.sp_load_dim_article (420_sp_load_dim_article.sql). Kept for history: TRUNCATE fails now that
-- fact_news references dw.dim_article (foreign key), and it would hand out new article_keys.
-- Load dw.dim_article from stg.stg_article (articles) and stg.stg_ticker_news (disclosures).
-- Full reload. As with dim_ticker, TRUNCATE hands out new article_keys: fine until fact_news
-- points here; Phase 4 replaces this with a MERGE on url.
USE BankingSectorIntelligence;
GO
SET XACT_ABORT ON;

-- A URL in both sources would break the unique key on url; stop with a clear message instead.
IF EXISTS (SELECT 1 FROM stg.stg_ticker_news n
           JOIN stg.stg_article a ON a.url = n.url
           WHERE n.item_kind = 'disclosure')
    THROW 50050, N'A disclosure URL is also in stg_article', 1;

BEGIN TRANSACTION;

TRUNCATE TABLE dw.dim_article;

-- d: a disclosure can sit in more than one ticker's list. Keep the row with the earliest listed
--    time (then ticker), and take title and time from that one row.
WITH d AS (
    SELECT n.url, n.title, n.list_time_local, n.is_date_only,
           ROW_NUMBER() OVER (PARTITION BY n.url ORDER BY n.list_time_local, n.ticker) AS rn
    FROM stg.stg_ticker_news n
    WHERE n.item_kind = 'disclosure'
),
items AS (
    SELECT a.url, 'article' AS item_type, a.article_id, a.id_url_count,
           a.sitemap_title AS title, a.og_title, a.publish_time_local, a.time_source,
           CAST(1 AS bit) AS has_time, a.page_fetched
    FROM stg.stg_article a
    UNION ALL
    SELECT d.url, 'disclosure', NULL, NULL,
           d.title, NULL, d.list_time_local, 'list',
           CASE WHEN d.is_date_only = 1 THEN 0 ELSE 1 END, 0
    FROM d
    WHERE d.rn = 1
)
INSERT INTO dw.dim_article (url, item_type, article_id, id_url_count, title, og_title,
                            publish_time_local, time_source, has_time, page_fetched)
SELECT url, item_type, article_id, id_url_count, title, og_title,
       publish_time_local, time_source, has_time, page_fetched
FROM items
ORDER BY publish_time_local, url;

COMMIT TRANSACTION;

SELECT item_type, time_source, COUNT(*) AS n
FROM dw.dim_article
GROUP BY item_type, time_source
ORDER BY item_type, time_source;
GO
