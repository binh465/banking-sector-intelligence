-- Checks and reading samples for stg.stg_article_bank_match.
USE BankingSectorIntelligence;

-- 1. Per in-scope bank: matched articles by best tier.
SELECT m.bank_id,
       SUM(CASE WHEN m.best_tier = 1 THEN 1 ELSE 0 END) AS tier1,
       SUM(CASE WHEN m.best_tier = 2 THEN 1 ELSE 0 END) AS tier2,
       SUM(CASE WHEN m.best_tier = 3 THEN 1 ELSE 0 END) AS tier3,
       COUNT(*) AS articles
FROM stg.stg_article_bank_match m
JOIN stg.stg_bank b ON b.bank_id = m.bank_id AND b.in_scope = 1
GROUP BY m.bank_id
ORDER BY m.bank_id;

-- 2. Which terms do the work: matches per term (in-scope banks).
SELECT m.bank_id, m.best_tier, m.matched_term, COUNT(*) AS articles
FROM stg.stg_article_bank_match m
JOIN stg.stg_bank b ON b.bank_id = m.bank_id AND b.in_scope = 1
GROUP BY m.bank_id, m.best_tier, m.matched_term
ORDER BY m.bank_id, articles DESC;

-- 3. Banks named per article (all banks, in scope or not): the input of the sector-news flag.
SELECT banks_mentioned, COUNT(*) AS articles,
       SUM(has_in_scope) AS articles_with_an_in_scope_bank
FROM (SELECT article_key, COUNT(*) AS banks_mentioned,
             MAX(CASE WHEN b.in_scope = 1 THEN 1 ELSE 0 END) AS has_in_scope
      FROM stg.stg_article_bank_match m
      JOIN stg.stg_bank b ON b.bank_id = m.bank_id
      GROUP BY article_key) x
GROUP BY banks_mentioned
ORDER BY banks_mentioned;

-- 4. Reading sample: 5 random titles per in-scope bank and tier. NEWID() gives a new order each
--    run; this is for a first look, not the precision sample (that one needs a fixed seed).
WITH s AS (
    SELECT m.bank_id, m.best_tier, m.matched_term, a.title,
           ROW_NUMBER() OVER (PARTITION BY m.bank_id, m.best_tier ORDER BY NEWID()) AS rn
    FROM stg.stg_article_bank_match m
    JOIN stg.stg_bank b    ON b.bank_id = m.bank_id AND b.in_scope = 1
    JOIN dw.dim_article a  ON a.article_key = m.article_key
)
SELECT bank_id, best_tier, matched_term, title
FROM s
WHERE rn <= 5
ORDER BY bank_id, best_tier, rn;

-- 5. Where the publish time of matched articles comes from (in-scope banks only).
--    lastmod-timed matches are reported apart in Phase 7 (lastmod can be days early, pipeline_log 2.5).
SELECT a.time_source, COUNT(DISTINCT m.article_key) AS articles, COUNT(*) AS article_bank_pairs
FROM stg.stg_article_bank_match m
JOIN stg.stg_bank b   ON b.bank_id = m.bank_id AND b.in_scope = 1
JOIN dw.dim_article a ON a.article_key = m.article_key
GROUP BY a.time_source;

-- 6. Every tier-3 match ("MB" + context word), to read through before the precision sample.
SELECT a.title
FROM stg.stg_article_bank_match m
JOIN dw.dim_article a ON a.article_key = m.article_key
WHERE m.best_tier = 3
ORDER BY a.publish_time_local;

-- 7. Articles naming 7 banks: the spike in query 3. What kind of articles are they?
SELECT TOP (20) a.publish_time_local, a.title
FROM dw.dim_article a
WHERE a.article_key IN (SELECT article_key FROM stg.stg_article_bank_match
                        GROUP BY article_key HAVING COUNT(*) = 7)
ORDER BY a.publish_time_local;

-- 8. Recall check for the weak alias: titles with "MB" (upper case, whole word) that were NOT matched
--    to MBB because they have no context word. Split by whether another bank is named in the title.
WITH mb AS (
    SELECT a.article_key, a.title
    FROM dw.dim_article a
    WHERE a.item_type = 'article'
      AND (N' ' + TRANSLATE(a.title, N',.:;!?()"“”‘’[]…|/«»*+=#@', N'                         ') + N' ')
          COLLATE Latin1_General_BIN2 LIKE N'% MB %'
      AND NOT EXISTS (SELECT 1 FROM stg.stg_article_bank_match m
                      WHERE m.article_key = a.article_key AND m.bank_id = N'MBB')
),
k AS (
    SELECT mb.article_key,
           CASE WHEN EXISTS (SELECT 1 FROM stg.stg_article_bank_match m WHERE m.article_key = mb.article_key)
                THEN N'other bank named' ELSE N'no other bank' END AS kind
    FROM mb
)
SELECT kind, COUNT(*) AS titles
FROM k
GROUP BY kind;

-- 8b. 40 of those titles, to judge whether "MB" there is the bank.
SELECT TOP (40) a.title
FROM dw.dim_article a
WHERE a.item_type = 'article'
  AND (N' ' + TRANSLATE(a.title, N',.:;!?()"“”‘’[]…|/«»*+=#@', N'                         ') + N' ')
      COLLATE Latin1_General_BIN2 LIKE N'% MB %'
  AND NOT EXISTS (SELECT 1 FROM stg.stg_article_bank_match m
                  WHERE m.article_key = a.article_key AND m.bank_id = N'MBB')
ORDER BY a.publish_time_local DESC;

-- 9. Titles dropped by the after-a-number rule: a case-sensitive alias right after a digit that is
--    not glued to a letter (same pattern as 500_match_articles.sql).
--    Exclusions are not applied here, so a few rows may already be excluded for another reason.
SELECT a.title, s.bank_id, s.term
FROM dw.dim_article a
JOIN stg.stg_alias s ON s.case_sensitive = 1
WHERE a.item_type = 'article'
  AND (N' ' + TRANSLATE(a.title, N',.:;!?()"“”‘’[]…|/«»*+=#@', N'                         ') + N' ')
      COLLATE Latin1_General_BIN2 LIKE (N'%[^A-Za-z][0-9] ' + s.term + N' %') COLLATE Latin1_General_BIN2
ORDER BY s.term, a.publish_time_local;
