-- Agreement of the title rules with CafeF's per-ticker article lists (stg.stg_ticker_news,
-- item_kind = 'article'). Not a true recall: CafeF tags by the article body while the rules read
-- the title only, and a ticker's list can carry another bank's item.
--   1. Per ticker: where each list article ends up.
--   2. List articles not matched to their own ticker, with the banks found in the title, for reading.
USE BankingSectorIntelligence;
GO

-- 1. Per ticker ----------------------------------------------------------------------------------
WITH list AS (
    SELECT n.ticker, n.url, a.article_key,
           CASE WHEN EXISTS (SELECT 1 FROM dw.dim_date d
                             WHERE d.full_date = CAST(n.list_time_local AS date))
                THEN 1 ELSE 0 END AS in_window
    FROM stg.stg_ticker_news n
    LEFT JOIN dw.dim_article a ON a.url = n.url AND a.item_type = 'article'
    WHERE n.item_kind = 'article'
),
outcome AS (
    SELECT l.ticker,
           CASE WHEN l.in_window = 0                  THEN 'outside_window'
                WHEN l.article_key IS NULL            THEN 'not_in_sitemap'
                WHEN EXISTS (SELECT 1 FROM stg.stg_article_bank_match m
                             WHERE m.article_key = l.article_key AND m.bank_id = l.ticker)
                                                      THEN 'matched'
                WHEN EXISTS (SELECT 1 FROM stg.stg_article_bank_match m
                             WHERE m.article_key = l.article_key)
                                                      THEN 'other_banks_only'
                ELSE 'no_bank' END AS outcome
    FROM list l
)
SELECT ticker,
       COUNT(*)                                                        AS list_articles,
       SUM(CASE WHEN outcome = 'outside_window'   THEN 1 ELSE 0 END)   AS outside_window,
       SUM(CASE WHEN outcome = 'not_in_sitemap'   THEN 1 ELSE 0 END)   AS not_in_sitemap,
       SUM(CASE WHEN outcome = 'matched'          THEN 1 ELSE 0 END)   AS matched,
       SUM(CASE WHEN outcome = 'other_banks_only' THEN 1 ELSE 0 END)   AS other_banks_only,
       SUM(CASE WHEN outcome = 'no_bank'          THEN 1 ELSE 0 END)   AS no_bank
FROM outcome
GROUP BY ROLLUP (ticker)          -- last row (ticker NULL) = all tickers
ORDER BY GROUPING(ticker), ticker;

-- 2. Not matched to their own ticker: titles to read ----------------------------------------------
SELECT n.ticker, a.article_key, a.publish_time_local, a.title,
       (SELECT STRING_AGG(m.bank_id, ', ') WITHIN GROUP (ORDER BY m.bank_id)
        FROM stg.stg_article_bank_match m
        WHERE m.article_key = a.article_key) AS banks_in_title
FROM stg.stg_ticker_news n
JOIN dw.dim_article a ON a.url = n.url AND a.item_type = 'article'
WHERE n.item_kind = 'article'
  AND NOT EXISTS (SELECT 1 FROM stg.stg_article_bank_match m
                  WHERE m.article_key = a.article_key AND m.bank_id = n.ticker)
ORDER BY n.ticker, a.publish_time_local;
GO