-- Does sitemap lastmod land on the same trading session as the real publish time?
--
-- Reaction session rule (draft of reaction_date_key for Phase 5):
--   published before 15:00 -> first trading day on or after that date
--   published at/after 15:00 -> first trading day after that date
-- Trading days come from the VNINDEX bars in raw.raw_calendar.
USE BankingSectorIntelligence;

-- 0. Format checks: every lastmod carries +07:00, every value converts.
SELECT
    SUM(CASE WHEN RIGHT([lastmod], 6) <> N'+07:00' THEN 1 ELSE 0 END)                      AS lastmod_not_plus7,
    SUM(CASE WHEN TRY_CONVERT(datetime2(0), LEFT([lastmod], 19)) IS NULL THEN 1 ELSE 0 END) AS lastmod_bad,
    SUM(CASE WHEN TRY_CONVERT(datetime2(0), [published_time]) IS NULL THEN 1 ELSE 0 END)    AS published_bad
FROM raw.raw_lastmod_sample;

-- 0b. The calendar the session lookup depends on: row count, range, values that don't convert.
SELECT COUNT(*) AS calendar_rows,
       MIN(TRY_CONVERT(datetime2(0), [time])) AS first_bar,
       MAX(TRY_CONVERT(datetime2(0), [time])) AS last_bar,
       SUM(CASE WHEN TRY_CONVERT(datetime2(0), [time]) IS NULL THEN 1 ELSE 0 END) AS time_bad
FROM raw.raw_calendar;

-- 1. Session for each timestamp, per article.
WITH cal AS (
    SELECT CAST(TRY_CONVERT(datetime2(0), [time]) AS date) AS trade_date,
           ROW_NUMBER() OVER (ORDER BY TRY_CONVERT(datetime2(0), [time])) AS session_seq
    FROM raw.raw_calendar
),
s AS (
    SELECT [stratum],
           CAST([stratum_population] AS int)                AS stratum_population,
           [url],
           TRY_CONVERT(datetime2(0), LEFT([lastmod], 19))  AS lastmod_local,
           TRY_CONVERT(datetime2(0), [published_time])     AS published_local
    FROM raw.raw_lastmod_sample
),
eff AS (
    SELECT s.*,
           CASE WHEN CAST(lastmod_local AS time) < '15:00' THEN CAST(lastmod_local AS date)
                ELSE DATEADD(DAY, 1, CAST(lastmod_local AS date)) END   AS lastmod_from_date,
           CASE WHEN CAST(published_local AS time) < '15:00' THEN CAST(published_local AS date)
                ELSE DATEADD(DAY, 1, CAST(published_local AS date)) END AS published_from_date
    FROM s
)
SELECT e.[stratum], e.[url], e.lastmod_local, e.published_local,
       DATEDIFF(MINUTE, e.published_local, e.lastmod_local) AS lastmod_minus_published_min,
       lm.trade_date AS lastmod_session,
       pb.trade_date AS published_session,
       lm.session_seq - pb.session_seq AS session_diff
INTO #per_article
FROM eff e
OUTER APPLY (SELECT TOP (1) c.trade_date, c.session_seq FROM cal c
             WHERE c.trade_date >= e.lastmod_from_date ORDER BY c.trade_date) lm
OUTER APPLY (SELECT TOP (1) c.trade_date, c.session_seq FROM cal c
             WHERE c.trade_date >= e.published_from_date ORDER BY c.trade_date) pb;

SELECT * FROM #per_article ORDER BY [stratum], session_diff DESC;

-- 2. Per stratum: how many articles land on a different session.
SELECT p.[stratum],
       MAX(s.stratum_population)                              AS stratum_population,
       COUNT(*)                                               AS sampled,
       SUM(CASE WHEN p.session_diff <> 0 THEN 1 ELSE 0 END)   AS different_session,
       SUM(CASE WHEN p.session_diff IS NULL THEN 1 ELSE 0 END) AS no_session
FROM #per_article p
JOIN (SELECT DISTINCT [stratum], CAST([stratum_population] AS int) AS stratum_population
      FROM raw.raw_lastmod_sample) s ON s.[stratum] = p.[stratum]
GROUP BY p.[stratum]
ORDER BY p.[stratum];

-- 3. Weighted back to the whole sitemap population: each stratum's share of mismatches
--    counts in proportion to its population, not to its sample size.
WITH per_stratum AS (
    SELECT p.[stratum],
           MAX(CAST(r.[stratum_population] AS float))                                AS pop,
           AVG(CASE WHEN p.session_diff <> 0 THEN 1.0 ELSE 0.0 END)                  AS mismatch_rate
    FROM #per_article p
    JOIN raw.raw_lastmod_sample r ON r.[url] = p.[url]
    WHERE p.session_diff IS NOT NULL
    GROUP BY p.[stratum]
)
SELECT SUM(pop * mismatch_rate) / SUM(pop) AS weighted_mismatch_rate,
       SUM(pop)                            AS population
FROM per_stratum;

DROP TABLE #per_article;
