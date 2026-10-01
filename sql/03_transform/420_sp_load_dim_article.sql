-- dw.sp_load_dim_article: sync dw.dim_article with stg.stg_article and stg.stg_ticker_news (Type 1).
--   new url            -> insert (new article_key)
--   changed attributes -> overwrite in place, article_key kept
--   url gone from staging -> kept (fact_news may point to it); counted in the result
-- Same transaction rule as sp_load_dim_date.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER PROCEDURE dw.sp_load_dim_article
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM stg.stg_ticker_news n
               JOIN stg.stg_article a ON a.url = n.url
               WHERE n.item_kind = 'disclosure')
        THROW 50050, N'A disclosure URL is also in stg_article', 1;

    DECLARE @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @actions TABLE (act NVARCHAR(10));

    BEGIN TRY
        IF @own_tran = 1 BEGIN TRANSACTION;

        WITH d AS (
            SELECT n.url, n.title, n.list_time_local, n.is_date_only,
                   ROW_NUMBER() OVER (PARTITION BY n.url ORDER BY n.list_time_local, n.ticker) AS rn
            FROM stg.stg_ticker_news n
            WHERE n.item_kind = 'disclosure'
        ),
        src AS (
            SELECT a.url, CAST('article' AS varchar(10)) AS item_type, a.article_id, a.id_url_count,
                   a.sitemap_title AS title, a.og_title, a.publish_time_local,
                   CAST(a.time_source AS varchar(10)) AS time_source, CAST(1 AS bit) AS has_time, a.page_fetched
            FROM stg.stg_article a
            UNION ALL
            SELECT d.url, 'disclosure', NULL, NULL, d.title, NULL, d.list_time_local, 'list',
                   CAST(CASE WHEN d.is_date_only = 1 THEN 0 ELSE 1 END AS bit), CAST(0 AS bit)
            FROM d
            WHERE d.rn = 1
        )
        MERGE dw.dim_article WITH (HOLDLOCK) AS tgt
        USING src
           ON tgt.url = src.url
        -- EXCEPT compares the column lists NULL-safely (og_title, article_id can be NULL).
        WHEN MATCHED AND EXISTS (SELECT tgt.item_type, tgt.article_id, tgt.id_url_count, tgt.title, tgt.og_title,
                                        tgt.publish_time_local, tgt.time_source, tgt.has_time, tgt.page_fetched
                                 EXCEPT
                                 SELECT src.item_type, src.article_id, src.id_url_count, src.title, src.og_title,
                                        src.publish_time_local, src.time_source, src.has_time, src.page_fetched)
            THEN UPDATE SET tgt.item_type          = src.item_type,
                            tgt.article_id         = src.article_id,
                            tgt.id_url_count       = src.id_url_count,
                            tgt.title              = src.title,
                            tgt.og_title           = src.og_title,
                            tgt.publish_time_local = src.publish_time_local,
                            tgt.time_source        = src.time_source,
                            tgt.has_time           = src.has_time,
                            tgt.page_fetched       = src.page_fetched
        WHEN NOT MATCHED BY TARGET
            THEN INSERT (url, item_type, article_id, id_url_count, title, og_title,
                         publish_time_local, time_source, has_time, page_fetched)
                 VALUES (src.url, src.item_type, src.article_id, src.id_url_count, src.title, src.og_title,
                         src.publish_time_local, src.time_source, src.has_time, src.page_fetched)
        OUTPUT $action INTO @actions;

        IF @own_tran = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own_tran = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT N'dim_article' AS tbl,
           COUNT(CASE WHEN act = N'INSERT' THEN 1 END)   AS inserted,
           COUNT(CASE WHEN act = N'UPDATE' THEN 1 END)   AS updated,
           (SELECT COUNT(*) FROM dw.dim_article t
             WHERE NOT EXISTS (SELECT 1 FROM stg.stg_article a WHERE a.url = t.url)
               AND NOT EXISTS (SELECT 1 FROM stg.stg_ticker_news n WHERE n.url = t.url AND n.item_kind = 'disclosure')
           ) AS not_in_staging
    FROM @actions;
END;
GO
