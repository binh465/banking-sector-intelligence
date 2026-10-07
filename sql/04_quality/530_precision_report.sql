-- Precision report for the hand-labelled sample (stg.stg_precision_label).
--   1. Per stratum: match precision and usable pair precision, each with a 95% Wilson interval.
--   2. Weighted overall figures, strata weighted by their size when sampled: all pairs, articles only.
--   3. Automatic sector flag (dw.fact_news.is_sector_news) against the human is_main_subject label,
--      correct matches only.
--   3b. Labelled pairs that no longer have a fact_news row.
-- Definitions: decisions.md, 2026-10-03 (precision sample, two measures).
USE BankingSectorIntelligence;
GO

DECLARE @z float = 1.96;   -- 95% interval

-- 1. Per stratum ---------------------------------------------------------------------------------
DROP TABLE IF EXISTS #precision_stratum;

WITH counts AS (
    SELECT stratum,
           COUNT(*)                                                                AS n,
           SUM(CASE WHEN is_correct = 1 THEN 1 ELSE 0 END)                          AS k_match,
           SUM(CASE WHEN is_correct = 1 AND is_main_subject = 1 THEN 1 ELSE 0 END)  AS k_usable,
           MAX(stratum_pairs)                                                       AS stratum_pairs
    FROM stg.stg_precision_label
    GROUP BY stratum
),
props AS (
    SELECT stratum, n, stratum_pairs, k_match, k_usable,
           CAST(k_match  AS float) / n AS p_match,
           CAST(k_usable AS float) / n AS p_usable,
           @z * @z / n                 AS z2n          -- z^2 / n, used in every Wilson term
    FROM counts
),
wilson AS (
    -- center = (p + z^2/2n) / (1 + z^2/n)
    -- half   = z * sqrt(p(1-p)/n + z^2/4n^2) / (1 + z^2/n);   z^2/4n^2 = z2n / 4n
    SELECT stratum, n, stratum_pairs, k_match, p_match, k_usable, p_usable,
           (p_match + z2n / 2) / (1 + z2n)                                       AS match_center,
           @z * SQRT(p_match * (1 - p_match) / n + z2n / (4 * n)) / (1 + z2n)    AS match_half,
           (p_usable + z2n / 2) / (1 + z2n)                                      AS usable_center,
           @z * SQRT(p_usable * (1 - p_usable) / n + z2n / (4 * n)) / (1 + z2n)  AS usable_half
    FROM props
)
SELECT stratum, n, stratum_pairs,
       k_match,  p_match,  match_center  - match_half  AS match_ci_lower,  match_center  + match_half  AS match_ci_upper,
       k_usable, p_usable, usable_center - usable_half AS usable_ci_lower, usable_center + usable_half AS usable_ci_upper
INTO #precision_stratum
FROM wilson;

SELECT stratum, n, stratum_pairs,
       k_match,
       ROUND(p_match, 4)         AS p_match,
       ROUND(match_ci_lower, 4)  AS match_ci_lower,
       ROUND(match_ci_upper, 4)  AS match_ci_upper,
       k_usable,
       ROUND(p_usable, 4)        AS p_usable,
       ROUND(usable_ci_lower, 4) AS usable_ci_lower,
       ROUND(usable_ci_upper, 4) AS usable_ci_upper
FROM #precision_stratum
ORDER BY stratum;   -- t0_disclosure, t1_ticker, t2_mb, t2_other

-- 2. Weighted overall ---------------------------------------------------------------------------
-- Each stratum appears once under 'all' and, if it is an article stratum, once more under 'articles'.
SELECT s.scope,
       SUM(p.n)                                                            AS labelled,
       SUM(p.stratum_pairs)                                                AS population_pairs,
       ROUND(SUM(p.stratum_pairs * p.p_match)  / SUM(p.stratum_pairs), 4)  AS p_match_weighted,
       ROUND(SUM(p.stratum_pairs * p.p_usable) / SUM(p.stratum_pairs), 4)  AS p_usable_weighted
FROM #precision_stratum p
CROSS APPLY (VALUES ('all'),
                    (CASE WHEN p.stratum <> 't0_disclosure' THEN 'articles' END)) AS s(scope)
WHERE s.scope IS NOT NULL
GROUP BY s.scope
ORDER BY s.scope;

-- 3. Sector flag vs human label, correct matches only --------------------------------------------
-- t.ticker = l.ticker keeps one fact row per labelled pair: an article has one fact row per bank.
SELECT f.is_sector_news,
       l.is_main_subject,
       COUNT(*) AS pairs
FROM stg.stg_precision_label l
JOIN dw.dim_article a ON a.url = l.url
JOIN dw.fact_news   f ON f.article_key = a.article_key
JOIN dw.dim_ticker  t ON t.ticker_key = f.ticker_key
                     AND t.ticker = l.ticker
WHERE l.is_correct = 1
GROUP BY f.is_sector_news, l.is_main_subject
ORDER BY f.is_sector_news, l.is_main_subject;

-- 3b. Labelled pairs without a fact_news row (0 while the matching rules are the sampled ones).
SELECT l.label_order, l.stratum, l.ticker, l.url
FROM stg.stg_precision_label l
WHERE NOT EXISTS (SELECT 1
                  FROM dw.dim_article a
                  JOIN dw.fact_news  f ON f.article_key = a.article_key
                  JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
                  WHERE a.url = l.url AND t.ticker = l.ticker);
GO