-- Structure checks for dw.fact_news. Empty until Phase 5 loads it; written now so the grain and the
-- date roles are tested the moment rows arrive.
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
