-- Rebuild test (Phase 12): compare a database rebuilt from empty, following the README run order,
-- with a reference copy of the database as it was before the rebuild.
--
-- Needs two databases on the same instance:
--   BSI_reference              restored from a copy-only backup taken before the rebuild, e.g.
--                                BACKUP DATABASE BankingSectorIntelligence TO DISK = N'bsi_before_rebuild.bak'
--                                    WITH COPY_ONLY, INIT, CHECKSUM;
--                                RESTORE VERIFYONLY FROM DISK = N'bsi_before_rebuild.bak' WITH CHECKSUM;
--                                RESTORE DATABASE BSI_reference FROM DISK = N'bsi_before_rebuild.bak'
--                                    WITH MOVE <data file> TO ..., MOVE <log file> TO ..., CHECKSUM;
--   BankingSectorIntelligence  dropped, then rebuilt with the README "How to run" steps.
--
-- Compares content with EXCEPT both ways on natural keys. Surrogate keys (article_key, ticker_key)
-- and load times (loaded_at_utc) are left out: they may differ between two loads. For tables the
-- primary key rules out duplicate rows; for views the number of distinct keys is counted as well.
-- CTEs are not materialized: each one is evaluated every time it is referenced.
-- Row counts per table, column definitions, the object list and the dq results were compared
-- separately during the rebuild (pipeline_log, Phase 12).
USE master;
GO

WITH
-- =========================================================
-- 1. dw.fact_news
-- Compare using natural keys, not article_key / ticker_key.
-- Keep valid_from to identify the correct SCD2 ticker version.
-- =========================================================
ref_fact_news AS (
    SELECT a.url, t.ticker, t.valid_from,
           f.publish_date_key, f.reaction_date_key,
           f.match_tier, f.banks_mentioned, f.is_sector_news
    FROM BSI_reference.dw.fact_news f
    JOIN BSI_reference.dw.dim_article a
        ON a.article_key = f.article_key
    JOIN BSI_reference.dw.dim_ticker t
        ON t.ticker_key = f.ticker_key
),
reb_fact_news AS (
    SELECT a.url, t.ticker, t.valid_from,
           f.publish_date_key, f.reaction_date_key,
           f.match_tier, f.banks_mentioned, f.is_sector_news
    FROM BankingSectorIntelligence.dw.fact_news f
    JOIN BankingSectorIntelligence.dw.dim_article a
        ON a.article_key = f.article_key
    JOIN BankingSectorIntelligence.dw.dim_ticker t
        ON t.ticker_key = f.ticker_key
),

-- =========================================================
-- 2. mart.v_pbi_ticker_session
-- Exact comparison includes FLOAT columns.
-- Natural key: (ticker, session_seq).
-- =========================================================
ref_ticker_session AS (
    SELECT *
    FROM BSI_reference.mart.v_pbi_ticker_session
),
reb_ticker_session AS (
    SELECT *
    FROM BankingSectorIntelligence.mart.v_pbi_ticker_session
),

-- =========================================================
-- 3. dw.dim_date
-- No surrogate key; compare every column.
-- =========================================================
ref_dim_date AS (
    SELECT *
    FROM BSI_reference.dw.dim_date
),
reb_dim_date AS (
    SELECT *
    FROM BankingSectorIntelligence.dw.dim_date
),

-- =========================================================
-- 4. dw.dim_ticker
-- Exclude ticker_key; compare all descriptive/version columns.
-- Natural key: (ticker, valid_from).
-- =========================================================
ref_dim_ticker AS (
    SELECT ticker, full_name, exchange,
           valid_from, valid_to, is_current
    FROM BSI_reference.dw.dim_ticker
),
reb_dim_ticker AS (
    SELECT ticker, full_name, exchange,
           valid_from, valid_to, is_current
    FROM BankingSectorIntelligence.dw.dim_ticker
),

-- =========================================================
-- 5. dw.dim_article
-- Exclude article_key; url is the natural key.
-- =========================================================
ref_dim_article AS (
    SELECT url, item_type, article_id, id_url_count,
           title, og_title, publish_time_local,
           time_source, has_time, page_fetched
    FROM BSI_reference.dw.dim_article
),
reb_dim_article AS (
    SELECT url, item_type, article_id, id_url_count,
           title, og_title, publish_time_local,
           time_source, has_time, page_fetched
    FROM BankingSectorIntelligence.dw.dim_article
),

-- =========================================================
-- 6. dw.fact_price_daily
-- Replace ticker_key with ticker + valid_from.
-- Keep date_key and all five OHLCV columns.
-- =========================================================
ref_fact_price_daily AS (
    SELECT t.ticker, t.valid_from, f.date_key,
           f.open_price, f.high_price, f.low_price,
           f.close_price, f.volume
    FROM BSI_reference.dw.fact_price_daily f
    JOIN BSI_reference.dw.dim_ticker t
        ON t.ticker_key = f.ticker_key
),
reb_fact_price_daily AS (
    SELECT t.ticker, t.valid_from, f.date_key,
           f.open_price, f.high_price, f.low_price,
           f.close_price, f.volume
    FROM BankingSectorIntelligence.dw.fact_price_daily f
    JOIN BankingSectorIntelligence.dw.dim_ticker t
        ON t.ticker_key = f.ticker_key
),

-- =========================================================
-- 7. stg.stg_precision_label
-- Exclude loaded_at_utc; compare the labels and natural keys.
-- =========================================================
ref_precision_label AS (
    SELECT url, ticker, label_order, stratum, stratum_pairs,
           matched_term, is_correct, is_main_subject,
           case_code, note
    FROM BSI_reference.stg.stg_precision_label
),
reb_precision_label AS (
    SELECT url, ticker, label_order, stratum, stratum_pairs,
           matched_term, is_correct, is_main_subject,
           case_code, note
    FROM BankingSectorIntelligence.stg.stg_precision_label
),

-- =========================================================
-- 8. mart.v_pbi_episode
-- Same view definition; key: episode_key.
-- =========================================================
ref_episode AS (
    SELECT *
    FROM BSI_reference.mart.v_pbi_episode
),
reb_episode AS (
    SELECT *
    FROM BankingSectorIntelligence.mart.v_pbi_episode
),

-- =========================================================
-- 9. mart.v_pbi_episode_news
-- Exclude article_key; use episode_key + url.
-- A no-news placeholder row has a NULL url.
-- =========================================================
ref_episode_news AS (
    SELECT episode_key, match_tier, item_type, title, url,
           publish_time_local, reaction_seq, offset_from_start,
           position
    FROM BSI_reference.mart.v_pbi_episode_news
),
reb_episode_news AS (
    SELECT episode_key, match_tier, item_type, title, url,
           publish_time_local, reaction_seq, offset_from_start,
           position
    FROM BankingSectorIntelligence.mart.v_pbi_episode_news
),

-- =========================================================
-- Combine all comparisons into one result set.
-- rebuild_keys is populated for views where duplicate rows
-- must be checked explicitly.
-- =========================================================
results AS (

    -- 1. dw.fact_news
    SELECT 1 AS sort_order,
           N'dw.fact_news' AS obj,
           (SELECT COUNT_BIG(*) FROM ref_fact_news) AS ref_rows,
           (SELECT COUNT_BIG(*) FROM reb_fact_news) AS rebuild_rows,
           CAST(NULL AS bigint) AS rebuild_keys,
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM ref_fact_news
               EXCEPT
               SELECT * FROM reb_fact_news
           ) x) AS only_in_ref,
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM reb_fact_news
               EXCEPT
               SELECT * FROM ref_fact_news
           ) y) AS only_in_rebuild

    UNION ALL

    -- 2. mart.v_pbi_ticker_session
    SELECT 2,
           N'mart.v_pbi_ticker_session',
           (SELECT COUNT_BIG(*) FROM ref_ticker_session),
           (SELECT COUNT_BIG(*) FROM reb_ticker_session),
           (SELECT COUNT_BIG(*) FROM (
               SELECT DISTINCT ticker, session_seq
               FROM reb_ticker_session
           ) k),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM ref_ticker_session
               EXCEPT
               SELECT * FROM reb_ticker_session
           ) x),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM reb_ticker_session
               EXCEPT
               SELECT * FROM ref_ticker_session
           ) y)

    UNION ALL

    -- 3. dw.dim_date
    SELECT 3,
           N'dw.dim_date',
           (SELECT COUNT_BIG(*) FROM ref_dim_date),
           (SELECT COUNT_BIG(*) FROM reb_dim_date),
           CAST(NULL AS bigint),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM ref_dim_date
               EXCEPT
               SELECT * FROM reb_dim_date
           ) x),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM reb_dim_date
               EXCEPT
               SELECT * FROM ref_dim_date
           ) y)

    UNION ALL

    -- 4. dw.dim_ticker
    SELECT 4,
           N'dw.dim_ticker',
           (SELECT COUNT_BIG(*) FROM ref_dim_ticker),
           (SELECT COUNT_BIG(*) FROM reb_dim_ticker),
           CAST(NULL AS bigint),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM ref_dim_ticker
               EXCEPT
               SELECT * FROM reb_dim_ticker
           ) x),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM reb_dim_ticker
               EXCEPT
               SELECT * FROM ref_dim_ticker
           ) y)

    UNION ALL

    -- 5. dw.dim_article
    SELECT 5,
           N'dw.dim_article',
           (SELECT COUNT_BIG(*) FROM ref_dim_article),
           (SELECT COUNT_BIG(*) FROM reb_dim_article),
           CAST(NULL AS bigint),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM ref_dim_article
               EXCEPT
               SELECT * FROM reb_dim_article
           ) x),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM reb_dim_article
               EXCEPT
               SELECT * FROM ref_dim_article
           ) y)

    UNION ALL

    -- 6. dw.fact_price_daily
    SELECT 6,
           N'dw.fact_price_daily',
           (SELECT COUNT_BIG(*) FROM ref_fact_price_daily),
           (SELECT COUNT_BIG(*) FROM reb_fact_price_daily),
           CAST(NULL AS bigint),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM ref_fact_price_daily
               EXCEPT
               SELECT * FROM reb_fact_price_daily
           ) x),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM reb_fact_price_daily
               EXCEPT
               SELECT * FROM ref_fact_price_daily
           ) y)

    UNION ALL

    -- 7. stg.stg_precision_label
    SELECT 7,
           N'stg.stg_precision_label',
           (SELECT COUNT_BIG(*) FROM ref_precision_label),
           (SELECT COUNT_BIG(*) FROM reb_precision_label),
           CAST(NULL AS bigint),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM ref_precision_label
               EXCEPT
               SELECT * FROM reb_precision_label
           ) x),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM reb_precision_label
               EXCEPT
               SELECT * FROM ref_precision_label
           ) y)

    UNION ALL

    -- 8. mart.v_pbi_episode
    SELECT 8,
           N'mart.v_pbi_episode',
           (SELECT COUNT_BIG(*) FROM ref_episode),
           (SELECT COUNT_BIG(*) FROM reb_episode),
           (SELECT COUNT_BIG(*) FROM (
               SELECT DISTINCT episode_key
               FROM reb_episode
           ) k),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM ref_episode
               EXCEPT
               SELECT * FROM reb_episode
           ) x),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM reb_episode
               EXCEPT
               SELECT * FROM ref_episode
           ) y)

    UNION ALL

    -- 9. mart.v_pbi_episode_news
    SELECT 9,
           N'mart.v_pbi_episode_news',
           (SELECT COUNT_BIG(*) FROM ref_episode_news),
           (SELECT COUNT_BIG(*) FROM reb_episode_news),
           (SELECT COUNT_BIG(*) FROM (
               SELECT DISTINCT episode_key, url
               FROM reb_episode_news
           ) k),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM ref_episode_news
               EXCEPT
               SELECT * FROM reb_episode_news
           ) x),
           (SELECT COUNT_BIG(*) FROM (
               SELECT * FROM reb_episode_news
               EXCEPT
               SELECT * FROM ref_episode_news
           ) y)
)
SELECT obj, ref_rows, rebuild_rows, rebuild_keys,
       only_in_ref, only_in_rebuild
FROM results
ORDER BY sort_order;
GO
