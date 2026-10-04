-- Checks for dw.fact_news, loaded by sql/03_transform/510_sp_load_fact_news.sql.
-- 1-5 structure (written in Phase 3); 6-12 load and reaction-session rule (Phase 5).
USE BankingSectorIntelligence;

-- 1. Grain: one row per item per bank, grouped by the durable ticker (two versions of STB on one
--    item would pass the primary key).
SELECT f.article_key, t.ticker, COUNT(*) AS n
FROM dw.fact_news f
JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
GROUP BY f.article_key, t.ticker
HAVING COUNT(*) > 1;

-- 2. publish_date_key is the item's own publish date.
SELECT f.article_key, a.publish_time_local, d.full_date AS publish_date_in_fact
FROM dw.fact_news f
JOIN dw.dim_article a ON a.article_key = f.article_key
JOIN dw.dim_date    d ON d.date_key    = f.publish_date_key
WHERE d.full_date <> CAST(a.publish_time_local AS date);

-- 3. reaction_date_key, when set, is a trading day.
SELECT f.article_key, d.full_date
FROM dw.fact_news f
JOIN dw.dim_date d ON d.date_key = f.reaction_date_key
WHERE d.is_trading_day = 0;

-- 4. ticker_key is the version valid on the publish date.
SELECT f.article_key, t.ticker, d.full_date, t.valid_from, t.valid_to
FROM dw.fact_news f
JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
JOIN dw.dim_date   d ON d.date_key   = f.publish_date_key
WHERE d.full_date NOT BETWEEN t.valid_from AND t.valid_to;

-- 5. Rows, items and reaction sessions per tier and sector flag.
SELECT match_tier, is_sector_news, COUNT(*) AS item_bank_rows, COUNT(DISTINCT article_key) AS items,
       SUM(CASE WHEN reaction_date_key IS NULL THEN 1 ELSE 0 END) AS no_reaction_session
FROM dw.fact_news
GROUP BY match_tier, is_sector_news
ORDER BY match_tier, is_sector_news;

-- 6. Reconciliation: every in-scope match pair and every disclosure-list pair is in the fact, except
--    items published outside the window. Both columns of each row should agree.
WITH src AS (
    SELECT m.article_key, b.ticker
    FROM stg.stg_article_bank_match m
    JOIN stg.stg_bank b ON b.bank_id = m.bank_id AND b.in_scope = 1
    UNION ALL
    SELECT a.article_key, n.ticker
    FROM stg.stg_ticker_news n
    JOIN dw.dim_article a ON a.url = n.url
    WHERE n.item_kind = 'disclosure'
),
src_in_window AS (
    SELECT s.article_key, s.ticker
    FROM src s
    JOIN dw.dim_article a ON a.article_key = s.article_key
    WHERE EXISTS (SELECT 1 FROM dw.dim_date d WHERE d.full_date = CAST(a.publish_time_local AS date))
),
fact AS (
    SELECT f.article_key, t.ticker
    FROM dw.fact_news f
    JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
)
SELECT N'staging pairs not in fact' AS side, COUNT(*) AS n
FROM (SELECT article_key, ticker FROM src_in_window EXCEPT SELECT article_key, ticker FROM fact) x
UNION ALL
SELECT N'fact pairs not in staging', COUNT(*)
FROM (SELECT article_key, ticker FROM fact EXCEPT SELECT article_key, ticker FROM src_in_window) y;

-- 7. Same-day reaction only when the rule allows it: trading day, time known, before 14:45.
SELECT f.article_key, a.item_type, a.publish_time_local, a.has_time, pd.is_trading_day
FROM dw.fact_news f
JOIN dw.dim_article a ON a.article_key = f.article_key
JOIN dw.dim_date pd   ON pd.date_key   = f.publish_date_key
WHERE f.reaction_date_key = f.publish_date_key
  AND NOT (pd.is_trading_day = 1 AND a.has_time = 1
           AND CAST(a.publish_time_local AS time(0)) < '14:45');

-- 8. No session skipped: no trading day strictly between the publish date and the reaction session,
--    and a publish date that was itself a usable session is never pushed to the next one.
SELECT f.article_key, a.publish_time_local, a.has_time, rd.full_date AS reaction_date
FROM dw.fact_news f
JOIN dw.dim_article a ON a.article_key = f.article_key
JOIN dw.dim_date pd   ON pd.date_key   = f.publish_date_key
JOIN dw.dim_date rd   ON rd.date_key   = f.reaction_date_key
WHERE EXISTS (SELECT 1 FROM dw.dim_date d
              WHERE d.is_trading_day = 1 AND d.full_date > pd.full_date AND d.full_date < rd.full_date)
   OR (rd.full_date > pd.full_date AND pd.is_trading_day = 1 AND a.has_time = 1
       AND CAST(a.publish_time_local AS time(0)) < '14:45');

-- 9. NULL reaction only when no usable session is left in the window.
SELECT f.article_key, a.publish_time_local
FROM dw.fact_news f
JOIN dw.dim_article a ON a.article_key = f.article_key
JOIN dw.dim_date pd   ON pd.date_key   = f.publish_date_key
WHERE f.reaction_date_key IS NULL
  AND EXISTS (SELECT 1 FROM dw.dim_date d
              WHERE d.is_trading_day = 1
                AND (d.full_date > pd.full_date
                     OR (d.full_date = pd.full_date AND a.has_time = 1
                         AND CAST(a.publish_time_local AS time(0)) < '14:45')));

-- 10. Where the reaction session falls, per item type and time knowledge (distinct items, so an item
--     tied to two banks counts once).
WITH i AS (
    SELECT DISTINCT f.article_key, a.item_type, a.has_time,
           CASE WHEN f.reaction_date_key IS NULL               THEN '3 after window'
                WHEN f.reaction_date_key = f.publish_date_key  THEN '1 same day'
                ELSE '2 later session' END AS reaction
    FROM dw.fact_news f
    JOIN dw.dim_article a ON a.article_key = f.article_key
)
SELECT item_type, has_time, reaction, COUNT(*) AS items
FROM i
GROUP BY item_type, has_time, reaction
ORDER BY item_type, has_time, reaction;

-- 11. Items the cutoff choice moves: timed items on a trading day between 14:45 and 15:00.
--     With a 15:00 cutoff these would react the same day; with 14:45 they react the next session.
SELECT COUNT(DISTINCT f.article_key) AS items_14_45_to_15_00
FROM dw.fact_news f
JOIN dw.dim_article a ON a.article_key = f.article_key
JOIN dw.dim_date pd   ON pd.date_key   = f.publish_date_key
WHERE pd.is_trading_day = 1 AND a.has_time = 1
  AND CAST(a.publish_time_local AS time(0)) >= '14:45'
  AND CAST(a.publish_time_local AS time(0)) <  '15:00';

-- 12. Per bank: item-bank rows, rows not flagged as sector news (usable in Phase 7), sector rows,
--     disclosures.
SELECT t.ticker,
       COUNT(*) AS items,
       SUM(CASE WHEN f.is_sector_news = 0 THEN 1 ELSE 0 END) AS not_sector,
       SUM(CASE WHEN f.is_sector_news = 1 THEN 1 ELSE 0 END) AS sector,
       SUM(CASE WHEN f.match_tier = 0 THEN 1 ELSE 0 END)     AS disclosures
FROM dw.fact_news f
JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
GROUP BY t.ticker
ORDER BY t.ticker;
