-- dw.sp_load_fact_news: rebuild dw.fact_news from the matching result and the per-ticker disclosure lists.
-- Run after dw.sp_load_dw (dim_article keys) and sql/03_transform/500_match_articles.sql.
--
-- Two sources, one grain (one row per item per bank of the 10):
--   articles     stg.stg_article_bank_match, in-scope banks only; match_tier = best_tier (1-3)
--   disclosures  stg.stg_ticker_news, item_kind = 'disclosure'; match_tier 0 (the bank's own list)
-- banks_mentioned counts every bank tied to the item, the 32 outside banks included, so the sector-news
-- flag sees "VCB, BIDV, Agribank" as three banks. For a disclosure it is the number of lists it is on.
--
-- Dates:
--   publish_date_key   date part of publish_time_local
--   reaction_date_key  first session whose closing price can reflect the item:
--                        has_time = 1, trading day, time before @cutoff -> that day's session
--                        otherwise (later time, non-trading day, or date only) -> next session after that date
--                      NULL when that session is after the window.
--   @cutoff is 14:45, the end of the closing auction (ATC 14:30-14:45). The close is fixed then; the
--   14:45-15:00 slot is put-through trading only and does not move the close.
-- ticker_key: the dim_ticker version valid on the publish date.
-- Items published outside the window have no dim_date row and are left out; the result counts them.
--
-- Full rebuild every run (matching rules change while Phase 5 is open). Same transaction rule as the
-- Phase 4 procedures: open a transaction only when called outside one.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER PROCEDURE dw.sp_load_fact_news
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @cutoff TIME(0) = '14:45';

    IF NOT EXISTS (SELECT 1 FROM stg.stg_article_bank_match)
        THROW 50090, N'stg_article_bank_match is empty: run 500_match_articles.sql first', 1;

    -- Every item-bank pair must find a dim_ticker version on its publish date; an inner join would
    -- drop it silently otherwise.
    IF EXISTS (
        SELECT 1
        FROM (SELECT b.ticker, a.publish_time_local
              FROM stg.stg_article_bank_match m
              JOIN stg.stg_bank b     ON b.bank_id = m.bank_id AND b.in_scope = 1
              JOIN dw.dim_article a   ON a.article_key = m.article_key
              UNION ALL
              SELECT n.ticker, a.publish_time_local
              FROM stg.stg_ticker_news n
              JOIN dw.dim_article a   ON a.url = n.url
              WHERE n.item_kind = 'disclosure') p
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_ticker t
                          WHERE t.ticker = p.ticker
                            AND CAST(p.publish_time_local AS date) BETWEEN t.valid_from AND t.valid_to))
        THROW 50091, N'An item-bank pair has no dim_ticker version on its publish date', 1;

    IF EXISTS (SELECT 1 FROM stg.stg_ticker_news n
               WHERE n.item_kind = 'disclosure'
                 AND NOT EXISTS (SELECT 1 FROM dw.dim_article a WHERE a.url = n.url))
        THROW 50092, N'A staged disclosure is not in dim_article: run dw.sp_load_dw first', 1;

    DECLARE @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @deleted INT, @inserted INT;

    BEGIN TRY
        IF @own_tran = 1 BEGIN TRANSACTION;

        DELETE FROM dw.fact_news;
        SET @deleted = @@ROWCOUNT;

        WITH article_pairs AS (
            -- banks_mentioned is counted before the in-scope filter, over all banks.
            SELECT m.article_key, b.ticker, b.in_scope, m.best_tier AS match_tier,
                   COUNT(*) OVER (PARTITION BY m.article_key) AS banks_mentioned
            FROM stg.stg_article_bank_match m
            JOIN stg.stg_bank b ON b.bank_id = m.bank_id
        ),
        disclosure_pairs AS (
            SELECT a.article_key, n.ticker,
                   COUNT(*) OVER (PARTITION BY n.url) AS banks_mentioned
            FROM stg.stg_ticker_news n
            JOIN dw.dim_article a ON a.url = n.url
            WHERE n.item_kind = 'disclosure'
        ),
        pairs AS (
            SELECT article_key, ticker, match_tier, banks_mentioned
            FROM article_pairs
            WHERE in_scope = 1
            UNION ALL
            SELECT article_key, ticker, CAST(0 AS tinyint), banks_mentioned
            FROM disclosure_pairs
        )
        INSERT INTO dw.fact_news (article_key, ticker_key, publish_date_key, reaction_date_key,
                                  match_tier, banks_mentioned)
        SELECT p.article_key, t.ticker_key, pd.date_key, r.date_key, p.match_tier, p.banks_mentioned
        FROM pairs p
        JOIN dw.dim_article a ON a.article_key = p.article_key
        JOIN dw.dim_date pd   ON pd.full_date  = CAST(a.publish_time_local AS date)   -- drops items outside the window
        JOIN dw.dim_ticker t  ON t.ticker      = p.ticker
                             AND pd.full_date BETWEEN t.valid_from AND t.valid_to
        OUTER APPLY (
            -- First trading day on or after the publish date that the item can still reach.
            -- full_date >= publish date is the range the seek can use; the OR only removes the
            -- publish date itself when the item came too late for that session.
            SELECT TOP (1) d.date_key
            FROM dw.dim_date d
            WHERE d.is_trading_day = 1
              AND d.full_date >= pd.full_date
              AND (d.full_date > pd.full_date
                   OR (a.has_time = 1 AND CAST(a.publish_time_local AS time(0)) < @cutoff))
            ORDER BY d.full_date
        ) r;
        SET @inserted = @@ROWCOUNT;

        IF @own_tran = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own_tran = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    -- Pairs left out because the item was published outside the window.
    SELECT N'fact_news' AS tbl, @deleted AS deleted, @inserted AS inserted,
           (SELECT COUNT(*)
            FROM (SELECT m.article_key
                  FROM stg.stg_article_bank_match m
                  JOIN stg.stg_bank b ON b.bank_id = m.bank_id AND b.in_scope = 1
                  UNION ALL
                  SELECT a.article_key
                  FROM stg.stg_ticker_news n
                  JOIN dw.dim_article a ON a.url = n.url
                  WHERE n.item_kind = 'disclosure') p
            JOIN dw.dim_article a ON a.article_key = p.article_key
            WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date d
                              WHERE d.full_date = CAST(a.publish_time_local AS date))
           ) AS outside_window;
END;
GO
